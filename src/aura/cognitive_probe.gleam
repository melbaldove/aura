//// Operator-triggered cognitive delivery probes.
////
//// These probes exercise the production path without requiring the user to
//// manually send provider messages: event ingest, cognitive worker, LLM
//// decision, delivery ledger, and Discord send.

import aura/db
import aura/event
import aura/event_ingest
import aura/time
import aura/xdg
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import simplifile

const deliver_now_body =
  "Hi Melby, can you approve or reject the production rollback within the next 90 minutes? The reconciliation job is blocked, and if we miss this decision window the team will carry incorrect payment state into tomorrow. I need a human decision; Aura can prepare context but must not decide for you. - Operations"

const default_timeout_ms = 120_000

const default_poll_ms = 500

pub type Context {
  Context(
    paths: xdg.Paths,
    db_subject: process.Subject(db.DbMessage),
    event_ingest_subject: process.Subject(event_ingest.IngestMessage),
  )
}

pub type ProbeDecision {
  ProbeDecision(
    event_id: String,
    summary: String,
    citation_count: Int,
    attention_action: String,
    attention_rationale: String,
    work_action: String,
    authority_required: String,
    delivery_target: String,
  )
}

pub type DeliveryState {
  DeliveryState(
    event_id: String,
    status: String,
    target: String,
    channel_id: String,
    error: String,
  )
}

/// Inject a realistic urgent Gmail-shaped event and require live delivery.
pub fn run_deliver_now(ctx: Context) -> Result(String, String) {
  let now = time.now_ms()
  run_deliver_now_with(
    ctx,
    int.to_string(now),
    now,
    default_timeout_ms,
    default_poll_ms,
  )
}

/// Deterministic variant for behavior tests.
pub fn run_deliver_now_with(
  ctx: Context,
  run_id: String,
  now_ms: Int,
  timeout_ms: Int,
  poll_ms: Int,
) -> Result(String, String) {
  let probe_event = deliver_now_event(run_id, now_ms)
  let event_id = probe_event.id
  let deadline_ms = time.now_ms() + timeout_ms

  use _ <- result.try(ensure_decisions_file(ctx.paths))
  event_ingest.ingest(ctx.event_ingest_subject, probe_event)

  use persisted <- result.try(wait_for_event(
    ctx.db_subject,
    event_id,
    deadline_ms,
    poll_ms,
  ))
  use decision <- result.try(wait_for_decision(
    ctx.paths,
    event_id,
    deadline_ms,
    poll_ms,
  ))
  use delivery <- result.try(wait_for_delivery(
    ctx.paths,
    event_id,
    deadline_ms,
    poll_ms,
  ))

  let errors = probe_errors(persisted, decision, delivery)
  case errors {
    [] -> Ok(format_result(persisted, decision, delivery))
    _ ->
      Error(
        "cognitive-test deliver-now failed event_id="
        <> event_id
        <> ": "
        <> string.join(errors, "; "),
      )
  }
}

/// Build the urgent Gmail-shaped event used by the live delivery probe.
pub fn deliver_now_event(run_id: String, now_ms: Int) -> event.AuraEvent {
  let event_id = deliver_now_event_id(run_id)
  let message_id = "<" <> event_id <> "@mail.gmail.com>"
  event.AuraEvent(
    id: event_id,
    source: "gmail-melbournebaldove",
    type_: "email.received",
    subject: "Approval needed within 90 minutes: production rollback",
    time_ms: now_ms,
    tags: dict.from_list([
      #("from", "ops@example.com"),
      #("to", "melby@heyyou.com.au"),
    ]),
    external_id: message_id,
    data: json.object([
      #("uid", json.int(now_ms)),
      #("message_id", json.string(message_id)),
      #("from", json.string("ops@example.com")),
      #("to", json.string("melby@heyyou.com.au")),
      #(
        "subject",
        json.string("Approval needed within 90 minutes: production rollback"),
      ),
      #("date", json.string(int.to_string(now_ms))),
      #("thread_id", json.string(event_id)),
      #("body_text", json.string(deliver_now_body)),
    ])
      |> json.to_string,
  )
}

pub fn deliver_now_event_id(run_id: String) -> String {
  "mail-m" <> safe_id(run_id)
}

/// Parse one persisted cognitive decision line.
pub fn parse_decision_line(line: String) -> Result(ProbeDecision, String) {
  json.parse(line, decision_decoder())
  |> result.map_error(fn(e) {
    "failed to decode probe decision: " <> string.inspect(e)
  })
}

