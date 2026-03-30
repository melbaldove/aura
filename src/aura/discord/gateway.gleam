import aura/discord/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import stratus

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
    heartbeat_subject: process.Subject(GatewayMessage),
    on_event: fn(types.GatewayEvent) -> Nil,
  )
}

pub type GatewayMessage {
  SendHeartbeat
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Connect to Discord gateway and start receiving events.
/// Returns the PID of the stratus WebSocket actor.
pub fn connect(
  token: String,
  intents: Int,
  gateway_url: String,
  on_event: fn(types.GatewayEvent) -> Nil,
) -> Result(process.Pid, String) {
  // Convert wss:// to https:// — stratus expects http(s) and upgrades to WS
  let url =
    gateway_url
    |> string.replace("wss://", "https://")
    |> string.replace("ws://", "http://")
  let url = url <> "/?v=10&encoding=json"

  let req = case request.to(url) {
    Ok(r) -> r
    Error(_) -> {
      let assert Ok(r) = request.to("https://gateway.discord.gg/?v=10&encoding=json")
      r
    }
  }

  let heartbeat_subject = process.new_subject()

  let initial_state =
    GatewayState(
      token: token,
      intents: intents,
      sequence: None,
      session_id: None,
      resume_url: None,
      heartbeat_interval: None,
      heartbeat_subject: heartbeat_subject,
      on_event: on_event,
    )

  let heartbeat_selector =
    process.new_selector()
    |> process.select(heartbeat_subject)

  let builder =
    stratus.new_with_initialiser(request: req, init: fn() {
      Ok(
        stratus.initialised(initial_state)
        |> stratus.selecting(heartbeat_selector),
      )
    })
    |> stratus.on_message(handle_message)
    |> stratus.on_close(fn(_state, reason) {
      logging.log(
        logging.Warning,
        "Gateway connection closed: " <> string.inspect(reason),
      )
    })

  case stratus.start(builder) {
    Ok(started) -> Ok(started.pid)
    Error(err) -> Error("Gateway connection failed: " <> string.inspect(err))
  }
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: GatewayState,
  message: stratus.Message(GatewayMessage),
  conn: stratus.Connection,
) -> stratus.Next(GatewayState, GatewayMessage) {
  case message {
    stratus.Text(text) -> handle_text(state, text, conn)
    stratus.Binary(_) -> stratus.continue(state)
    stratus.User(SendHeartbeat) -> handle_heartbeat(state, conn)
  }
}

// ---------------------------------------------------------------------------
// Heartbeat
// ---------------------------------------------------------------------------

fn handle_heartbeat(
  state: GatewayState,
  conn: stratus.Connection,
) -> stratus.Next(GatewayState, GatewayMessage) {
  let payload =
    types.heartbeat_payload(state.sequence)
    |> json.to_string

  case stratus.send_text_message(conn, payload) {
    Ok(_) -> {
      logging.log(logging.Debug, "Sent heartbeat")
    }
    Error(err) -> {
      logging.log(
        logging.Error,
        "Failed to send heartbeat: " <> string.inspect(err),
      )
    }
  }

  // Schedule next heartbeat
  schedule_heartbeat(state)

  stratus.continue(state)
}

fn schedule_heartbeat(state: GatewayState) -> Nil {
  case state.heartbeat_interval {
    Some(interval) -> {
      process.send_after(state.heartbeat_subject, interval, SendHeartbeat)
      Nil
    }
    None -> Nil
  }
}

// ---------------------------------------------------------------------------
// Gateway frame parsing & dispatch
// ---------------------------------------------------------------------------

fn handle_text(
  state: GatewayState,
  text: String,
  conn: stratus.Connection,
) -> stratus.Next(GatewayState, GatewayMessage) {
  // Parse the outer gateway frame: { op, s, t, d }
  let frame_result = parse_gateway_frame(text)

  case frame_result {
    Ok(#(op, seq, event_name)) -> {
      // Update sequence number if present
      let new_state = case seq {
        Some(s) -> GatewayState(..state, sequence: Some(s))
        None -> state
      }
      handle_opcode(new_state, op, event_name, text, conn)
    }
    Error(err) -> {
      logging.log(
        logging.Warning,
        "Failed to parse gateway frame: " <> string.inspect(err),
      )
      stratus.continue(state)
    }
  }
}

/// Parse the outer gateway frame to extract op, s, and t fields.
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
  conn: stratus.Connection,
) -> stratus.Next(GatewayState, GatewayMessage) {
  case op {
    // Dispatch (op 0)
    0 -> handle_dispatch(state, event_name, raw_text)

    // Heartbeat request from server (op 1)
    1 -> handle_heartbeat(state, conn)

    // Reconnect (op 7)
    7 -> {
      state.on_event(types.Reconnect)
      stratus.stop_abnormal("Reconnect requested by server")
    }

    // Invalid Session (op 9)
    9 -> {
      let resumable = parse_invalid_session(raw_text)
      state.on_event(types.InvalidSession(resumable: resumable))
      case resumable {
        True -> stratus.continue(state)
        False -> stratus.stop_abnormal("Invalid session, not resumable")
      }
    }

    // Hello (op 10)
    10 -> handle_hello(state, raw_text, conn)

    // Heartbeat ACK (op 11)
    11 -> {
      logging.log(logging.Debug, "Received heartbeat ACK")
      state.on_event(types.HeartbeatAck)
      stratus.continue(state)
    }

    // Unknown opcode
    _other -> {
      logging.log(
        logging.Debug,
        "Received unknown opcode: " <> string.inspect(op),
      )
      stratus.continue(state)
    }
  }
}

