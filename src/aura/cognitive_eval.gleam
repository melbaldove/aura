//// Fixture-backed cognitive judgment evals.
////
//// These evals exercise the same production event-ingest and cognitive-worker
//// path as ambient integrations, but fixtures assert decision predicates rather
//// than exact model prose. They are judgment checks, not path smoke checks.

import aura/cognitive_delivery
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

const default_fixture_dir = "evals/cognitive"

const default_timeout_ms = 120_000

const default_poll_ms = 500

pub type Context {
  Context(
    paths: xdg.Paths,
    db_subject: process.Subject(db.DbMessage),
    event_ingest_subject: process.Subject(event_ingest.IngestMessage),
    delivery_subject: option.Option(process.Subject(cognitive_delivery.Message)),
  )
}

pub type Fixture {
  Fixture(
    id: String,
    event_key: String,
    description: String,
    source: String,
    type_: String,
    subject: String,
    tags: dict.Dict(String, String),
    data: dict.Dict(String, String),
    expect: Expectation,
  )
}

pub type Expectation {
  Expectation(
    attention_any: List(String),
    work_any: List(String),
    authority_any: List(String),
    min_citations: Int,
    min_gaps: Int,
    require_gap_contains: String,
  )
}

pub type EvalDecision {
  EvalDecision(
    event_id: String,
    summary: String,
    citation_count: Int,
    attention_action: String,
    attention_rationale: String,
    work_action: String,
    authority_required: String,
    gaps: List(String),
  )
}

pub type CaseResult {
  CaseResult(
    id: String,
    passed: Bool,
    event_id: String,
    attention_action: String,
    work_action: String,
    authority_required: String,
    citation_count: Int,
    gap_count: Int,
    errors: List(String),
  )
}

/// Run all checked-in cognitive eval fixtures against the running daemon.
pub fn run_fixtures(ctx: Context) -> Result(String, String) {
  let now = time.now_ms()
  run_fixtures_with(
    ctx,
    default_fixture_dir,
    int.to_string(now),
    now,
    default_timeout_ms,
    default_poll_ms,
  )
}

/// Run fixtures with deterministic inputs. Exposed for behavior tests.
pub fn run_fixtures_with(
  ctx: Context,
  fixture_dir: String,
  run_id: String,
  now_ms: Int,
  timeout_ms: Int,
  poll_ms: Int,
) -> Result(String, String) {
  use fixtures <- result.try(load_fixtures(fixture_dir))
  case fixtures {
    [] -> Error("no cognitive eval fixtures found in " <> fixture_dir)
    _ -> {
      use _ <- result.try(ensure_decisions_file(ctx.paths))
      let results =
        run_case_list(ctx, fixtures, run_id, now_ms, timeout_ms, poll_ms, [])
      let report = format_report(results)
      case list.any(results, fn(result) { !result.passed }) {
        True -> Error(report)
        False -> Ok(report)
      }
    }
  }
}

/// Load every JSON fixture in a directory, sorted by filename.
pub fn load_fixtures(dir: String) -> Result(List(Fixture), String) {
  use entries <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(e) {
      "failed to read cognitive eval fixture directory "
      <> dir
      <> ": "
      <> string.inspect(e)
    }),
  )

  entries
  |> list.filter(fn(entry) { string.ends_with(entry, ".json") })
  |> list.sort(string.compare)
  |> list.try_map(fn(entry) { load_fixture(dir <> "/" <> entry) })
}

/// Parse one fixture JSON string.
pub fn parse_fixture(raw: String) -> Result(Fixture, String) {
  json.parse(raw, fixture_decoder())
  |> result.map_error(fn(e) {
    "failed to decode cognitive eval fixture: " <> string.inspect(e)
  })
}

/// Build the synthetic event id for a fixture case.
pub fn eval_event_id(case_id: String, run_id: String) -> String {
  "mail-" <> safe_id(case_id) <> "-" <> safe_id(run_id)
}

/// Build the AuraEvent injected for one fixture.
pub fn fixture_event(
  fixture: Fixture,
  run_id: String,
  now_ms: Int,
) -> event.AuraEvent {
  let event_id = eval_event_id(fixture.event_key, run_id)
  let external_id = "<" <> event_id <> "@mail.gmail.com>"
  let base_data =
    dict.from_list([
      #("message_id", external_id),
      #("thread_id", event_id),
      #("subject", fixture.subject),
      #("date", int.to_string(now_ms)),
    ])
  let data = dict.merge(base_data, fixture.data)

  event.AuraEvent(
    id: event_id,
    source: fixture.source,
    type_: fixture.type_,
    subject: fixture.subject,
    time_ms: now_ms,
    tags: fixture.tags,
    external_id: external_id,
    data: json.dict(data, fn(key) { key }, json.string) |> json.to_string,
  )
}