/// Parse one persisted delivery ledger line.
pub fn parse_delivery_line(line: String) -> Result(DeliveryState, String) {
  json.parse(line, delivery_decoder())
  |> result.map_error(fn(e) {
    "failed to decode delivery state: " <> string.inspect(e)
  })
}

fn probe_errors(
  persisted: event.AuraEvent,
  decision: ProbeDecision,
  delivery: DeliveryState,
) -> List(String) {
  []
  |> require(
    body_text(persisted.data) |> string.contains("next 90 minutes"),
    "event body_text does not contain the relative future deadline",
  )
  |> require(
    decision.attention_action == "ask_now",
    "attention must be ask_now for an explicit approval request, got "
      <> decision.attention_action,
  )
  |> require(
    decision.delivery_target != "none",
    "decision delivery target must be user-facing",
  )
  |> require(
    decision.delivery_target == delivery.target,
    "decision delivery target "
      <> decision.delivery_target
      <> " did not match ledger target "
      <> delivery.target,
  )
  |> require(
    delivery.status == "delivered",
    "delivery status must be delivered, got " <> delivery.status,
  )
  |> require(delivery.channel_id != "", "delivery channel_id is empty")
  |> require(decision.citation_count > 0, "decision has no citations")
  |> require(
    string.trim(decision.attention_rationale) != "",
    "decision attention.rationale is empty",
  )
}

fn require(
  errors: List(String),
  condition: Bool,
  message: String,
) -> List(String) {
  case condition {
    True -> errors
    False -> list.append(errors, [message])
  }
}

fn format_result(
  persisted: event.AuraEvent,
  decision: ProbeDecision,
  delivery: DeliveryState,
) -> String {
  "OK: cognitive-test deliver-now"
  <> " event_id="
  <> persisted.id
  <> " attention="
  <> decision.attention_action
  <> " work="
  <> decision.work_action
  <> " authority="
  <> decision.authority_required
  <> " delivery="
  <> delivery.status
  <> " target="
  <> delivery.target
  <> " channel_id="
  <> delivery.channel_id
  <> " citations="
  <> int.to_string(decision.citation_count)
}

fn wait_for_event(
  db_subject: process.Subject(db.DbMessage),
  event_id: String,
  deadline_ms: Int,
  poll_ms: Int,
) -> Result(event.AuraEvent, String) {
  case db.get_event(db_subject, event_id) {
    Ok(option.Some(e)) -> Ok(e)
    Ok(option.None) -> {
      case time.now_ms() >= deadline_ms {
        True ->
          Error("timed out waiting for probe event persistence: " <> event_id)
        False -> {
          process.sleep(poll_ms)
          wait_for_event(db_subject, event_id, deadline_ms, poll_ms)
        }
      }
    }
    Error(err) -> Error("failed to load probe event: " <> err)
  }
}

fn wait_for_decision(
  paths: xdg.Paths,
  event_id: String,
  deadline_ms: Int,
  poll_ms: Int,
) -> Result(ProbeDecision, String) {
  case find_decision(paths, event_id) {
    Ok(option.Some(decision)) -> Ok(decision)
    Ok(option.None) -> {
      case time.now_ms() >= deadline_ms {
        True -> Error("timed out waiting for cognitive decision: " <> event_id)
        False -> {
          process.sleep(poll_ms)
          wait_for_decision(paths, event_id, deadline_ms, poll_ms)
        }
      }
    }
    Error(err) -> Error(err)
  }
}

fn wait_for_delivery(
  paths: xdg.Paths,
  event_id: String,
  deadline_ms: Int,
  poll_ms: Int,
) -> Result(DeliveryState, String) {
  case find_delivery(paths, event_id) {
    Ok(option.Some(delivery)) -> Ok(delivery)
    Ok(option.None) -> {
      case time.now_ms() >= deadline_ms {
        True -> Error("timed out waiting for delivery state: " <> event_id)
        False -> {
          process.sleep(poll_ms)
          wait_for_delivery(paths, event_id, deadline_ms, poll_ms)
        }
      }
    }
    Error(err) -> Error(err)
  }
}

fn find_decision(
  paths: xdg.Paths,
  event_id: String,
) -> Result(option.Option(ProbeDecision), String) {
  use content <- result.try(read_optional(xdg.decisions_path(paths)))
  content
  |> string.split("\n")
  |> list.reverse
  |> find_decision_line(event_id)
}

