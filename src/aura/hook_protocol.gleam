//// Hook-layer wire protocol (ADR 038). Line-framed; each command is a single
//// line. Structured commands (`event`/`notify`/`ask`) carry one line of JSON.
//// `decision <correlation_id>` is a plain token. Pure parsing/formatting — no
//// IO. Every function here is testable without a terminal.

import aura/mcp/jsonrpc
import gleam/dynamic.{nil as dynamic_nil, type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type HookCommand {
  HookEvent(
    source: String,
    type_: String,
    subject: String,
    external_id: String,
    data: String,
  )
  HookNotify(
    source: String,
    rule: String,
    target: String,
    text: String,
    external_id: String,
  )
  HookAsk(
    source: String,
    rule: String,
    correlation_id: String,
    target: String,
    text: String,
    buttons: List(String),
    ttl_minutes: Int,
  )
  HookDecision(correlation_id: String)
}

pub const default_ttl_minutes = 60

// Discord message cap is 2000 chars; leave room for the button chrome and the
// provenance prefix.
const text_limit = 1800

const default_buttons = ["Resolved", "Abort"]

/// Prepend `[hook:<source>/<rule>]` (or `[hook:<source>]` when there is no
/// rule) provenance to lane-2 message text. Applied once at the ctl boundary
/// so the ledger and conversation history record exactly what the user saw.
pub fn apply_provenance(source: String, rule: String, text: String) -> String {
  case rule {
    "" -> "[hook:" <> source <> "] " <> text
    _ -> "[hook:" <> source <> "/" <> rule <> "] " <> text
  }
}

/// Parse one socket line into a `HookCommand`.
/// Commands: `event <json>`, `notify <json>`, `ask <json>`, `decision <id>`.
pub fn parse(line: String) -> Result(HookCommand, String) {
  parse_named(string.trim(line))
}

fn parse_named(line: String) -> Result(HookCommand, String) {
  use name <- result.try(first_word(line))
  let rest = string.drop_start(line, string.length(name))
  case name {
    "event" -> parse_event(string.trim(rest))
    "notify" -> parse_notify(string.trim(rest))
    "ask" -> parse_ask(string.trim(rest))
    "decision" -> parse_decision(string.trim(rest))
    _ -> Error("unknown hook command: " <> name)
  }
}

fn first_word(line: String) -> Result(String, String) {
  let parts = string.split(line, on: " ")
  case parts {
    [first, ..] if first != "" -> Ok(first)
    _ -> Error("empty hook command")
  }
}

fn parse_decision(rest: String) -> Result(HookCommand, String) {
  case string.trim(rest) {
    "" -> Error("decision requires a correlation_id")
    cid -> {
      use _ <- result.try(validate_id_field("correlation_id", cid))
      Ok(HookDecision(correlation_id: cid))
    }
  }
}

fn parse_event(payload: String) -> Result(HookCommand, String) {
  let decoder = {
    use source <- decode.field("source", decode.string)
    use type_ <- decode.optional_field("type", "hook.event", decode.string)
    use subject <- decode.field("subject", decode.string)
    use external_id <- decode.field("external_id", decode.string)
    use data <- decode.optional_field("data", dynamic_nil(), decode.dynamic)
    decode.success(#(source, type_, subject, external_id, data))
  }
  let parsed =
    case json.parse(payload, using: decoder) {
      Ok(v) -> Ok(v)
      Error(e) -> Error("invalid event payload: " <> string.inspect(e))
    }
  use #(source, type_, subject, external_id, data) <- result.try(parsed)
  use _ <- result.try(validate_source(source))
  use _ <- result.try(validate_id_field("external_id", external_id))
  let data_str = case json.to_string(jsonrpc.dynamic_to_json(data)) {
    "null" -> "{}"
    s -> s
  }
  Ok(HookEvent(
    source: source,
    type_: type_,
    subject: subject,
    external_id: external_id,
    data: data_str,
  ))
}

fn parse_notify(payload: String) -> Result(HookCommand, String) {
  let decoder = {
    use source <- decode.field("source", decode.string)
    use rule <- decode.optional_field("rule", "", decode.string)
    use target <- decode.field("target", decode.string)
    use text <- decode.field("text", decode.string)
    use external_id <- decode.optional_field("external_id", "", decode.string)
    decode.success(#(source, rule, target, text, external_id))
  }
  let parsed =
    case json.parse(payload, using: decoder) {
      Ok(v) -> Ok(v)
      Error(e) -> Error("invalid notify payload: " <> string.inspect(e))
    }
  use #(source, rule, target, text, external_id) <- result.try(parsed)
  use _ <- result.try(validate_source(source))
  use _ <- result.try(validate_id_field("external_id", external_id))
  use _ <- result.try(validate_target(target))
  use _ <- result.try(validate_text(text))
  Ok(HookNotify(
    source: source,
    rule: rule,
    target: target,
    text: text,
    external_id: external_id,
  ))
}

fn parse_ask(payload: String) -> Result(HookCommand, String) {
  let decoder = {
    use source <- decode.field("source", decode.string)
    use rule <- decode.optional_field("rule", "", decode.string)
    use correlation_id <- decode.field("correlation_id", decode.string)
    use target <- decode.field("target", decode.string)
    use text <- decode.field("text", decode.string)
    use buttons <- decode.optional_field(
      "buttons",
      default_buttons,
      decode.list(decode.string),
    )
    use ttl_minutes <- decode.optional_field(
      "ttl_minutes",
      default_ttl_minutes,
      decode.int,
    )
    decode.success(
      #(source, rule, correlation_id, target, text, buttons, ttl_minutes),
    )
  }
  let parsed =
    case json.parse(payload, using: decoder) {
      Ok(v) -> Ok(v)
      Error(e) -> Error("invalid ask payload: " <> string.inspect(e))
    }
  use #(source, rule, correlation_id, target, text, buttons, ttl_minutes) <-
    result.try(parsed)
  use _ <- result.try(validate_source(source))
  use _ <- result.try(validate_id_field("correlation_id", correlation_id))
  use _ <- result.try(validate_target(target))
  use _ <- result.try(validate_text(text))
  use _ <- result.try(validate_buttons(buttons))
  Ok(HookAsk(
    source: source,
    rule: rule,
    correlation_id: correlation_id,
    target: target,
    text: text,
    buttons: buttons,
    ttl_minutes: ttl_minutes,
  ))
}

fn validate_source(source: String) -> Result(Nil, String) {
  case source {
    "" -> Error("source must not be empty")
    _ -> Ok(Nil)
  }
}

fn validate_id_field(field: String, value: String) -> Result(Nil, String) {
  case value {
    "" -> Error(field <> " must not be empty")
    _ ->
      case string.contains(value, "|") {
        True -> Error(field <> " must not contain a vertical bar")
        False -> Ok(Nil)
      }
  }
}

fn validate_target(target: String) -> Result(Nil, String) {
  case target {
    "" -> Error("target must not be empty")
    _ -> Ok(Nil)
  }
}

fn validate_text(text: String) -> Result(Nil, String) {
  case string.length(text) > text_limit {
    True -> Error("text exceeds " <> string.inspect(text_limit) <> " chars")
    False -> Ok(Nil)
  }
}

fn validate_buttons(buttons: List(String)) -> Result(Nil, String) {
  case list.length(buttons) {
    n if n < 1 || n > 5 -> Error("buttons must be between 1 and 5")
    _ ->
      case list.any(buttons, fn(b) { string.contains(b, "|") }) {
        True -> Error("button labels must not contain a vertical bar")
        False -> Ok(Nil)
      }
  }
}

/// `"xask|" <> correlation_id <> "|" <> choice` — the Discord button custom_id.
/// IDs are validated to exclude `|`, and `xor`-free of Discord's forbidden
/// markers, so they survive round-trips.
pub fn encode_ask_custom_id(correlation_id: String, choice: String) -> String {
  "xask|" <> correlation_id <> "|" <> choice
}

/// Inverse of `encode_ask_custom_id`. Errors on non-xask custom ids.
pub fn decode_ask_custom_id(
  custom_id: String,
) -> Result(#(String, String), String) {
  let parts = string.split(custom_id, on: "|")
  case parts {
    ["xask", correlation_id, choice] -> Ok(#(correlation_id, choice))
    _ -> Error("not an xask custom id")
  }
}

// Response line constructors — single source of truth for the wire format.

pub fn resp_ok_event_queued(event_id: String) -> String {
  "QUEUED " <> event_id
}

pub fn resp_ok_deduped() -> String {
  "DEDUPED"
}

pub fn resp_delivered(event_id: String) -> String {
  "DELIVERED " <> event_id
}

pub fn resp_resolved(correlation_id: String, choice: String) -> String {
  "RESOLVED " <> correlation_id <> " " <> choice
}

pub fn resp_pending() -> String {
  "PENDING"
}

pub fn resp_expired(correlation_id: String) -> String {
  "EXPIRED " <> correlation_id
}

pub fn resp_unknown() -> String {
  "UNKNOWN"
}

pub fn resp_error(msg: String) -> String {
  "ERROR: " <> msg
}