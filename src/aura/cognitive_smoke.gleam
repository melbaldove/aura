//// Production-local cognitive smoke checks.
////
//// These checks exercise the running daemon, DB actor, event ingest actor, and
//// configured cognitive LLM without requiring the user to generate provider
//// events by hand. Smoke events are synthetic and must remain side-effect safe.

import aura/cognitive_event
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

const gmail_rel42_body = "AURA synthetic cognitive smoke test. Please review REL-42 tomorrow. This is not a real user request and must not notify, dispatch, mutate memory, or learn preferences."

const default_timeout_ms = 120_000

const default_poll_ms = 500

pub type Context {
  Context(
    paths: xdg.Paths,
    db_subject: process.Subject(db.DbMessage),
    event_ingest_subject: process.Subject(event_ingest.IngestMessage),
  )
}

pub type SmokeDecision {
  SmokeDecision(
    event_id: String,
    summary: String,
    citation_count: Int,
    attention_action: String,
    attention_rationale: String,
    work_action: String,
    authority_required: String,
  )
}

/// Run the Gmail-shaped REL-42 smoke check against the running daemon.
pub fn run_gmail_rel42(ctx: Context) -> Result(String, String) {
  let now = time.now_ms()
  run_gmail_rel42_with(
    ctx,
    int.to_string(now),
    now,
    default_timeout_ms,
    default_poll_ms,
  )
}

/// Run the Gmail-shaped REL-42 smoke check with deterministic timing.
/// Exposed so behavior tests can avoid real waiting and real LLM calls.
pub fn run_gmail_rel42_with(
  ctx: Context,
  run_id: String,
  now_ms: Int,
  timeout_ms: Int,
  poll_ms: Int,
) -> Result(String, String) {
  let smoke_event = gmail_rel42_event(run_id, now_ms)
  let event_id = smoke_event.id
  let deadline_ms = time.now_ms() + timeout_ms

  use _ <- result.try(ensure_decisions_file(ctx.paths))
  event_ingest.ingest(ctx.event_ingest_subject, smoke_event)

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

  let body_text = body_text(persisted.data)
  let evidence =
    persisted |> cognitive_event.from_event |> cognitive_event.extract_evidence
  let errors = smoke_errors(body_text, evidence, decision)

  case errors {
    [] -> Ok(format_result(persisted, body_text, evidence, decision))
    _ ->
      Error("cognitive-smoke gmail-rel42 failed: " <> string.join(errors, "; "))
  }
}

/// Build the synthetic Gmail-shaped event used by the REL-42 smoke check.
pub fn gmail_rel42_event(run_id: String, now_ms: Int) -> event.AuraEvent {
  let event_id = gmail_rel42_event_id(run_id)
  let message_id = "<" <> event_id <> "@aura.invalid>"
  event.AuraEvent(
    id: event_id,
    source: "gmail-smoke",
    type_: "email.received",
    subject: "AURA cognitive smoke test: REL-42",
    time_ms: now_ms,
    tags: dict.from_list([
      #("synthetic", "true"),
      #("smoke", "true"),
      #("smoke_kind", "gmail-rel42"),
      #("from", "aura-smoke@example.invalid"),
      #("to", "melby@heyyou.com.au"),
    ]),
    external_id: message_id,
    data: json.object([
      #("uid", json.int(now_ms)),
      #("message_id", json.string(message_id)),
      #("from", json.string("aura-smoke@example.invalid")),
      #("to", json.string("melby@heyyou.com.au")),
      #("subject", json.string("AURA cognitive smoke test: REL-42")),
      #("date", json.string(int.to_string(now_ms))),
      #("thread_id", json.string(event_id)),
      #("body_text", json.string(gmail_rel42_body)),
      #("synthetic", json.string("true")),
      #("smoke_kind", json.string("gmail-rel42")),
      #("test_run_id", json.string(run_id)),
    ])
      |> json.to_string,
  )
}

pub fn gmail_rel42_event_id(run_id: String) -> String {
  "smoke-gmail-rel42-" <> safe_id(run_id)
}