fn find_delivery(
  paths: xdg.Paths,
  event_id: String,
) -> Result(option.Option(DeliveryState), String) {
  use content <- result.try(read_optional(xdg.deliveries_path(paths)))
  content
  |> string.split("\n")
  |> list.reverse
  |> find_delivery_line(event_id)
}

fn find_decision_line(
  lines: List(String),
  event_id: String,
) -> Result(option.Option(ProbeDecision), String) {
  case lines {
    [] -> Ok(option.None)
    [line, ..rest] -> {
      case string.contains(line, "\"event_id\":\"" <> event_id <> "\"") {
        True -> {
          use decision <- result.try(parse_decision_line(line))
          Ok(option.Some(decision))
        }
        False -> find_decision_line(rest, event_id)
      }
    }
  }
}

fn find_delivery_line(
  lines: List(String),
  event_id: String,
) -> Result(option.Option(DeliveryState), String) {
  case lines {
    [] -> Ok(option.None)
    [line, ..rest] -> {
      case string.contains(line, "\"event_id\":\"" <> event_id <> "\"") {
        True -> {
          use delivery <- result.try(parse_delivery_line(line))
          Ok(option.Some(delivery))
        }
        False -> find_delivery_line(rest, event_id)
      }
    }
  }
}

fn ensure_decisions_file(paths: xdg.Paths) -> Result(Nil, String) {
  let dir = xdg.cognitive_dir(paths)
  let path = xdg.decisions_path(paths)
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(e) {
      "failed to create cognitive directory "
      <> dir
      <> ": "
      <> string.inspect(e)
    }),
  )
  case simplifile.is_file(path) {
    Ok(True) -> Ok(Nil)
    Ok(False) ->
      simplifile.write(path, "")
      |> result.map_error(fn(e) {
        "failed to create decisions log " <> path <> ": " <> string.inspect(e)
      })
    Error(e) ->
      Error(
        "failed to inspect decisions log " <> path <> ": " <> string.inspect(e),
      )
  }
}

fn read_optional(path: String) -> Result(String, String) {
  case simplifile.is_file(path) {
    Ok(True) ->
      simplifile.read(path)
      |> result.map_error(fn(e) {
        "failed to read " <> path <> ": " <> string.inspect(e)
      })
    Ok(False) -> Ok("")
    Error(e) ->
      Error("failed to inspect " <> path <> ": " <> string.inspect(e))
  }
}

fn body_text(data: String) -> String {
  case json.parse(data, decode.at(["body_text"], decode.string)) {
    Ok(value) -> value
    Error(_) -> ""
  }
}

fn decision_decoder() {
  use event_id <- decode.field("event_id", decode.string)
  use summary <- decode.field("summary", decode.string)
  use citations <- decode.field("citations", decode.list(decode.string))
  use attention <- decode.field("attention", attention_decoder())
  use work <- decode.field("work", work_decoder())
  use authority <- decode.field("authority", authority_decoder())
  use delivery <- decode.field("delivery", delivery_decision_decoder())
  decode.success(ProbeDecision(
    event_id: event_id,
    summary: summary,
    citation_count: list.length(citations),
    attention_action: attention.0,
    attention_rationale: attention.1,
    work_action: work,
    authority_required: authority,
    delivery_target: delivery,
  ))
}

fn attention_decoder() {
  use action <- decode.field("action", decode.string)
  use rationale <- decode.field("rationale", decode.string)
  decode.success(#(action, rationale))
}

fn work_decoder() {
  use action <- decode.field("action", decode.string)
  decode.success(action)
}

fn authority_decoder() {
  use required <- decode.field("required", decode.string)
  decode.success(required)
}

fn delivery_decision_decoder() {
  use target <- decode.field("target", decode.string)
  decode.success(target)
}

fn delivery_decoder() {
  use event_id <- decode.field("event_id", decode.string)
  use status <- decode.field("status", decode.string)
  use target <- decode.field("target", decode.string)
  use channel_id <- decode.field("channel_id", decode.string)
  use error <- decode.optional_field("error", "", decode.string)
  decode.success(DeliveryState(
    event_id: event_id,
    status: status,
    target: target,
    channel_id: channel_id,
    error: error,
  ))
}

fn safe_id(value: String) -> String {
  value
  |> string.replace(" ", "-")
  |> string.replace("/", "-")
  |> string.replace(":", "-")
  |> string.replace("@", "-")
  |> string.replace("<", "-")
  |> string.replace(">", "-")
}
