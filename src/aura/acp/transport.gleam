import aura/acp/client
import aura/acp/monitor as acp_monitor
import aura/acp/provider
import aura/acp/sse
import aura/acp/stdio
import aura/acp/tmux
import aura/acp/types
import aura/time
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/result

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Transport determines how ACP sessions are dispatched.
pub type Transport {
  Http(server_url: String, agent_name: String)
  Stdio(command: String)
  Tmux
}

/// Handle to a running session — varies by transport.
pub type SessionHandle {
  HttpHandle(run_id: String)
  StdioHandle(port: stdio.Port, session_id: String)
  TmuxHandle
}

/// Result of dispatching a session.
pub type DispatchResult {
  DispatchResult(run_id: String, handle: SessionHandle)
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// Dispatch a new session. Returns the run/session ID and a handle.
pub fn dispatch(
  transport: Transport,
  session_name: String,
  task_spec: types.TaskSpec,
  monitor_model: String,
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
) -> Result(DispatchResult, String) {
  case transport {
    Http(server_url, agent_name) ->
      dispatch_http(
        server_url,
        agent_name,
        session_name,
        task_spec,
        on_event,
      )
    Stdio(command) ->
      dispatch_stdio(command, session_name, task_spec, on_event)
    Tmux ->
      dispatch_tmux(session_name, task_spec, monitor_model, on_event)
  }
}

/// Send input to a running session.
pub fn send_input(
  transport: Transport,
  handle: SessionHandle,
  session_name: String,
  input: String,
) -> Result(Nil, String) {
  case transport, handle {
    Http(server_url, _), HttpHandle(run_id) ->
      client.resume_run(server_url, run_id, input) |> result.map(fn(_) { Nil })
    Stdio(_), StdioHandle(port, session_id) ->
      send_stdio_prompt(port, session_id, input)
    Tmux, TmuxHandle -> tmux.send_input(session_name, input)
    _, _ -> Error("Transport/handle mismatch")
  }
}

/// Kill a running session.
pub fn kill(
  transport: Transport,
  handle: SessionHandle,
  session_name: String,
) -> Result(Nil, String) {
  case transport, handle {
    Http(server_url, _), HttpHandle(run_id) ->
      client.cancel_run(server_url, run_id)
    Stdio(_), StdioHandle(port, _) -> {
      let _ = stdio.send_notification(port, "cancel", json.object([]))
      stdio.close(port)
      Ok(Nil)
    }
    Tmux, TmuxHandle -> {
      case tmux.kill_session(session_name) {
        Ok(_) -> Ok(Nil)
        Error(e) -> {
          io.println(
            "[acp] tmux kill failed for " <> session_name <> ": " <> e,
          )
          Ok(Nil)
        }
      }
    }
    _, _ -> Error("Transport/handle mismatch")
  }
}

/// Check if a session is still alive (for recovery).
pub fn is_alive(
  transport: Transport,
  run_id: String,
  session_name: String,
) -> Bool {
  case transport {
    Http(server_url, _) ->
      case client.get_run(server_url, run_id) {
        Ok(run) ->
          case run.status {
            client.Completed | client.Failed | client.Cancelled -> False
            _ -> True
          }
        Error(_) -> False
      }
    Stdio(_) ->
      // Stdio sessions die with the BEAM -- never alive on recovery
      False
    Tmux -> tmux.session_exists(session_name)
  }
}

// ---------------------------------------------------------------------------
// Stdio dispatch
// ---------------------------------------------------------------------------

fn dispatch_stdio(
  command: String,
  session_name: String,
  task_spec: types.TaskSpec,
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
) -> Result(DispatchResult, String) {
  // Spawn the child process
  let self_pid = process.self()
  let port = stdio.start(command, self_pid)

  // Initialize handshake
  use _ <- result.try(
    stdio.send_jsonrpc(
      port,
      0,
      "initialize",
      json.object([
        #("protocolVersion", json.int(1)),
        #("clientCapabilities", json.object([])),
        #(
          "clientInfo",
          json.object([
            #("name", json.string("aura")),
            #("title", json.string("A.U.R.A.")),
            #("version", json.string("0.1.0")),
          ]),
        ),
      ]),
    ),
  )

  // Wait for initialize response
  use _ <- result.try(wait_for_response(0, 10_000))

  // Create session
  use _ <- result.try(
    stdio.send_jsonrpc(
      port,
      1,
      "session/new",
      json.object([#("cwd", json.string(task_spec.cwd))]),
    ),
  )

  // Wait for session response, extract sessionId
  use session_response <- result.try(wait_for_response(1, 10_000))
  let session_id =
    case
      json.parse(
        session_response,
        decode.at(["result", "sessionId"], decode.string),
      )
    {
      Ok(id) -> id
      Error(_) -> "unknown"
    }

  // Send the initial prompt
  use _ <- result.try(
    stdio.send_jsonrpc(
      port,
      2,
      "session/prompt",
      json.object([
        #("sessionId", json.string(session_id)),
        #(
          "prompt",
          json.array(
            [
              json.object([
                #("type", json.string("text")),
                #("text", json.string(task_spec.prompt)),
              ]),
            ],
            fn(x) { x },
          ),
        ),
      ]),
    ),
  )

  // Spawn a reader process that translates stdio events to AcpEvents
  process.spawn_unlinked(fn() {
    on_event(
      acp_monitor.AcpStarted(session_name, task_spec.domain, task_spec.id),
    )
    stdio_event_loop(session_name, task_spec.domain, on_event)
  })

  Ok(DispatchResult(
    run_id: session_id,
    handle: StdioHandle(port: port, session_id: session_id),
  ))
}

fn stdio_event_loop(
  session_name: String,
  domain: String,
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
) -> Nil {
  case stdio.receive_message(300_000) {
    stdio.Line(data) -> {
      // Parse JSON-RPC message
      case parse_stdio_message(data) {
        StdioNotification(event_type, content) -> {
          // Translate to AcpEvent
          case event_type {
            "agent_message_chunk" | "tool_call" | "tool_call_update" | "plan" ->
              on_event(
                acp_monitor.AcpProgress(
                  session_name,
                  domain,
                  "",
                  "",
                  content,
                  False,
                ),
              )
            _ -> Nil
          }
          stdio_event_loop(session_name, domain, on_event)
        }
        StdioResponse(stop_reason) -> {
          // Turn complete
          case stop_reason {
            "end_turn" ->
              on_event(
                acp_monitor.AcpCompleted(
                  session_name,
                  domain,
                  types.AcpReport(
                    outcome: types.Clean,
                    files_changed: [],
                    decisions: "",
                    tests: "",
                    blockers: "",
                    anchor: "Session completed",
                  ),
                ),
              )
            "cancelled" ->
              on_event(acp_monitor.AcpFailed(session_name, domain, "cancelled"))
            "refusal" ->
              on_event(acp_monitor.AcpFailed(session_name, domain, "refused"))
            other ->
              on_event(
                acp_monitor.AcpFailed(
                  session_name,
                  domain,
                  "stopped: " <> other,
                ),
              )
          }
        }
        StdioOther -> {
          // Unrecognized message, continue
          stdio_event_loop(session_name, domain, on_event)
        }
      }
    }
    stdio.Exit(code) -> {
      io.println(
        "[acp-stdio] Process exited with code "
        <> code
        <> " for "
        <> session_name,
      )
      on_event(
        acp_monitor.AcpFailed(
          session_name,
          domain,
          "process exited (code " <> code <> ")",
        ),
      )
    }
    stdio.Error(reason) -> {
      io.println("[acp-stdio] Error for " <> session_name <> ": " <> reason)
      on_event(acp_monitor.AcpFailed(session_name, domain, reason))
    }
    stdio.Timeout -> {
      io.println("[acp-stdio] Timeout for " <> session_name)
      on_event(acp_monitor.AcpFailed(session_name, domain, "stdio timeout"))
    }
  }
}

type StdioMessageType {
  StdioNotification(event_type: String, content: String)
  StdioResponse(stop_reason: String)
  StdioOther
}

fn parse_stdio_message(data: String) -> StdioMessageType {
  // Check if it's a session/update notification
  case json.parse(data, decode.at(["method"], decode.string)) {
    Ok("session/update") -> {
      let event_type =
        case
          json.parse(
            data,
            decode.at(
              ["params", "update", "sessionUpdate"],
              decode.string,
            ),
          )
        {
          Ok(t) -> t
          Error(_) -> "unknown"
        }
      let content =
        case
          json.parse(
            data,
            decode.at(["params", "update", "content", "text"], decode.string),
          )
        {
          Ok(t) -> t
          Error(_) -> data
        }
      StdioNotification(event_type, content)
    }
    _ -> {
      // Check if it's a response with stopReason
      case
        json.parse(data, decode.at(["result", "stopReason"], decode.string))
      {
        Ok(reason) -> StdioResponse(reason)
        Error(_) -> StdioOther
      }
    }
  }
}

fn wait_for_response(
  expected_id: Int,
  timeout_ms: Int,
) -> Result(String, String) {
  case stdio.receive_message(timeout_ms) {
    stdio.Line(data) -> {
      // Check if this is the response we're waiting for
      case json.parse(data, decode.at(["id"], decode.int)) {
        Ok(id) if id == expected_id -> Ok(data)
        Ok(_) -> wait_for_response(expected_id, timeout_ms)
        Error(_) -> wait_for_response(expected_id, timeout_ms)
      }
    }
    stdio.Error(reason) -> Error("stdio error: " <> reason)
    stdio.Exit(code) ->
      Error("process exited during init (code " <> code <> ")")
    stdio.Timeout -> Error("timeout waiting for response")
  }
}

fn send_stdio_prompt(
  port: stdio.Port,
  session_id: String,
  input: String,
) -> Result(Nil, String) {
  let id = time.now_ms() / 1000
  stdio.send_jsonrpc(
    port,
    id,
    "session/prompt",
    json.object([
      #("sessionId", json.string(session_id)),
      #(
        "prompt",
        json.array(
          [
            json.object([
              #("type", json.string("text")),
              #("text", json.string(input)),
            ]),
          ],
          fn(x) { x },
        ),
      ),
    ]),
  )
}

