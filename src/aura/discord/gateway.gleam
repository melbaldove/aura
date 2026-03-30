import aura/discord/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

pub type GatewayState {
  GatewayState(
    token: String,
    intents: Int,
    sequence: Option(Int),
    session_id: Option(String),
    resume_url: Option(String),
    heartbeat_interval: Option(Int),
    ws_pid: Option(process.Pid),
    self_subject: Option(process.Subject(GatewayMessage)),
    on_event: fn(types.GatewayEvent) -> Nil,
  )
}

pub type GatewayMessage {
  WsText(String)
  WsClosed
  WsError(String)
  SendHeartbeat
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Connect to Discord gateway via raw WebSocket.
/// Returns the PID of the gateway actor.
pub fn connect(
  token: String,
  intents: Int,
  gateway_url: String,
  on_event: fn(types.GatewayEvent) -> Nil,
) -> Result(process.Pid, String) {
  // Parse host from URL (e.g., "wss://gateway.discord.gg" -> "gateway.discord.gg")
  let host = case string.split(gateway_url, "//") {
    [_, rest] -> case string.split(rest, "/") {
      [h, ..] -> h
      _ -> rest
    }
    _ -> "gateway.discord.gg"
  }

  let path = "/?v=10&encoding=json"

  let initial_state =
    GatewayState(
      token: token,
      intents: intents,
      sequence: None,
      session_id: None,
      resume_url: None,
      heartbeat_interval: None,
      ws_pid: None,
      self_subject: None,
      on_event: on_event,
    )

  // Start the gateway actor
  let result =
    actor.new_with_initialiser(10_000, fn(self_subject) {
      // Connect WebSocket, relay frames to this actor
      let ws_pid = ws_connect(host, path, self_subject)
      let state = GatewayState(..initial_state, ws_pid: Some(ws_pid), self_subject: Some(self_subject))

      // Set up selector for WebSocket messages and heartbeat
      let selector =
        process.new_selector()
        |> process.select(self_subject)

      Ok(
        actor.initialised(state)
        |> actor.selecting(selector)
        |> actor.returning(self_subject),
      )
    })
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> Ok(started.pid)
    Error(err) -> Error("Gateway failed: " <> string.inspect(err))
  }
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "aura_ws_ffi", "connect")
fn ws_connect_raw(
  host: String,
  path: String,
  callback_pid: process.Pid,
) -> process.Pid

/// Connect WebSocket and set up message relay to the actor subject
fn ws_connect(
  host: String,
  path: String,
  subject: process.Subject(GatewayMessage),
) -> process.Pid {
  // Spawn a bridge that receives raw Erlang WS messages and converts to Gleam
  let bridge_pid = spawn_bridge(subject)
  ws_connect_raw(host, path, bridge_pid)
}

@external(erlang, "aura_gateway_bridge", "spawn_bridge")
fn spawn_bridge(subject: process.Subject(GatewayMessage)) -> process.Pid

/// Send a text frame through the WebSocket
fn ws_send(state: GatewayState, text: String) -> Nil {
  case state.ws_pid {
    Some(pid) -> ws_send_raw(pid, text)
    None -> Nil
  }
}

@external(erlang, "aura_gateway_bridge", "ws_send")
fn ws_send_raw(ws_pid: process.Pid, text: String) -> Nil

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: GatewayState,
  message: GatewayMessage,
) -> actor.Next(GatewayState, GatewayMessage) {
  case message {
    WsText(text) -> handle_text(state, text)
    WsClosed -> {
      state.on_event(types.Reconnect)
      actor.stop_abnormal("WebSocket closed")
    }
    WsError(err) -> {
      actor.stop_abnormal("WebSocket error: " <> err)
    }
    SendHeartbeat -> handle_heartbeat(state)
  }
}

// ---------------------------------------------------------------------------
// Heartbeat
// ---------------------------------------------------------------------------

fn handle_heartbeat(
  state: GatewayState,
) -> actor.Next(GatewayState, GatewayMessage) {
  let payload =
    types.heartbeat_payload(state.sequence)
    |> json.to_string
  ws_send(state, payload)
  schedule_heartbeat(state)
  actor.continue(state)
}

fn schedule_heartbeat(state: GatewayState) -> Nil {
  case state.heartbeat_interval, state.self_subject {
    Some(interval), Some(subject) -> schedule_heartbeat_ffi(interval, subject)
    _, _ -> Nil
  }
}

@external(erlang, "aura_gateway_bridge", "schedule_heartbeat")
fn schedule_heartbeat_ffi(interval_ms: Int, subject: process.Subject(GatewayMessage)) -> Nil

// ---------------------------------------------------------------------------
// Gateway frame parsing & dispatch
// ---------------------------------------------------------------------------

fn handle_text(
  state: GatewayState,
  text: String,
) -> actor.Next(GatewayState, GatewayMessage) {
  let frame_result = parse_gateway_frame(text)

  case frame_result {
    Ok(#(op, seq, event_name)) -> {
      let new_state = case seq {
        Some(s) -> GatewayState(..state, sequence: Some(s))
        None -> state
      }
      handle_opcode(new_state, op, event_name, text)
    }
    Error(_) -> actor.continue(state)
  }
}

