//// MCP stdio client actor.
////
//// Spawns a subprocess per configured MCP server, speaks JSON-RPC 2.0 over
//// NDJSON on stdio, and runs the MCP handshake (`initialize` → response →
//// `notifications/initialized`). Once the handshake completes the actor is
//// `Ready`, and `call_tool/4` exposes a synchronous surface on top of the
//// async request/response stream for the brain's action surface.
////
//// The Erlang port is owned by `aura_mcp_stdio_ffi`. Raw lines are delivered
//// to this actor's pid as `{mcp_line, Handle, RawLine}` and subprocess exit
//// as `{mcp_exit, Handle, Status}` — translated to `ClientMessage` via
//// `process.select_record`.
////
//// Design notes:
////
//// - Clean subprocess exit (status 0) in `Ready` is treated as a normal
////   actor stop. Servers that shut down gracefully (OAuth refresh failure,
////   SIGTERM from an operator) should not trigger supervisor restart loops.
////   Non-zero exit in `Ready`, or any exit during `Handshaking`, stops the
////   actor abnormally so the supervisor restarts it.
////
//// - Handshake has a deadline (`config.handshake_timeout_ms`, default 30s).
////   If the server never completes initialize within the window the actor
////   stops abnormally with "handshake deadline exceeded".
////
//// - Incoming notifications from the server on a Ready client are logged at
////   Info and dropped. ADR 026 retired the ambient-subscription path; the
////   action surface does not consume notifications.
////
//// - `call_tool` correlates requests and responses via a `pending` dict
////   keyed by JSON-RPC id. Each entry carries either `PendingInit` (the one
////   outstanding initialize id) or `PendingToolCall(reply_to)` (a waiter we
////   must deliver `ToolCallOk` / `ToolCallErr` to).

import aura/mcp/jsonrpc
import aura/mcp/stdio_transport.{type Handle}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/otp/actor
import gleam/otp/supervision
import gleam/string
import logging

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Handshake / lifecycle phase.
pub type Phase {
  Handshaking
  Ready
}

/// Default handshake deadline (30 seconds). Generous enough for slow OAuth
/// refreshes but not indefinite.
pub const default_handshake_timeout_ms: Int = 30_000

