import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

/// Extract tags from an event payload using source-specific rules.
///
/// Returns an empty dict for unknown sources, unknown event types on a
/// known source, and malformed JSON payloads. This is the rules-only
/// ("cheap path") tagger that runs on every event at ingestion — LLM
/// fuzzy tagging (entities, topics, priority) is a later phase.
///
/// The fail-soft semantics are deliberate: this runs in the ingest hot
/// path and a misbehaving MCP server must not poison downstream work.
/// The AuraEvent is still deduped and persisted; only the tag column is
/// best-effort. A parse failure here is not silent — the caller is free
/// to check for an empty dict and log — but the tagger itself never
/// crashes the ingest actor.
pub fn tag(
  source: String,
  type_: String,
  data: String,
) -> Dict(String, String) {
  case parse(data) {
    Ok(payload) -> tag_payload(source, type_, payload)
    Error(_) -> dict.new()
  }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

fn tag_payload(
  source: String,
  type_: String,
  payload: Dynamic,
) -> Dict(String, String) {
  case source_family(source), type_ {
    Gmail, "email.received" | Gmail, "email.sent" -> tag_gmail(payload)
    Linear, "issue.commented" -> tag_linear_comment(payload)
    Linear, "issue.updated" -> tag_linear_issue(payload)
    Linear, "issue.created" -> tag_linear_issue(payload)
    _, _ -> dict.new()
  }
}

type SourceFamily {
  Gmail
  Linear
  UnknownSource
}

fn source_family(source: String) -> SourceFamily {
  case source {
    "gmail" -> Gmail
    "linear" -> Linear
    _ ->
      case string.starts_with(source, "gmail-") {
        True -> Gmail
        False -> UnknownSource
      }
  }
}

// ---------------------------------------------------------------------------
// Gmail rules
// ---------------------------------------------------------------------------

fn tag_gmail(payload: Dynamic) -> Dict(String, String) {
  let entries =
    [
      #("from", extract_string(payload, ["from"])),
      #("to", extract_first_recipient(payload)),
      #("thread_id", extract_string(payload, ["thread_id"])),
      #("subject_line", extract_string(payload, ["subject"])),
    ]
    |> list.filter_map(keep_ok)

  dict.from_list(entries)
}

/// `to` may be a raw string (single recipient) or a JSON array (many).
/// We take the first element for arrays and the whole string otherwise.
fn extract_first_recipient(payload: Dynamic) -> Result(String, Nil) {
  // Try string first; fall back to list[0].
  case decode.run(payload, decode.at(["to"], decode.string)) {
    Ok("") -> Error(Nil)
    Ok(value) -> Ok(value)
    Error(_) ->
      case
        decode.run(payload, decode.at(["to"], decode.list(decode.string)))
      {
        Ok([first, ..]) -> Ok(first)
        _ -> Error(Nil)
      }
  }
}

// ---------------------------------------------------------------------------
// Linear rules
// ---------------------------------------------------------------------------

fn tag_linear_comment(payload: Dynamic) -> Dict(String, String) {
  let entries =
    [
      #("ticket_id", extract_string(payload, ["issue", "identifier"])),
      #("author", extract_string(payload, ["comment", "user", "email"])),
    ]
    |> list.filter_map(keep_ok)

  dict.from_list(entries)
}

fn tag_linear_issue(payload: Dynamic) -> Dict(String, String) {
  let entries =
    [
      #("ticket_id", extract_string(payload, ["issue", "identifier"])),
      #("author", extract_string(payload, ["issue", "assignee", "email"])),
      #("status", extract_string(payload, ["issue", "state", "name"])),
    ]
    |> list.filter_map(keep_ok)

  dict.from_list(entries)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parse(data: String) -> Result(Dynamic, json.DecodeError) {
  json.parse(data, decode.dynamic)
}

fn extract_string(
  payload: Dynamic,
  path: List(String),
) -> Result(String, Nil) {
  case decode.run(payload, decode.at(path, decode.string)) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

fn keep_ok(
  entry: #(String, Result(String, Nil)),
) -> Result(#(String, String), Nil) {
  let #(key, result) = entry
  case result {
    Ok(value) -> Ok(#(key, value))
    Error(_) -> Error(Nil)
  }
}