fn parse_gateway_frame(
  text: String,
) -> Result(#(Int, Option(Int), Option(String)), json.DecodeError) {
  let decoder = {
    use op <- decode.field("op", decode.int)
    use s <- decode.optional_field("s", None, decode.optional(decode.int))
    use t <- decode.optional_field("t", None, decode.optional(decode.string))
    decode.success(#(op, s, t))
  }
  json.parse(text, decoder)
}

fn handle_opcode(
  state: GatewayState,
  op: Int,
  event_name: Option(String),
  raw_text: String,
) -> actor.Next(GatewayState, GatewayMessage) {
  case op {
    0 -> handle_dispatch(state, event_name, raw_text)
    1 -> handle_heartbeat(state)
    7 -> {
      state.on_event(types.Reconnect)
      actor.stop_abnormal("Reconnect requested")
    }
    9 -> {
      let resumable = parse_invalid_session(raw_text)
      state.on_event(types.InvalidSession(resumable: resumable))
      case resumable {
        True -> actor.continue(state)
        False -> actor.stop_abnormal("Invalid session")
      }
    }
    10 -> handle_hello(state, raw_text)
    11 -> {
      state.on_event(types.HeartbeatAck)
      actor.continue(state)
    }
    _ -> actor.continue(state)
  }
}

// ---------------------------------------------------------------------------
// Hello (op 10)
// ---------------------------------------------------------------------------

fn handle_hello(
  state: GatewayState,
  raw_text: String,
) -> actor.Next(GatewayState, GatewayMessage) {
  case parse_hello_interval(raw_text) {
    Ok(interval) -> {
      let new_state =
        GatewayState(..state, heartbeat_interval: Some(interval))

      new_state.on_event(types.Hello(types.HelloPayload(
        heartbeat_interval: interval,
      )))

      schedule_heartbeat(new_state)

      let identify =
        types.identify_payload(new_state.token, new_state.intents)
        |> json.to_string
      ws_send(new_state, identify)

      actor.continue(new_state)
    }
    Error(_) -> {
      actor.stop_abnormal("Failed to parse Hello")
    }
  }
}

fn parse_hello_interval(text: String) -> Result(Int, json.DecodeError) {
  decode.at(["d", "heartbeat_interval"], decode.int)
  |> json.parse(text, _)
}

// ---------------------------------------------------------------------------
// Dispatch (op 0)
// ---------------------------------------------------------------------------

fn handle_dispatch(
  state: GatewayState,
  event_name: Option(String),
  raw_text: String,
) -> actor.Next(GatewayState, GatewayMessage) {
  case event_name {
    Some("READY") -> handle_ready(state, raw_text)
    Some("MESSAGE_CREATE") -> handle_message_create(state, raw_text)
    Some(name) -> {
      state.on_event(types.UnknownEvent(name: name))
      actor.continue(state)
    }
    None -> actor.continue(state)
  }
}

fn handle_ready(
  state: GatewayState,
  raw_text: String,
) -> actor.Next(GatewayState, GatewayMessage) {
  case parse_ready(raw_text) {
    Ok(#(session_id, resume_url)) -> {
      let new_state =
        GatewayState(
          ..state,
          session_id: Some(session_id),
          resume_url: Some(resume_url),
        )
      new_state.on_event(
        types.Ready(types.ReadyPayload(
          session_id: session_id,
          resume_gateway_url: resume_url,
        )),
      )
      actor.continue(new_state)
    }
    Error(_) -> actor.continue(state)
  }
}

fn parse_ready(
  text: String,
) -> Result(#(String, String), json.DecodeError) {
  let decoder = {
    use session_id <- decode.subfield(["d", "session_id"], decode.string)
    use resume_url <- decode.subfield(["d", "resume_gateway_url"], decode.string)
    decode.success(#(session_id, resume_url))
  }
  json.parse(text, decoder)
}

fn handle_message_create(
  state: GatewayState,
  raw_text: String,
) -> actor.Next(GatewayState, GatewayMessage) {
  case parse_message_create(raw_text) {
    Ok(msg) -> {
      state.on_event(types.MessageCreate(msg))
      actor.continue(state)
    }
    Error(_) -> actor.continue(state)
  }
}

fn parse_message_create(
  text: String,
) -> Result(types.ReceivedMessage, json.DecodeError) {
  let user_decoder = {
    use id <- decode.field("id", decode.string)
    use username <- decode.field("username", decode.string)
    use bot <- decode.optional_field("bot", False, decode.bool)
    decode.success(types.User(id: id, username: username, bot: bot))
  }

  let decoder =
    decode.at(["d"], {
      use id <- decode.field("id", decode.string)
      use channel_id <- decode.field("channel_id", decode.string)
      use guild_id <- decode.optional_field(
        "guild_id",
        None,
        decode.optional(decode.string),
      )
      use author <- decode.field("author", user_decoder)
      use content <- decode.optional_field("content", "", decode.string)
      decode.success(types.ReceivedMessage(
        id: id,
        channel_id: channel_id,
        guild_id: guild_id,
        author: author,
        content: content,
      ))
    })

  json.parse(text, decoder)
}

fn parse_invalid_session(text: String) -> Bool {
  let decoder = decode.at(["d"], decode.bool)
  case json.parse(text, decoder) {
    Ok(resumable) -> resumable
    Error(_) -> False
  }
}