// ---------------------------------------------------------------------------
// Hello (op 10) — start heartbeat + send Identify
// ---------------------------------------------------------------------------

fn handle_hello(
  state: GatewayState,
  raw_text: String,
  conn: stratus.Connection,
) -> stratus.Next(GatewayState, GatewayMessage) {
  let interval_result = parse_hello_interval(raw_text)

  case interval_result {
    Ok(interval) -> {
      logging.log(
        logging.Info,
        "Received Hello, heartbeat interval: "
          <> string.inspect(interval)
          <> "ms",
      )

      let new_state =
        GatewayState(..state, heartbeat_interval: Some(interval))

      // Notify callback
      new_state.on_event(types.Hello(types.HelloPayload(
        heartbeat_interval: interval,
      )))

      // Schedule initial heartbeat
      schedule_heartbeat(new_state)

      // Send Identify
      let identify =
        types.identify_payload(new_state.token, new_state.intents)
        |> json.to_string

      case stratus.send_text_message(conn, identify) {
        Ok(_) -> {
          logging.log(logging.Info, "Sent Identify")
        }
        Error(err) -> {
          logging.log(
            logging.Error,
            "Failed to send Identify: " <> string.inspect(err),
          )
        }
      }

      stratus.continue(new_state)
    }
    Error(err) -> {
      logging.log(
        logging.Error,
        "Failed to parse Hello payload: " <> string.inspect(err),
      )
      stratus.stop_abnormal("Failed to parse Hello")
    }
  }
}

fn parse_hello_interval(text: String) -> Result(Int, json.DecodeError) {
  let decoder =
    decode.at(["d", "heartbeat_interval"], decode.int)
  json.parse(text, decoder)
}

// ---------------------------------------------------------------------------
// Dispatch (op 0) — route by event name
// ---------------------------------------------------------------------------

fn handle_dispatch(
  state: GatewayState,
  event_name: Option(String),
  raw_text: String,
) -> stratus.Next(GatewayState, GatewayMessage) {
  case event_name {
    Some("READY") -> handle_ready(state, raw_text)
    Some("MESSAGE_CREATE") -> handle_message_create(state, raw_text)
    Some(name) -> {
      logging.log(logging.Debug, "Unhandled dispatch event: " <> name)
      state.on_event(types.UnknownEvent(name: name))
      stratus.continue(state)
    }
    None -> {
      logging.log(logging.Warning, "Dispatch event with no name")
      stratus.continue(state)
    }
  }
}

// ---------------------------------------------------------------------------
// READY
// ---------------------------------------------------------------------------

fn handle_ready(
  state: GatewayState,
  raw_text: String,
) -> stratus.Next(GatewayState, GatewayMessage) {
  let ready_result = parse_ready(raw_text)

  case ready_result {
    Ok(#(session_id, resume_url)) -> {
      logging.log(logging.Info, "Received READY, session: " <> session_id)

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

      stratus.continue(new_state)
    }
    Error(err) -> {
      logging.log(
        logging.Warning,
        "Failed to parse READY payload: " <> string.inspect(err),
      )
      stratus.continue(state)
    }
  }
}

fn parse_ready(
  text: String,
) -> Result(#(String, String), json.DecodeError) {
  let decoder = {
    use session_id <- decode.subfield(
      ["d", "session_id"],
      decode.string,
    )
    use resume_url <- decode.subfield(
      ["d", "resume_gateway_url"],
      decode.string,
    )
    decode.success(#(session_id, resume_url))
  }
  json.parse(text, decoder)
}

// ---------------------------------------------------------------------------
// MESSAGE_CREATE
// ---------------------------------------------------------------------------

fn handle_message_create(
  state: GatewayState,
  raw_text: String,
) -> stratus.Next(GatewayState, GatewayMessage) {
  let msg_result = parse_message_create(raw_text)

  case msg_result {
    Ok(msg) -> {
      state.on_event(types.MessageCreate(msg))
      stratus.continue(state)
    }
    Error(err) -> {
      logging.log(
        logging.Warning,
        "Failed to parse MESSAGE_CREATE: " <> string.inspect(err),
      )
      stratus.continue(state)
    }
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

// ---------------------------------------------------------------------------
// Invalid Session (op 9) — parse "d" as bool
// ---------------------------------------------------------------------------

fn parse_invalid_session(text: String) -> Bool {
  let decoder = decode.at(["d"], decode.bool)
  case json.parse(text, decoder) {
    Ok(resumable) -> resumable
    Error(_) -> False
  }
}
