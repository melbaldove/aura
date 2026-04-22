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

import aura/mcp/jsonrpc
import aura/mcp/stdio_transport.{type Handle}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/string

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
    on_notification: fn(String, json.Json) -> Nil,
  )
}

/// Messages the actor handles. `McpLine` and `McpExit` are translated from
/// the raw tagged tuples delivered by the FFI.
pub type ClientMessage {
  McpLine(raw: String)
  McpExit(status: Int)
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
      case state.phase {
        Ready ->
          actor.stop_abnormal(
            "mcp subprocess exited (status "
            <> int.to_string(status)
            <> ")",
          )
        _ ->
          actor.stop_abnormal(
            "mcp subprocess exited during handshake (status "
            <> int.to_string(status)
            <> ")",
          )
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
        Handshaking | Subscribing(_) ->
          actor.stop_abnormal(
            "mcp client failed: malformed JSON during handshake: " <> err,
          )
        Ready ->
          // After handshake, tolerate garbage — the client keeps running.
          actor.continue(state)
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
            _, jsonrpc.Failure(code, message, _) ->
              actor.stop_abnormal(
                "mcp client failed: "
                <> describe_pending(pending)
                <> " returned error "
                <> int.to_string(code)
                <> ": "
                <> message,
              )
            InitializePending, jsonrpc.Success(_) ->
              after_initialize(state_without)
            SubscribePending(_), jsonrpc.Success(_) ->
              advance_subscribe(state_without)
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
      jsonrpc.encode(jsonrpc.notification_no_params("notifications/initialized")),
    )
  {
    Error(err) ->
      actor.stop_abnormal(
        "mcp client failed: initialized notification send: " <> err,
      )
    Ok(_) ->
      advance_subscribe(
        State(..state, phase: Subscribing(state.config.subscribe)),
      )
  }
}

/// Walk the list of remaining subscribe URIs. Send the first, stop there;
/// when the response comes in `handle_response` calls us again. When the
/// list is empty we transition to Ready.
fn advance_subscribe(state: State) -> actor.Next(State, ClientMessage) {
  case state.phase {
    Subscribing([]) -> actor.continue(State(..state, phase: Ready))
    Subscribing([uri, ..rest]) -> {
      let id = state.next_id
      let msg =
        jsonrpc.request(id, "resources/subscribe", json.object([
          #("uri", json.string(uri)),
        ]))
      case stdio_transport.send_line(state.handle, jsonrpc.encode(msg)) {
        Error(err) ->
          actor.stop_abnormal(
            "mcp client failed: subscribe send(" <> uri <> "): " <> err,
          )
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