/// Parse one persisted decision JSONL line.
pub fn parse_decision_line(line: String) -> Result(SmokeDecision, String) {
  json.parse(line, smoke_decision_decoder())
  |> result.map_error(fn(e) {
    "failed to decode smoke decision: " <> string.inspect(e)
  })
}

fn smoke_errors(
  body_text: String,
  evidence: cognitive_event.EvidenceBundle,
  decision: SmokeDecision,
) -> List(String) {
  []
  |> require(body_text != "", "event body_text is empty")
  |> require(
    string.contains(body_text, "REL-42"),
    "event body_text does not contain REL-42",
  )
  |> require(
    string.contains(string.lowercase(body_text), "tomorrow"),
    "event body_text does not contain tomorrow",
  )
  |> require(
    has_atom(evidence, "resource_id", "REL-42"),
    "missing REL-42 evidence",
  )
  |> require(
    has_atom(evidence, "datetime", "tomorrow"),
    "missing tomorrow evidence",
  )
  |> require(decision.citation_count > 0, "decision has no citations")
  |> require(
    string.trim(decision.attention_rationale) != "",
    "decision attention.rationale is empty",
  )
  |> require(
    decision.attention_action == "record",
    "smoke attention must be record",
  )
  |> require(decision.work_action == "none", "smoke work must be none")
  |> require(
    decision.authority_required == "none",
    "smoke authority must be none",
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

fn has_atom(
  evidence: cognitive_event.EvidenceBundle,
  kind: String,
  value: String,
) -> Bool {
  list.any(evidence.atoms, fn(atom) {
    atom.kind == kind && string.lowercase(atom.value) == string.lowercase(value)
  })
}

fn format_result(
  persisted: event.AuraEvent,
  body_text: String,
  evidence: cognitive_event.EvidenceBundle,
  decision: SmokeDecision,
) -> String {
  "OK: cognitive-smoke gmail-rel42"
  <> " event_id="
  <> persisted.id
  <> " body_len="
  <> int.to_string(string.length(body_text))
  <> " evidence_count="
  <> int.to_string(list.length(evidence.atoms))
  <> " attention="
  <> decision.attention_action
  <> " rationale="
  <> one_line(decision.attention_rationale)
  <> " work="
  <> decision.work_action
  <> " authority="
  <> decision.authority_required
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
          Error("timed out waiting for smoke event persistence: " <> event_id)
        False -> {
          process.sleep(poll_ms)
          wait_for_event(db_subject, event_id, deadline_ms, poll_ms)
        }
      }
    }
    Error(err) -> Error("failed to load smoke event: " <> err)
  }
}

fn wait_for_decision(
  paths: xdg.Paths,
  event_id: String,
  deadline_ms: Int,
  poll_ms: Int,
) -> Result(SmokeDecision, String) {
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

fn find_decision(
  paths: xdg.Paths,
  event_id: String,
) -> Result(option.Option(SmokeDecision), String) {
  use content <- result.try(
    simplifile.read(xdg.decisions_path(paths))
    |> result.map_error(fn(e) {
      "failed to read decisions log: " <> string.inspect(e)
    }),
  )
  content
  |> string.split("\n")
  |> list.reverse
  |> find_decision_line(event_id)
}

fn find_decision_line(
  lines: List(String),
  event_id: String,
) -> Result(option.Option(SmokeDecision), String) {
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

fn body_text(data: String) -> String {
  case json.parse(data, decode.at(["body_text"], decode.string)) {
    Ok(value) -> value
    Error(_) -> ""
  }
}

fn smoke_decision_decoder() {
  use event_id <- decode.field("event_id", decode.string)
  use summary <- decode.field("summary", decode.string)
  use citations <- decode.field("citations", decode.list(decode.string))
  use attention <- decode.field("attention", attention_decoder())
  use work <- decode.field("work", work_decoder())
  use authority <- decode.field("authority", authority_decoder())
  decode.success(SmokeDecision(
    event_id: event_id,
    summary: summary,
    citation_count: list.length(citations),
    attention_action: attention.0,
    attention_rationale: attention.1,
    work_action: work,
    authority_required: authority,
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

fn one_line(value: String) -> String {
  value
  |> string.trim
  |> string.replace("\r", " ")
  |> string.replace("\n", " ")
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
