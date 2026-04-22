import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

/// Extract tags from an event payload using source-specific rules.
///
/// Returns an empty dict for unknown sources and malformed JSON payloads.
/// This is the rules-only ("cheap path") tagger that runs on every event
/// at ingestion — LLM fuzzy tagging (entities, topics, priority) is a
/// later phase.
///
/// Dispatch is by `source` family alone. The `type_` parameter is kept
/// in the public signature (reserved for future use) but currently
/// unused: in production every MCP notification arrives as
/// `type_ = "resource.updated"` (see `mcp/pool.gleam`), so keying on
/// type would make every tagging arm dead code. Instead, for a known
/// source family we attempt all known field extractions; missing fields
/// simply don't tag (see `keep_ok`).
///
/// The fail-soft semantics are deliberate: this runs in the ingest hot
/// path and a misbehaving MCP server must not poison downstream work.
/// The AuraEvent is still deduped and persisted; only the tag column is
/// best-effort. A parse failure here is not silent — the caller is free
/// to check for an empty dict and log — but the tagger itself never
/// crashes the ingest actor.
pub fn tag(
  source: String,
  _type_: String,
  data: String,
) -> Dict(String, String) {
  case source_family(source), parse(data) {
    Gmail, Ok(payload) -> tag_gmail(payload)
    Linear, Ok(payload) -> tag_linear(payload)
    _, _ -> dict.new()
  }
}

// ---------------------------------------------------------------------------
// Source family
// ---------------------------------------------------------------------------

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
      case
        string.starts_with(source, "gmail-"),
        string.starts_with(source, "linear-")
      {
        True, _ -> Gmail
        _, True -> Linear
        _, _ -> UnknownSource
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

/// Extract linear tags. Tries every known linear field path — missing
/// fields simply don't tag. A "commented" event has `comment.user.email`
/// (populates `author`) but no `issue.state.name`; an "updated" event
/// has `issue.state.name` (populates `status`) and often
/// `issue.assignee.email` (populates `author`). Each path is probed
/// independently, so payload shape drives the output.
fn tag_linear(payload: Dynamic) -> Dict(String, String) {
  let entries =
    [
      #("ticket_id", extract_string(payload, ["issue", "identifier"])),
      #("author", extract_linear_author(payload)),
      #("status", extract_string(payload, ["issue", "state", "name"])),
    ]
    |> list.filter_map(keep_ok)

  dict.from_list(entries)
}

/// Prefer `comment.user.email` (comment events) and fall back to
/// `issue.assignee.email` (issue lifecycle events). Either may be
/// missing; a missing value produces `Error(Nil)` and no tag.
fn extract_linear_author(payload: Dynamic) -> Result(String, Nil) {
  case extract_string(payload, ["comment", "user", "email"]) {
    Ok(value) -> Ok(value)
    Error(_) -> extract_string(payload, ["issue", "assignee", "email"])
  }
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