// ---------------------------------------------------------------------------
// HTTP dispatch (delegates to existing client + SSE)
// ---------------------------------------------------------------------------

fn dispatch_http(
  server_url: String,
  agent_name: String,
  session_name: String,
  task_spec: types.TaskSpec,
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
) -> Result(DispatchResult, String) {
  use run <- result.try(
    client.create_run(server_url, agent_name, task_spec.prompt),
  )

  // Start SSE listener — translates SSE events to AcpEvents via on_event
  let run_id = run.run_id
  let domain = task_spec.domain
  process.spawn_unlinked(fn() {
    let self_pid = process.self()
    // Start SSE subscription in a separate process (it blocks on httpc)
    process.spawn_unlinked(fn() {
      client.subscribe_events(server_url, run_id, self_pid)
    })
    // Event loop
    http_event_loop(on_event, session_name, domain, run_id, server_url)
  })

  Ok(DispatchResult(run_id: run.run_id, handle: HttpHandle(run_id: run.run_id)))
}

/// Receive SSE events and translate them to AcpEvents.
fn http_event_loop(
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
  session_name: String,
  domain: String,
  run_id: String,
  server_url: String,
) -> Nil {
  case sse.receive_event(300_000) {
    sse.Event(event_type, data) -> {
      case event_type {
        "run.in-progress" ->
          on_event(acp_monitor.AcpStarted(session_name, domain, run_id))
        "run.awaiting" ->
          on_event(
            acp_monitor.AcpAlert(
              session_name,
              domain,
              types.Blocked,
              "Agent awaiting input",
            ),
          )
        "run.completed" ->
          on_event(
            acp_monitor.AcpCompleted(
              session_name,
              domain,
              types.AcpReport(
                outcome: types.Clean,
                files_changed: [],
                decisions: "",
                tests: "",
                blockers: "",
                anchor: data,
              ),
            ),
          )
        "run.failed" ->
          on_event(acp_monitor.AcpFailed(session_name, domain, data))
        "run.cancelled" ->
          on_event(acp_monitor.AcpFailed(session_name, domain, "cancelled"))
        "message.part" ->
          on_event(
            acp_monitor.AcpProgress(session_name, domain, "", "", data, False),
          )
        _ -> Nil
      }
      // Stop on terminal events, continue otherwise
      case event_type {
        "run.completed" | "run.failed" | "run.cancelled" -> Nil
        _ ->
          http_event_loop(on_event, session_name, domain, run_id, server_url)
      }
    }
    sse.Error(reason) -> {
      io.println("[acp-sse] Error for " <> session_name <> ": " <> reason)
      // Reconnect after delay
      process.sleep(5000)
      let self_pid = process.self()
      process.spawn_unlinked(fn() {
        client.subscribe_events(server_url, run_id, self_pid)
      })
      http_event_loop(on_event, session_name, domain, run_id, server_url)
    }
    sse.Done -> {
      io.println("[acp-sse] Stream ended for " <> session_name)
      Nil
    }
    sse.Timeout -> {
      io.println("[acp-sse] Timeout for " <> session_name <> ", reconnecting")
      let self_pid = process.self()
      process.spawn_unlinked(fn() {
        client.subscribe_events(server_url, run_id, self_pid)
      })
      http_event_loop(on_event, session_name, domain, run_id, server_url)
    }
  }
}

