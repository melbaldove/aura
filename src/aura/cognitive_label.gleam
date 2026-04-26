//// Correction label capture for cognitive replay.
////
//// Labels are operator/user feedback about real cognitive decisions. They are
//// append-only JSONL records, not policy by themselves. Replay turns them into
//// evidence about which text policy, concern context, or validator behavior
//// needs adjustment.

import aura/memory
import aura/structured_memory
import aura/time
import aura/xdg
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type CaptureResult {
  CaptureResult(
    event_id: String,
    label: String,
    attention_any: List(String),
    path: String,
  )
}

pub fn capture(
  paths: xdg.Paths,
  event_id: String,
  label: String,
  expected_attention: String,
  note: String,
) -> Result(CaptureResult, String) {
  let event_id = string.trim(event_id)
  let label = string.lowercase(string.trim(label))
  let expected_attention = string.lowercase(string.trim(expected_attention))
  let note = string.trim(note)

  use _ <- result.try(validate_event_id(event_id))
  use _ <- result.try(validate_label(label))
  use _ <- result.try(validate_attention(expected_attention))
  use _ <- result.try(structured_memory.security_scan(note))
  use _ <- result.try(
    simplifile.create_directory_all(xdg.cognitive_dir(paths))
    |> result.map_error(fn(e) {
      "failed to create cognitive directory "
      <> xdg.cognitive_dir(paths)
      <> ": "
      <> string.inspect(e)
    }),
  )

  let attention_any = case expected_attention {
    "" -> default_attention_for_label(label)
    attention -> [attention]
  }

  use _ <- result.try(memory.append_jsonl(
    xdg.labels_path(paths),
    json.object([
      #("timestamp_ms", json.int(time.now_ms())),
      #("event_id", json.string(event_id)),
      #("label", json.string(label)),
      #("note", json.string(note)),
      #("attention_any", json.array(attention_any, json.string)),
      #("work_any", json.array([], json.string)),
      #("authority_any", json.array([], json.string)),
      #("min_citations", json.int(1)),
      #("min_gaps", json.int(0)),
      #("require_gap_contains", json.string("")),
    ]),
  ))

  Ok(CaptureResult(
    event_id: event_id,
    label: label,
    attention_any: attention_any,
    path: xdg.labels_path(paths),
  ))
}

pub fn allowed_labels() -> List(String) {
  [
    "false_interrupt",
    "missed_important",
    "bad_deferral",
    "useful_digest",
    "bad_concern_match",
    "bad_authority_call",
    "verification_burden_reduced",
    "planning_burden_reduced",
  ]
}

pub fn diagnosis_for_label(label: String) -> String {
  case string.lowercase(label) {
    "false_interrupt" -> "policy:attention.md too interruptive"
    "missed_important" -> "policy:attention.md missed urgency"
    "bad_deferral" -> "policy:attention.md wrong timing"
    "useful_digest" -> "policy:attention.md digest calibration"
    "bad_concern_match" -> "concerns/*.md or policy:concerns.md"
    "bad_authority_call" -> "policy:authority.md"
    "verification_burden_reduced" -> "policy:work.md verification"
    "planning_burden_reduced" -> "policy:work.md planning"
    "" -> ""
    _ -> "unclassified correction surface"
  }
}

fn validate_event_id(event_id: String) -> Result(Nil, String) {
  case event_id == "" || string.contains(event_id, "\n") {
    True -> Error("event_id is required and must fit on one line")
    False -> Ok(Nil)
  }
}

fn validate_label(label: String) -> Result(Nil, String) {
  case list.contains(allowed_labels(), label) {
    True -> Ok(Nil)
    False ->
      Error(
        "invalid cognitive label '"
        <> label
        <> "'. Use one of: "
        <> string.join(allowed_labels(), ", "),
      )
  }
}

fn validate_attention(attention: String) -> Result(Nil, String) {
  case attention {
    "" | "record" | "digest" | "surface_now" | "ask_now" -> Ok(Nil)
    _ ->
      Error(
        "invalid expected attention '"
        <> attention
        <> "'. Use record, digest, surface_now, ask_now, or omit it.",
      )
  }
}

fn default_attention_for_label(label: String) -> List(String) {
  case label {
    "false_interrupt" -> ["record", "digest"]
    "missed_important" | "bad_deferral" -> ["surface_now", "ask_now"]
    "useful_digest" -> ["digest"]
    _ -> []
  }
}