/// Parse one persisted decision JSONL line.
pub fn parse_decision_line(line: String) -> Result(EvalDecision, String) {
  json.parse(line, eval_decision_decoder())
  |> result.map_error(fn(e) {
    "failed to decode eval decision: " <> string.inspect(e)
  })
}

fn run_case_list(
  ctx: Context,
  fixtures: List(Fixture),
  run_id: String,
  now_ms: Int,
  timeout_ms: Int,
  poll_ms: Int,
  acc: List(CaseResult),
) -> List(CaseResult) {
  case fixtures {
    [] -> list.reverse(acc)
    [fixture, ..rest] -> {
      let result = run_case(ctx, fixture, run_id, now_ms, timeout_ms, poll_ms)
      run_case_list(ctx, rest, run_id, now_ms, timeout_ms, poll_ms, [
        result,
        ..acc
      ])
    }
  }
}

fn run_case(
  ctx: Context,
  fixture: Fixture,
  run_id: String,
  now_ms: Int,
  timeout_ms: Int,
  poll_ms: Int,
) -> CaseResult {
  let eval_event = fixture_event(fixture, run_id, now_ms)
  let deadline_ms = time.now_ms() + timeout_ms

  suppress_delivery(ctx.delivery_subject, eval_event.id)
  event_ingest.ingest(ctx.event_ingest_subject, eval_event)

  case wait_for_event(ctx.db_subject, eval_event.id, deadline_ms, poll_ms) {
    Error(err) -> failed_case(fixture.id, eval_event.id, [err])
    Ok(persisted) -> {
      let evidence =
        persisted
        |> cognitive_event.from_event
        |> cognitive_event.extract_evidence
      case wait_for_decision(ctx.paths, eval_event.id, deadline_ms, poll_ms) {
        Error(err) ->
          failed_case(fixture.id, eval_event.id, [
            err,
            "evidence_count=" <> int.to_string(list.length(evidence.atoms)),
          ])
        Ok(decision) -> {
          let errors = expectation_errors(fixture.expect, decision)
          CaseResult(
            id: fixture.id,
            passed: errors == [],
            event_id: eval_event.id,
            attention_action: decision.attention_action,
            work_action: decision.work_action,
            authority_required: decision.authority_required,
            citation_count: decision.citation_count,
            gap_count: list.length(decision.gaps),
            errors: errors,
          )
        }
      }
    }
  }
}

fn suppress_delivery(
  delivery_subject: option.Option(process.Subject(cognitive_delivery.Message)),
  event_id: String,
) -> Nil {
  case delivery_subject {
    option.Some(subject) ->
      cognitive_delivery.suppress_event(
        subject,
        event_id,
        "cognitive eval fixture must not notify",
      )
    option.None -> Nil
  }
}

fn failed_case(
  fixture_id: String,
  event_id: String,
  errors: List(String),
) -> CaseResult {
  CaseResult(
    id: fixture_id,
    passed: False,
    event_id: event_id,
    attention_action: "",
    work_action: "",
    authority_required: "",
    citation_count: 0,
    gap_count: 0,
    errors: errors,
  )
}

fn expectation_errors(
  expect: Expectation,
  decision: EvalDecision,
) -> List(String) {
  []
  |> require(
    string.trim(decision.attention_rationale) != "",
    "attention.rationale is empty",
  )
  |> require_allowed(
    decision.attention_action,
    expect.attention_any,
    "attention.action",
  )
  |> require_allowed(decision.work_action, expect.work_any, "work.action")
  |> require_allowed(
    decision.authority_required,
    expect.authority_any,
    "authority.required",
  )
  |> require(
    decision.citation_count >= expect.min_citations,
    "citations "
      <> int.to_string(decision.citation_count)
      <> " < "
      <> int.to_string(expect.min_citations),
  )
  |> require(
    list.length(decision.gaps) >= expect.min_gaps,
    "gaps "
      <> int.to_string(list.length(decision.gaps))
      <> " < "
      <> int.to_string(expect.min_gaps),
  )
  |> require_gap_contains(decision.gaps, expect.require_gap_contains)
}

fn require_allowed(
  errors: List(String),
  actual: String,
  allowed: List(String),
  label: String,
) -> List(String) {
  case allowed {
    [] -> errors
    _ ->
      require(
        errors,
        list.contains(allowed, actual),
        label
          <> "="
          <> actual
          <> " not in ["
          <> string.join(allowed, ", ")
          <> "]",
      )
  }
}