// ---------------------------------------------------------------------------
// Tmux dispatch (delegates to existing tmux + monitor)
// ---------------------------------------------------------------------------

fn dispatch_tmux(
  session_name: String,
  task_spec: types.TaskSpec,
  monitor_model: String,
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
) -> Result(DispatchResult, String) {
  // Trust directory if Claude Code
  case task_spec.provider {
    provider.ClaudeCode -> {
      let _ = tmux.ensure_trusted(task_spec.cwd)
      Nil
    }
    _ -> Nil
  }
  let shell_command =
    provider.build_command(
      task_spec.provider,
      task_spec.prompt,
      task_spec.cwd,
      session_name,
      task_spec.worktree,
    )
  use _ <- result.try(
    tmux.create_session(session_name, shell_command)
    |> result.map_error(fn(e) { "Failed to create tmux session: " <> e }),
  )
  case
    acp_monitor.start_monitor_only(
      task_spec,
      session_name,
      monitor_model,
      on_event,
      True,
      False,
    )
  {
    Ok(_) -> Ok(DispatchResult(run_id: "", handle: TmuxHandle))
    Error(err) -> {
      let _ = tmux.kill_session(session_name)
      Error("Monitor start failed: " <> err)
    }
  }
}

/// Parse transport from config string.
pub fn parse(
  transport_str: String,
  server_url: String,
  agent_name: String,
  command: String,
) -> Transport {
  case transport_str {
    "http" -> Http(server_url, agent_name)
    "stdio" -> Stdio(command)
    _ -> Tmux
  }
}