/// Configuration for a single MCP client.
pub type ClientConfig {
  ClientConfig(
    name: String,
    command: String,
    args: List(String),
    env: List(#(String, String)),
    /// Upper bound on how long the handshake (`initialize` + `initialized`
    /// notification) may take before the actor stops abnormally. 30s by
    /// default.
    handshake_timeout_ms: Int,
  )
}

/// Result delivered back to a `call_tool/4` waiter.
pub type ToolCallResult {
  ToolCallOk(result: json.Json)
  ToolCallErr(message: String)
}

/// One outstanding JSON-RPC request the actor is waiting to correlate.
type Pending {
  PendingInit
  PendingToolCall(reply_to: Subject(ToolCallResult), tool: String)
}

/// Messages the actor handles. `McpLine` and `McpExit` are translated from
/// the raw tagged tuples delivered by the FFI. `HandshakeDeadline` is a
/// self-sent timer message that trips if the handshake runs too long.
/// `CallTool` is the entry point for the public `call_tool/4` surface.
/// `CancelPendingToolCall` is sent by `call_tool/4` when its
/// `process.receive` times out, so the actor can drop the stale entry
/// from `pending` rather than leaking it if the server never responds.
pub type ClientMessage {
  McpLine(raw: String)
  McpExit(status: Int)
  HandshakeDeadline
  CallTool(
    reply_to: Subject(ToolCallResult),
    tool: String,
    args: json.Json,
  )
  CancelPendingToolCall(reply_to: Subject(ToolCallResult))
  Stop
}

type State {
  State(
    handle: Handle,
    config: ClientConfig,
    /// Outstanding JSON-RPC requests, keyed by id.
    pending: Dict(Int, Pending),
    next_id: Int,
    phase: Phase,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Build a `ClientConfig` with sensible defaults (`handshake_timeout_ms` =
/// 30s). Prefer this over constructing `ClientConfig` directly so new fields
/// gain reasonable defaults automatically.
pub fn new_config(
  name name: String,
  command command: String,
  args args: List(String),
  env env: List(#(String, String)),
) -> ClientConfig {
  ClientConfig(
    name: name,
    command: command,
    args: args,
    env: env,
    handshake_timeout_ms: default_handshake_timeout_ms,
  )
}

/// Start a new MCP client actor. Spawns the subprocess synchronously; the
/// initialize handshake continues asynchronously — once the server replies
/// and the client sends `notifications/initialized` the actor transitions
/// to `Ready`.
///
/// Fails synchronously if the subprocess cannot be spawned or the initial
/// `initialize` request cannot be written.
pub fn start(
  config: ClientConfig,
) -> Result(actor.Started(Subject(ClientMessage)), String) {
  let builder =
    actor.new_with_initialiser(5000, fn(self_subject) {
      let self_pid = process.self()
      case
        stdio_transport.start(
          config.command,
          config.args,
          config.env,
          self_pid,
        )
      {
        Error(err) ->
          Error("mcp subprocess spawn failed: " <> err)
        Ok(handle) -> {
          let id = 0
          case send_initialize(handle, id) {
            Error(err) -> {
              stdio_transport.close(handle)
              Error("mcp initialize send failed: " <> err)
            }
            Ok(_) -> {
              logging.log(
                logging.Info,
                log_prefix(config)
                  <> " Handshaking with "
                  <> config.command,
              )
              // Arm the handshake deadline. If we reach Ready before it
              // fires, the message is ignored in `handle_message`.
              let _ =
                process.send_after(
                  self_subject,
                  config.handshake_timeout_ms,
                  HandshakeDeadline,
                )
              let state =
                State(
                  handle: handle,
                  config: config,
                  pending: dict.from_list([#(id, PendingInit)]),
                  next_id: id + 1,
                  phase: Handshaking,
                )
              let selector = build_selector(self_subject)
              Ok(
                actor.initialised(state)
                |> actor.selecting(selector)
                |> actor.returning(self_subject),
              )
            }
          }
        }
      }
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> Ok(started)
    Error(err) -> Error("mcp client failed to start: " <> string.inspect(err))
  }
}

/// Build a supervised child spec so the MCP client can live under a
/// supervisor. The pool supervisor (task 8) uses this.
pub fn supervised(
  config: ClientConfig,
) -> supervision.ChildSpecification(Subject(ClientMessage)) {
  supervision.worker(fn() {
    case start(config) {
      Ok(started) -> Ok(started)
      Error(_) -> Error(actor.InitTimeout)
    }
  })
}

/// Ask the actor to shut down and close the subprocess.
pub fn stop(subject: Subject(ClientMessage)) -> Nil {
  process.send(subject, Stop)
}

/// Call an MCP tool synchronously. Sends a `tools/call` JSON-RPC request and
/// blocks up to `timeout_ms` for the response.
///
/// Returns the raw `result` JSON on success (typically
/// `{"content": [...]}` per the MCP spec), or a string error:
/// - `"mcp client not ready"` if the handshake hasn't completed.
/// - `"mcp tool error: <code> <message>"` if the server returned JSON-RPC
///   error.
/// - `"mcp tool call timed out [<tool>]"` if no response arrives within
///   `timeout_ms`. On timeout the actor's pending entry is also cleared
///   so stale waiters don't leak.
///
/// Callers handle "not ready" by retrying later; the client never queues
/// requests across the handshake boundary.
pub fn call_tool(
  subject: Subject(ClientMessage),
  tool: String,
  args: json.Json,
  timeout_ms: Int,
) -> Result(json.Json, String) {
  let reply_to = process.new_subject()
  process.send(subject, CallTool(reply_to: reply_to, tool: tool, args: args))
  case process.receive(reply_to, timeout_ms) {
    Ok(ToolCallOk(result)) -> Ok(result)
    Ok(ToolCallErr(msg)) -> Error(msg)
    Error(_) -> {
      // Timed out waiting for a response. Tell the actor to drop the
      // pending entry so it doesn't leak across the lifetime of the
      // client — the server may never reply.
      process.send(subject, CancelPendingToolCall(reply_to: reply_to))
      Error("mcp tool call timed out [" <> tool <> "]")
    }
  }
}

// ---------------------------------------------------------------------------
// Selector — translate raw FFI tuples into ClientMessage
// ---------------------------------------------------------------------------

fn build_selector(
  self_subject: Subject(ClientMessage),
) -> process.Selector(ClientMessage) {
  // {mcp_line, Handle, RawLine} and {mcp_exit, Handle, Status} are plain
  // Erlang tuples sent by aura_mcp_stdio_ffi. Match by tag + arity, decode
  // the payload via a Dynamic decoder. Handle is discarded because each
  // actor owns exactly one subprocess.
  let line_tag = atom.create("mcp_line")
  let exit_tag = atom.create("mcp_exit")

  process.new_selector()
  |> process.select(self_subject)
  |> process.select_record(line_tag, 2, decode_line)
  |> process.select_record(exit_tag, 2, decode_exit)
}

fn decode_line(msg: Dynamic) -> ClientMessage {
  let decoder = {
    use raw <- decode.field(2, decode.string)
    decode.success(McpLine(raw: raw))
  }
  case decode.run(msg, decoder) {
    Ok(m) -> m
    Error(_) -> McpLine(raw: "")
  }
}

fn decode_exit(msg: Dynamic) -> ClientMessage {
  let decoder = {
    use status <- decode.field(2, decode.int)
    decode.success(McpExit(status: status))
  }
  case decode.run(msg, decoder) {
    Ok(m) -> m
    Error(_) -> McpExit(status: -1)
  }
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: State,
  msg: ClientMessage,
) -> actor.Next(State, ClientMessage) {
  case msg {
    Stop -> {
      stdio_transport.close(state.handle)
      actor.stop()
    }

    McpExit(status) ->
      case state.phase, status {
        Ready, 0 -> {
          logging.log(
            logging.Info,
            log_prefix(state.config) <> " Subprocess exited cleanly",
          )
          actor.stop()
        }
        Ready, _ -> {
          let reason =
            "mcp subprocess exited (status " <> int.to_string(status) <> ")"
          logging.log(
            logging.Error,
            log_prefix(state.config)
              <> " Subprocess exited with status "
              <> int.to_string(status)
              <> " during Ready",
          )
          actor.stop_abnormal(reason)
        }
        _, _ -> {
          let reason =
            "mcp subprocess exited during handshake (status "
            <> int.to_string(status)
            <> ")"
          logging.log(
            logging.Error,
            log_prefix(state.config)
              <> " Subprocess exited with status "
              <> int.to_string(status)
              <> " during "
              <> phase_name(state.phase),
          )
          actor.stop_abnormal(reason)
        }
      }

    HandshakeDeadline ->
      case state.phase {
        Ready ->
          // Handshake finished before the deadline fired — ignore.
          actor.continue(state)
        Handshaking -> {
          let reason =
            "handshake deadline exceeded ("
            <> int.to_string(state.config.handshake_timeout_ms)
            <> "ms)"
          logging.log(
            logging.Error,
            log_prefix(state.config)
              <> " Handshake deadline exceeded after "
              <> int.to_string(state.config.handshake_timeout_ms)
              <> "ms in "
              <> phase_name(state.phase),
          )
          stdio_transport.close(state.handle)
          actor.stop_abnormal(reason)
        }
      }

    CallTool(reply_to, tool, args) -> handle_call_tool(state, reply_to, tool, args)

    CancelPendingToolCall(reply_to) ->
      handle_cancel_pending(state, reply_to)

    McpLine(raw) -> handle_line(state, raw)
  }
}

/// Remove any `PendingToolCall` entries whose reply subject matches
/// `reply_to`. Called after `call_tool/4` times out, so the actor's
/// pending dict stays bounded by genuinely in-flight calls rather than
/// accumulating entries whose waiters have already given up.
fn handle_cancel_pending(
  state: State,
  reply_to: Subject(ToolCallResult),
) -> actor.Next(State, ClientMessage) {
  let pending =
    dict.filter(state.pending, fn(_id, entry) {
      case entry {
        PendingToolCall(reply_to: existing, ..) -> existing != reply_to
        PendingInit -> True
      }
    })
  actor.continue(State(..state, pending: pending))
}

fn handle_call_tool(
  state: State,
  reply_to: Subject(ToolCallResult),
  tool: String,
  args: json.Json,
) -> actor.Next(State, ClientMessage) {
  case state.phase {
    Handshaking -> {
      process.send(reply_to, ToolCallErr("mcp client not ready"))
      actor.continue(state)
    }
    Ready -> {
      let id = state.next_id
      let params =
        json.object([
          #("name", json.string(tool)),
          #("arguments", args),
        ])
      let line = jsonrpc.encode(jsonrpc.request(id, "tools/call", params))
      case stdio_transport.send_line(state.handle, line) {
        Error(err) -> {
          process.send(
            reply_to,
            ToolCallErr("mcp tool call send failed: " <> err),
          )
          actor.continue(state)
        }
        Ok(_) -> {
          let pending =
            dict.insert(
              state.pending,
              id,
              PendingToolCall(reply_to: reply_to, tool: tool),
            )
          actor.continue(State(..state, pending: pending, next_id: id + 1))
        }
      }
    }
  }
}

fn handle_line(
  state: State,
  raw: String,
) -> actor.Next(State, ClientMessage) {
  case jsonrpc.decode(raw) {
    Error(err) ->
      case state.phase {
        // During the handshake any malformed JSON from the server is fatal —
        // we can't know whether to send notifications/initialized or not.
        Handshaking -> {
          logging.log(
            logging.Error,
            log_prefix(state.config)
              <> " Malformed JSON during handshake: "
              <> err,
          )
          actor.stop_abnormal(
            "mcp client failed: malformed JSON during handshake: " <> err,
          )
        }
        Ready -> {
          // After handshake, tolerate garbage — the client keeps running.
          // But log it so the operator can see what's being dropped.
          logging.log(
            logging.Warning,
            log_prefix(state.config)
              <> " Discarding malformed JSON line: "
              <> truncate(raw, 80),
          )
          actor.continue(state)
        }
      }

    Ok(jsonrpc.Notification(method, _params)) -> {
      // ADR 026 removed the ambient-subscription path; notifications are not
      // consumed by the client. Log + drop so operators can see what the
      // server emits.
      logging.log(
        logging.Info,
        log_prefix(state.config) <> " Unhandled notification: " <> method,
      )
      actor.continue(state)
    }

    Ok(jsonrpc.Response(id, body)) -> handle_response(state, id, body)

    Ok(jsonrpc.Request(_, _, _)) ->
      // Servers can issue requests to clients (e.g. sampling). Not supported
      // yet; ignore.
      actor.continue(state)
  }
}

fn handle_response(
  state: State,
  id: jsonrpc.Id,
  body: jsonrpc.ResponseBody,
) -> actor.Next(State, ClientMessage) {
  case id {
    jsonrpc.IntId(n) ->
      case dict.get(state.pending, n) {
        Ok(PendingInit) -> {
          let pending = dict.delete(state.pending, n)
          let state_without = State(..state, pending: pending)
          case body {
            jsonrpc.Failure(code, message, _) -> {
              logging.log(
                logging.Error,
                log_prefix(state.config)
                  <> " JSON-RPC error for initialize: "
                  <> int.to_string(code)
                  <> " "
                  <> message,
              )
              actor.stop_abnormal(
                "mcp client failed: initialize returned error "
                <> int.to_string(code)
                <> ": "
                <> message,
              )
            }
            jsonrpc.Success(_) -> after_initialize(state_without)
          }
        }
        Ok(PendingToolCall(reply_to, tool)) -> {
          let pending = dict.delete(state.pending, n)
          case body {
            jsonrpc.Success(result) -> {
              process.send(reply_to, ToolCallOk(result))
              actor.continue(State(..state, pending: pending))
            }
            jsonrpc.Failure(code, message, _) -> {
              logging.log(
                logging.Warning,
                log_prefix(state.config)
                  <> " Tool "
                  <> tool
                  <> " returned error "
                  <> int.to_string(code)
                  <> ": "
                  <> message,
              )
              process.send(
                reply_to,
                ToolCallErr(
                  "mcp tool error: "
                  <> int.to_string(code)
                  <> " "
                  <> message,
                ),
              )
              actor.continue(State(..state, pending: pending))
            }
          }
        }
        Error(_) ->
          // Response for a request we don't remember. Ignore.
          actor.continue(state)
      }
    jsonrpc.StringId(_) ->
      // We always send int ids; a string-id response is a server bug.
      actor.continue(state)
  }
}

// ---------------------------------------------------------------------------
// Handshake progression
// ---------------------------------------------------------------------------

fn after_initialize(state: State) -> actor.Next(State, ClientMessage) {
  // Send the `notifications/initialized` notification (no response expected)
  // and transition straight to Ready.
  case
    stdio_transport.send_line(
      state.handle,
      jsonrpc.encode(jsonrpc.notification_no_params(
        "notifications/initialized",
      )),
    )
  {
    Error(err) -> {
      logging.log(
        logging.Error,
        log_prefix(state.config)
          <> " Failed to send initialized notification: "
          <> err,
      )
      actor.stop_abnormal(
        "mcp client failed: initialized notification send: " <> err,
      )
    }
    Ok(_) -> {
      logging.log(logging.Info, log_prefix(state.config) <> " Ready")
      actor.continue(State(..state, phase: Ready))
    }
  }
}

fn send_initialize(handle: Handle, id: Int) -> Result(Nil, String) {
  let params =
    json.object([
      #("protocolVersion", json.string("2025-06-18")),
      #(
        "clientInfo",
        json.object([
          #("name", json.string("aura")),
          #("version", json.string("0.1.0")),
        ]),
      ),
      #("capabilities", json.object([])),
    ])
  stdio_transport.send_line(
    handle,
    jsonrpc.encode(jsonrpc.request(id, "initialize", params)),
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn log_prefix(config: ClientConfig) -> String {
  "[mcp:" <> config.name <> "]"
}

fn phase_name(phase: Phase) -> String {
  case phase {
    Handshaking -> "Handshaking"
    Ready -> "Ready"
  }
}

fn truncate(s: String, n: Int) -> String {
  case string.length(s) > n {
    True -> string.slice(s, 0, n) <> "..."
    False -> s
  }
}

