import aura/acp/client
import aura/acp/monitor as acp_monitor
import aura/acp/provider
import aura/acp/sse
import aura/acp/stdio
import aura/acp/tmux
import aura/acp/types
import gleam/erlang/process
import gleam/io
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
  StdioHandle(owner: stdio.SessionOwner, session_id: String)
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
    Stdio(_), StdioHandle(owner, session_id) ->
      stdio.send_input(owner, session_id, input)
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
    Stdio(_), StdioHandle(owner, _) -> {
      stdio.close(owner)
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
  let reply_subject = process.new_subject()

  process.spawn_unlinked(fn() {
    case stdio.start_session(command, task_spec.cwd, task_spec.prompt) {
      Error(e) -> {
        process.send(reply_subject, Error(e))
      }
      Ok(#(owner, session_id)) -> {
        process.send(reply_subject, Ok(#(owner, session_id)))
        on_event(acp_monitor.AcpStarted(session_name, task_spec.domain, task_spec.id))
        stdio_event_loop(session_name, task_spec.domain, on_event)
      }
    }
  })

  case process.receive(reply_subject, 30_000) {
    Ok(Ok(#(owner, session_id))) ->
      Ok(DispatchResult(
        run_id: session_id,
        handle: StdioHandle(owner: owner, session_id: session_id),
      ))
    Ok(Error(err)) -> Error("Stdio dispatch failed: " <> err)
    Error(_) -> Error("Stdio session handshake timed out")
  }
}

fn stdio_event_loop(
  session_name: String,
  domain: String,
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
) -> Nil {
  case stdio.receive_event(5000) {
    stdio.Event(_event_type, _content) -> {
      // Will forward to monitor in next task
      stdio_event_loop(session_name, domain, on_event)
    }
    stdio.Complete(stop_reason) -> {
      case stop_reason {
        "end_turn" ->
          on_event(acp_monitor.AcpCompleted(session_name, domain, types.AcpReport(
            outcome: types.Clean, files_changed: [], decisions: "",
            tests: "", blockers: "", anchor: "Session completed",
          )))
        "cancelled" ->
          on_event(acp_monitor.AcpFailed(session_name, domain, "cancelled"))
        "refusal" ->
          on_event(acp_monitor.AcpFailed(session_name, domain, "refused"))
        other ->
          on_event(acp_monitor.AcpFailed(session_name, domain, "stopped: " <> other))
      }
    }
    stdio.Exit(code) -> {
      io.println("[acp-stdio] Process exited with code " <> code <> " for " <> session_name)
      on_event(acp_monitor.AcpFailed(session_name, domain, "process exited (code " <> code <> ")"))
    }
    stdio.Error(reason) -> {
      io.println("[acp-stdio] Error for " <> session_name <> ": " <> reason)
      on_event(acp_monitor.AcpFailed(session_name, domain, reason))
    }
    stdio.Timeout -> {
      stdio_event_loop(session_name, domain, on_event)
    }
  }
}

// Stdio protocol handling (handshake, JSON-RPC, event parsing) is in the
// Erlang FFI (aura_acp_stdio_ffi.erl). The Gleam side only manages lifecycle.

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
