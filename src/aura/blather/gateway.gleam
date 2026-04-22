//// Blather WebSocket gateway actor. Connects to `<base_url>/ws/events`
//// over plain TCP (Blather runs plain `ws://` over the VPN — TLS
//// terminates elsewhere if at all), parses each JSON frame via
//// `blather/types.parse_event`, and delegates to an `on_event` callback
//// supplied by the poller.
////
//// Much simpler than `aura/discord/gateway` because Blather has no
//// heartbeat/identify/opcode protocol — auth is in the URL query
//// string at upgrade time, and every subsequent frame is a plain
//// event envelope. We respond to server pings at the FFI layer; the
//// actor just sees well-formed text frames.

import aura/blather/types
import gleam/erlang/process
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import logging

// ---------------------------------------------------------------------------
// State + messages
// ---------------------------------------------------------------------------

pub type GatewayState {
  GatewayState(on_event: fn(types.GatewayEvent) -> Nil)
}

pub type GatewayMessage {
  WsText(String)
  WsClosed
  WsError(String)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Connect to a Blather server and start an actor that forwards decoded
/// events to `on_event`. `base_url` should include any reverse-proxy
/// prefix (e.g. `http://10.0.0.2:18100/api`) — same convention as
/// `blather/rest.gleam`. `api_key` is appended as a query parameter on
/// the WS upgrade.
pub fn connect(
  base_url: String,
  api_key: String,
  on_event: fn(types.GatewayEvent) -> Nil,
) -> Result(actor.Started(process.Subject(GatewayMessage)), String) {
  use #(host, port, ws_path) <- result.try(resolve_ws_target(base_url, api_key))

  actor.new_with_initialiser(10_000, fn(self_subject) {
    let _ws_pid = ws_connect(host, port, ws_path, self_subject)
    let selector =
      process.new_selector()
      |> process.select(self_subject)
    Ok(
      actor.initialised(GatewayState(on_event: on_event))
      |> actor.selecting(selector)
      |> actor.returning(self_subject),
    )
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map_error(fn(err) { "Blather gateway start failed: " <> string.inspect(err) })
}

// ---------------------------------------------------------------------------
// URL parsing (pure, testable)
// ---------------------------------------------------------------------------

/// From a Blather `base_url` (e.g. `http://10.0.0.2:18100/api`) and an
/// `api_key`, produce `#(host, port, path)` suitable for the plain-TCP
/// WS FFI. The path includes `base_url`'s path prefix plus `/ws/events`
/// plus the `?api_key=<key>` query.
pub fn resolve_ws_target(
  base_url: String,
  api_key: String,
) -> Result(#(String, Int, String), String) {
  use parsed <- result.try(
    uri.parse(base_url)
    |> result.map_error(fn(_) { "Blather url is not a valid URI: " <> base_url }),
  )
  use host <- result.try(
    parsed.host
    |> option.to_result("Blather url missing host: " <> base_url),
  )
  let port = option.unwrap(parsed.port, default_port(parsed.scheme))
  let prefix = case parsed.path {
    "" -> ""
    "/" -> ""
    p -> strip_trailing_slash(p)
  }
  let path =
    prefix
    <> "/ws/events?api_key="
    <> uri.percent_encode(api_key)
  Ok(#(host, port, path))
}

fn default_port(scheme: Option(String)) -> Int {
  case scheme {
    Some("https") | Some("wss") -> 443
    Some("http") | Some("ws") -> 80
    _ -> 80
  }
}

fn strip_trailing_slash(s: String) -> String {
  case string.ends_with(s, "/") {
    True -> string.drop_end(s, 1)
    False -> s
  }
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "aura_ws_plain_ffi", "connect")
fn ws_connect_raw(
  host: String,
  port: Int,
  path: String,
  callback_pid: process.Pid,
) -> process.Pid

fn ws_connect(
  host: String,
  port: Int,
  path: String,
  subject: process.Subject(GatewayMessage),
) -> process.Pid {
  let bridge_pid = spawn_bridge(subject)
  ws_connect_raw(host, port, path, bridge_pid)
}

@external(erlang, "aura_gateway_bridge", "spawn_bridge")
fn spawn_bridge(subject: process.Subject(GatewayMessage)) -> process.Pid

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
      logging.log(
        logging.Info,
        "[blather-gateway] WsClosed — supervisor will restart",
      )
      actor.stop_abnormal("WebSocket closed")
    }
    WsError(err) -> {
      logging.log(logging.Error, "[blather-gateway] WsError: " <> err)
      actor.stop_abnormal("WebSocket error: " <> err)
    }
  }
}

fn handle_text(
  state: GatewayState,
  text: String,
) -> actor.Next(GatewayState, GatewayMessage) {
  case types.parse_event(text) {
    Ok(event) -> {
      state.on_event(event)
      actor.continue(state)
    }
    Error(err) -> {
      logging.log(
        logging.Warning,
        "[blather-gateway] Dropped unparseable frame: "
          <> string.inspect(err)
          <> " raw="
          <> string.slice(text, 0, 120),
      )
      actor.continue(state)
    }
  }
}

