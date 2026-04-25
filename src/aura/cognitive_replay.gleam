//// Replay persisted cognitive events against current policy and labels.
////
//// Replay is the feedback loop that lets structure earn its way into code:
//// rerun real events through today's model/policy context, compare against
//// human labels, and record drift without notifying the user.

import aura/cognitive_decision
import aura/cognitive_delivery
import aura/cognitive_worker
import aura/db
import aura/time
import aura/xdg
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import simplifile

const default_timeout_ms = 120_000

const default_poll_ms = 500

pub type Context {
  Context(
    paths: xdg.Paths,
    db_subject: process.Subject(db.DbMessage),
    cognitive_subject: process.Subject(cognitive_worker.Message),
    delivery_subject: option.Option(process.Subject(cognitive_delivery.Message)),
  )
}

pub type Label {
  Label(
    event_id: String,
    note: String,
    attention_any: List(String),
    work_any: List(String),
    authority_any: List(String),
    min_citations: Int,
    min_gaps: Int,
    require_gap_contains: String,
  )
}

pub type ReplayDecision {
  ReplayDecision(
    event_id: String,
    attention_action: String,
    work_action: String,
    authority_required: String,
    citation_count: Int,
    gaps: List(String),
  )
}

pub type CaseResult {
  CaseResult(
    event_id: String,
    passed: Bool,
    skipped: Bool,
    attention_action: String,
    work_action: String,
    authority_required: String,
    citation_count: Int,
    gap_count: Int,
    errors: List(String),
  )
}

/// Run all labels in `~/.local/share/aura/cognitive/labels.jsonl`.
pub fn run_labels(ctx: Context) -> Result(String, String) {
  run_labels_with(ctx, default_timeout_ms, default_poll_ms)
}

/// Run labels with deterministic timeouts. Exposed for behavior tests.
pub fn run_labels_with(
  ctx: Context,
  timeout_ms: Int,
  poll_ms: Int,
) -> Result(String, String) {
  use labels <- result.try(load_labels(ctx.paths))
  let results = replay_label_list(ctx, labels, timeout_ms, poll_ms, [])
  let report = format_report(results)
  case list.any(results, fn(result) { !result.passed && !result.skipped }) {
    True -> Error(report)
    False -> Ok(report)
  }
}

/// Load replay labels from the cognitive labels JSONL file.
pub fn load_labels(paths: xdg.Paths) -> Result(List(Label), String) {
  let path = xdg.labels_path(paths)
  case simplifile.is_file(path) {
    Ok(False) -> Ok([])
    Error(e) ->
      Error(
        "failed to inspect replay labels " <> path <> ": " <> string.inspect(e),
      )
    Ok(True) -> {
      use content <- result.try(
        simplifile.read(path)
        |> result.map_error(fn(e) {
          "failed to read replay labels " <> path <> ": " <> string.inspect(e)
        }),
      )
      content
      |> string.split("\n")
      |> parse_label_lines(1, [])
    }
  }
}

/// Parse one JSONL replay label line.
pub fn parse_label_line(line: String) -> Result(Label, String) {
  json.parse(line, label_decoder())
  |> result.map_error(fn(e) {
    "failed to decode replay label: " <> string.inspect(e)
  })
}

/// Parse one persisted cognitive decision line into replay comparison fields.
pub fn parse_decision_line(line: String) -> Result(ReplayDecision, String) {
  use decision <- result.try(cognitive_decision.decode_response(line))
  Ok(ReplayDecision(
    event_id: decision.event_id,
    attention_action: decision.attention.action,
    work_action: decision.work.action,
    authority_required: decision.authority.required,
    citation_count: list.length(decision.citations),
    gaps: decision.gaps,
  ))
}

fn replay_label_list(
  ctx: Context,
  labels: List(Label),
  timeout_ms: Int,
  poll_ms: Int,
  acc: List(CaseResult),
) -> List(CaseResult) {
  case labels {
    [] -> list.reverse(acc)
    [label, ..rest] -> {
      let result = replay_label(ctx, label, timeout_ms, poll_ms)
      replay_label_list(ctx, rest, timeout_ms, poll_ms, [result, ..acc])
    }
  }
}

