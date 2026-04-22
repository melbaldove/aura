//// MCP stdio client actor.
////
//// Spawns a subprocess per configured MCP server, speaks JSON-RPC 2.0 over
//// NDJSON on stdio, runs the MCP handshake (`initialize` → response →
//// `notifications/initialized`), subscribes to the configured resource URIs,
//// and forwards incoming notifications to the caller via `on_notification`.
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
////   Non-zero exit in `Ready`, or any exit during `Handshaking`/`Subscribing`,
////   stops the actor abnormally so the supervisor restarts it.
////
//// - Handshake has a deadline (`config.handshake_timeout_ms`, default 30s).
////   If the server never completes initialize + subscribe within the window
////   the actor stops abnormally with "handshake deadline exceeded".
////
//// - `config.on_notification` is invoked inline on the actor's message-
////   handling thread. Callbacks should be fast / non-blocking; if a callback
////   needs to do expensive work it should forward the payload to its own
////   process.

import aura/mcp/jsonrpc
import aura/mcp/stdio_transport.{type Handle}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/string
import logging

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Purpose of a pending request, so responses can be correlated and routed.
pub type Pending {
  InitializePending
  SubscribePending(uri: String)
}

/// Handshake / lifecycle phase.
pub type Phase {
  Handshaking
  Subscribing(remaining: List(String))
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
    /// Resource URI patterns to subscribe to after the handshake completes.
    subscribe: List(String),
    /// Invoked on every incoming notification from the server with the raw
    /// `method` and `params`. The callback can filter for
    /// `notifications/resources/updated` or handle any method it cares about.
    ///
    /// Runs inline on the actor thread — do fast, non-blocking work only.
    on_notification: fn(String, json.Json) -> Nil,
    /// Upper bound on how long the handshake (`initialize` + all
    /// subscribe calls) may take before the actor stops abnormally.
    /// 30s by default.
    handshake_timeout_ms: Int,
  )
}

/// Messages the actor handles. `McpLine` and `McpExit` are translated from
/// the raw tagged tuples delivered by the FFI. `HandshakeDeadline` is a
/// self-sent timer message that trips if the handshake runs too long.
pub type ClientMessage {
  McpLine(raw: String)
  McpExit(status: Int)
  HandshakeDeadline
  Stop
}

type State {
  State(
    handle: Handle,
    config: ClientConfig,
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
  subscribe subscribe: List(String),
  on_notification on_notification: fn(String, json.Json) -> Nil,
) -> ClientConfig {
  ClientConfig(
    name: name,
    command: command,
    args: args,
    env: env,
    subscribe: subscribe,
    on_notification: on_notification,
    handshake_timeout_ms: default_handshake_timeout_ms,
  )
}

/// Start a new MCP client actor. Spawns the subprocess synchronously; the
/// initialize + subscribe handshake continues asynchronously — observers
/// see progress through `config.on_notification` once the client reaches
/// `Ready` and the server emits notifications.
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
                  pending: dict.from_list([#(id, InitializePending)]),
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
        Handshaking | Subscribing(_) -> {
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

    McpLine(raw) -> handle_line(state, raw)
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
        Handshaking | Subscribing(_) -> {
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

    Ok(jsonrpc.Notification(method, params)) -> {
      let params_json = case params {
        Some(p) -> p
        None -> json.object([])
      }
      state.config.on_notification(method, params_json)
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
        Error(_) ->
          // Response for a request we don't remember. Ignore.
          actor.continue(state)
        Ok(pending) -> {
          let new_pending = dict.delete(state.pending, n)
          let state_without = State(..state, pending: new_pending)
          case pending, body {
            _, jsonrpc.Failure(code, message, _) -> {
              logging.log(
                logging.Error,
                log_prefix(state.config)
                  <> " JSON-RPC error for "
                  <> describe_pending(pending)
                  <> ": "
                  <> int.to_string(code)
                  <> " "
                  <> message,
              )
              actor.stop_abnormal(
                "mcp client failed: "
                <> describe_pending(pending)
                <> " returned error "
                <> int.to_string(code)
                <> ": "
                <> message,
              )
            }
            InitializePending, jsonrpc.Success(_) ->
              after_initialize(state_without)
            SubscribePending(uri), jsonrpc.Success(_) -> {
              logging.log(
                logging.Info,
                log_prefix(state.config) <> " Subscribed: " <> uri,
              )
              advance_subscribe(state_without)
            }
          }
        }
      }
    jsonrpc.StringId(_) ->
      // We always send int ids; a string-id response is a server bug.
      actor.continue(state)
  }
}

fn describe_pending(pending: Pending) -> String {
  case pending {
    InitializePending -> "initialize"
    SubscribePending(uri) -> "resources/subscribe(" <> uri <> ")"
  }
}

// ---------------------------------------------------------------------------
// Handshake + subscribe progression
// ---------------------------------------------------------------------------

fn after_initialize(state: State) -> actor.Next(State, ClientMessage) {
  // Send the `notifications/initialized` notification (no response expected).
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
      let count = list.length(state.config.subscribe)
      logging.log(
        logging.Info,
        log_prefix(state.config)
          <> " Initialized; subscribing to "
          <> int.to_string(count)
          <> " resources",
      )
      advance_subscribe(
        State(..state, phase: Subscribing(state.config.subscribe)),
      )
    }
  }
}

/// Walk the list of remaining subscribe URIs. Send the first, stop there;
/// when the response comes in `handle_response` calls us again. When the
/// list is empty we transition to Ready.
fn advance_subscribe(state: State) -> actor.Next(State, ClientMessage) {
  case state.phase {
    Subscribing([]) -> {
      logging.log(logging.Info, log_prefix(state.config) <> " Ready")
      actor.continue(State(..state, phase: Ready))
    }
    Subscribing([uri, ..rest]) -> {
      let id = state.next_id
      let msg =
        jsonrpc.request(id, "resources/subscribe", json.object([
          #("uri", json.string(uri)),
        ]))
      case stdio_transport.send_line(state.handle, jsonrpc.encode(msg)) {
        Error(err) -> {
          logging.log(
            logging.Error,
            log_prefix(state.config)
              <> " Failed to send subscribe("
              <> uri
              <> "): "
              <> err,
          )
          actor.stop_abnormal(
            "mcp client failed: subscribe send(" <> uri <> "): " <> err,
          )
        }
        Ok(_) ->
          actor.continue(
            State(
              ..state,
              pending: dict.insert(state.pending, id, SubscribePending(uri)),
              next_id: id + 1,
              phase: Subscribing(rest),
            ),
          )
      }
    }
    _ -> actor.continue(state)
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
    Subscribing(_) -> "Subscribing"
    Ready -> "Ready"
  }
}

fn truncate(s: String, n: Int) -> String {
  case string.length(s) > n {
    True -> string.slice(s, 0, n) <> "..."
    False -> s
  }
}