fn require_gap_contains(
  errors: List(String),
  gaps: List(String),
  needle: String,
) -> List(String) {
  case string.trim(needle) {
    "" -> errors
    trimmed -> {
      let lowered = string.lowercase(trimmed)
      require(
        errors,
        list.any(gaps, fn(gap) {
          string.contains(string.lowercase(gap), lowered)
        }),
        "no gap contains " <> trimmed,
      )
    }
  }
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

fn format_report(results: List(CaseResult)) -> String {
  let passed =
    results |> list.filter(fn(result) { result.passed }) |> list.length
  let failed = list.length(results) - passed
  let header =
    case failed {
      0 -> "OK: cognitive-eval fixtures"
      _ -> "cognitive-eval fixtures failed"
    }
    <> " passed="
    <> int.to_string(passed)
    <> " failed="
    <> int.to_string(failed)
    <> " total="
    <> int.to_string(list.length(results))

  [header, ..list.map(results, format_case_result)]
  |> string.join("\n")
}

fn format_case_result(result: CaseResult) -> String {
  let status = case result.passed {
    True -> "PASS"
    False -> "FAIL"
  }
  status
  <> " "
  <> result.id
  <> " attention="
  <> blank_dash(result.attention_action)
  <> " work="
  <> blank_dash(result.work_action)
  <> " authority="
  <> blank_dash(result.authority_required)
  <> " citations="
  <> int.to_string(result.citation_count)
  <> " gaps="
  <> int.to_string(result.gap_count)
  <> " event_id="
  <> result.event_id
  <> case result.errors {
    [] -> ""
    _ -> " errors=" <> string.join(result.errors, "; ")
  }
}

fn blank_dash(value: String) -> String {
  case value {
    "" -> "-"
    _ -> value
  }
}

fn load_fixture(path: String) -> Result(Fixture, String) {
  use raw <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) {
      "failed to read cognitive eval fixture "
      <> path
      <> ": "
      <> string.inspect(e)
    }),
  )
  parse_fixture(raw)
  |> result.map_error(fn(err) { path <> ": " <> err })
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
          Error("timed out waiting for eval event persistence: " <> event_id)
        False -> {
          process.sleep(poll_ms)
          wait_for_event(db_subject, event_id, deadline_ms, poll_ms)
        }
      }
    }
    Error(err) -> Error("failed to load eval event: " <> err)
  }
}

fn wait_for_decision(
  paths: xdg.Paths,
  event_id: String,
  deadline_ms: Int,
  poll_ms: Int,
) -> Result(EvalDecision, String) {
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
) -> Result(option.Option(EvalDecision), String) {
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
) -> Result(option.Option(EvalDecision), String) {
  case lines {
    [] -> Ok(option.None)
    [line, ..rest] -> {
      case string.contains(line, event_id) {
        True -> {
          use decision <- result.try(parse_decision_line(line))
          case decision.event_id == event_id {
            True -> Ok(option.Some(decision))
            False -> find_decision_line(rest, event_id)
          }
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

fn fixture_decoder() {
  use id <- decode.field("id", decode.string)
  use event_key <- decode.optional_field("event_key", id, decode.string)
  use description <- decode.optional_field("description", "", decode.string)
  use source <- decode.optional_field("source", "gmail", decode.string)
  use type_ <- decode.optional_field("type", "email.received", decode.string)
  use subject <- decode.field("subject", decode.string)
  use tags <- decode.optional_field(
    "tags",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use data <- decode.optional_field(
    "data",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use expect <- decode.field("expect", expectation_decoder())
  decode.success(Fixture(
    id: id,
    event_key: event_key,
    description: description,
    source: source,
    type_: type_,
    subject: subject,
    tags: tags,
    data: data,
    expect: expect,
  ))
}

fn expectation_decoder() {
  use attention_any <- decode.optional_field(
    "attention_any",
    [],
    decode.list(decode.string),
  )
  use work_any <- decode.optional_field(
    "work_any",
    [],
    decode.list(decode.string),
  )
  use authority_any <- decode.optional_field(
    "authority_any",
    [],
    decode.list(decode.string),
  )
  use min_citations <- decode.optional_field("min_citations", 1, decode.int)
  use min_gaps <- decode.optional_field("min_gaps", 0, decode.int)
  use require_gap_contains <- decode.optional_field(
    "require_gap_contains",
    "",
    decode.string,
  )
  decode.success(Expectation(
    attention_any: attention_any,
    work_any: work_any,
    authority_any: authority_any,
    min_citations: min_citations,
    min_gaps: min_gaps,
    require_gap_contains: require_gap_contains,
  ))
}

fn eval_decision_decoder() {
  use event_id <- decode.field("event_id", decode.string)
  use summary <- decode.field("summary", decode.string)
  use citations <- decode.field("citations", decode.list(decode.string))
  use attention <- decode.field("attention", attention_decoder())
  use work <- decode.field("work", work_decoder())
  use authority <- decode.field("authority", authority_decoder())
  use gaps <- decode.field("gaps", decode.list(decode.string))
  decode.success(EvalDecision(
    event_id: event_id,
    summary: summary,
    citation_count: list.length(citations),
    attention_action: attention.0,
    attention_rationale: attention.1,
    work_action: work,
    authority_required: authority,
    gaps: gaps,
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

fn safe_id(value: String) -> String {
  value
  |> string.replace(" ", "-")
  |> string.replace("/", "-")
  |> string.replace(":", "-")
  |> string.replace("@", "-")
  |> string.replace("<", "-")
  |> string.replace(">", "-")
}