fn replay_label(
  ctx: Context,
  label: Label,
  timeout_ms: Int,
  poll_ms: Int,
) -> CaseResult {
  case has_expectation(label) {
    False ->
      CaseResult(
        event_id: label.event_id,
        passed: True,
        skipped: True,
        attention_action: "",
        work_action: "",
        authority_required: "",
        citation_count: 0,
        gap_count: 0,
        errors: ["label has no expectations"],
      )
    True -> {
      let deadline_ms = time.now_ms() + timeout_ms
      case db.get_event(ctx.db_subject, label.event_id) {
        Error(err) ->
          failed_case(label.event_id, ["failed to load event: " <> err])
        Ok(option.None) -> failed_case(label.event_id, ["event not found"])
        Ok(option.Some(_event)) -> {
          case count_decisions(ctx.paths, label.event_id) {
            Error(err) -> failed_case(label.event_id, [err])
            Ok(before_count) -> {
              suppress_delivery(ctx.delivery_subject, label.event_id)
              cognitive_worker.build_context(
                ctx.cognitive_subject,
                label.event_id,
              )
              case
                wait_for_new_decision(
                  ctx.paths,
                  label.event_id,
                  before_count,
                  deadline_ms,
                  poll_ms,
                )
              {
                Error(err) -> failed_case(label.event_id, [err])
                Ok(decision) -> {
                  let errors = expectation_errors(label, decision)
                  CaseResult(
                    event_id: label.event_id,
                    passed: errors == [],
                    skipped: False,
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
        "cognitive replay must not notify",
      )
    option.None -> Nil
  }
}

fn wait_for_new_decision(
  paths: xdg.Paths,
  event_id: String,
  before_count: Int,
  deadline_ms: Int,
  poll_ms: Int,
) -> Result(ReplayDecision, String) {
  case decisions_for_event(paths, event_id) {
    Error(err) -> Error(err)
    Ok(decisions) -> {
      case list.drop(decisions, before_count) {
        [decision, ..] -> Ok(decision)
        [] -> {
          case time.now_ms() >= deadline_ms {
            True -> Error("timed out waiting for replay decision: " <> event_id)
            False -> {
              process.sleep(poll_ms)
              wait_for_new_decision(
                paths,
                event_id,
                before_count,
                deadline_ms,
                poll_ms,
              )
            }
          }
        }
      }
    }
  }
}

fn count_decisions(paths: xdg.Paths, event_id: String) -> Result(Int, String) {
  use decisions <- result.try(decisions_for_event(paths, event_id))
  Ok(list.length(decisions))
}

fn decisions_for_event(
  paths: xdg.Paths,
  event_id: String,
) -> Result(List(ReplayDecision), String) {
  let path = xdg.decisions_path(paths)
  case simplifile.is_file(path) {
    Ok(False) -> Ok([])
    Error(e) ->
      Error(
        "failed to inspect decisions log " <> path <> ": " <> string.inspect(e),
      )
    Ok(True) -> {
      use content <- result.try(
        simplifile.read(path)
        |> result.map_error(fn(e) {
          "failed to read decisions log " <> path <> ": " <> string.inspect(e)
        }),
      )
      content
      |> string.split("\n")
      |> collect_decisions(event_id, [])
    }
  }
}

fn collect_decisions(
  lines: List(String),
  event_id: String,
  acc: List(ReplayDecision),
) -> Result(List(ReplayDecision), String) {
  case lines {
    [] -> Ok(list.reverse(acc))
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case trimmed == "" || !string.contains(trimmed, event_id) {
        True -> collect_decisions(rest, event_id, acc)
        False -> {
          use decision <- result.try(parse_decision_line(trimmed))
          case decision.event_id == event_id {
            True -> collect_decisions(rest, event_id, [decision, ..acc])
            False -> collect_decisions(rest, event_id, acc)
          }
        }
      }
    }
  }
}

fn parse_label_lines(
  lines: List(String),
  line_number: Int,
  acc: List(Label),
) -> Result(List(Label), String) {
  case lines {
    [] -> Ok(list.reverse(acc))
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case trimmed {
        "" -> parse_label_lines(rest, line_number + 1, acc)
        _ -> {
          use label <- result.try(
            parse_label_line(trimmed)
            |> result.map_error(fn(err) {
              "labels.jsonl:" <> int.to_string(line_number) <> ": " <> err
            }),
          )
          parse_label_lines(rest, line_number + 1, [label, ..acc])
        }
      }
    }
  }
}

fn expectation_errors(label: Label, decision: ReplayDecision) -> List(String) {
  []
  |> require_allowed(
    decision.attention_action,
    label.attention_any,
    "attention.action",
  )
  |> require_allowed(decision.work_action, label.work_any, "work.action")
  |> require_allowed(
    decision.authority_required,
    label.authority_any,
    "authority.required",
  )
  |> require(
    decision.citation_count >= label.min_citations,
    "citations "
      <> int.to_string(decision.citation_count)
      <> " < "
      <> int.to_string(label.min_citations),
  )
  |> require(
    list.length(decision.gaps) >= label.min_gaps,
    "gaps "
      <> int.to_string(list.length(decision.gaps))
      <> " < "
      <> int.to_string(label.min_gaps),
  )
  |> require_gap_contains(decision.gaps, label.require_gap_contains)
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

fn has_expectation(label: Label) -> Bool {
  label.attention_any != []
  || label.work_any != []
  || label.authority_any != []
  || label.min_citations > 0
  || label.min_gaps > 0
  || string.trim(label.require_gap_contains) != ""
}

fn failed_case(event_id: String, errors: List(String)) -> CaseResult {
  CaseResult(
    event_id: event_id,
    passed: False,
    skipped: False,
    attention_action: "",
    work_action: "",
    authority_required: "",
    citation_count: 0,
    gap_count: 0,
    errors: errors,
  )
}

fn format_report(results: List(CaseResult)) -> String {
  let passed =
    results
    |> list.filter(fn(result) { result.passed && !result.skipped })
    |> list.length
  let skipped =
    results |> list.filter(fn(result) { result.skipped }) |> list.length
  let failed =
    results
    |> list.filter(fn(result) { !result.passed && !result.skipped })
    |> list.length
  let header =
    case failed {
      0 -> "OK: cognitive-replay labels"
      _ -> "cognitive-replay labels failed"
    }
    <> " passed="
    <> int.to_string(passed)
    <> " failed="
    <> int.to_string(failed)
    <> " skipped="
    <> int.to_string(skipped)
    <> " total="
    <> int.to_string(list.length(results))

  [header, ..list.map(results, format_case_result)]
  |> string.join("\n")
}

fn format_case_result(result: CaseResult) -> String {
  let status = case result.skipped, result.passed {
    True, _ -> "SKIP"
    False, True -> "PASS"
    False, False -> "FAIL"
  }
  status
  <> " "
  <> result.event_id
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

fn label_decoder() {
  use event_id <- decode.field("event_id", decode.string)
  use note <- decode.optional_field("note", "", decode.string)
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
  decode.success(Label(
    event_id: event_id,
    note: note,
    attention_any: attention_any,
    work_any: work_any,
    authority_any: authority_any,
    min_citations: min_citations,
    min_gaps: min_gaps,
    require_gap_contains: require_gap_contains,
  ))
}
