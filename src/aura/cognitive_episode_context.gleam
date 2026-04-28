//// Prompt context for recent user-facing cognitive attention outputs.
////
//// The delivery ledger tells us which cognitive decisions reached a user
//// surface. Conversation history stores the exact assistant message the user
//// saw. This module joins those two ordinary records into prompt context so
//// natural feedback can refer to Aura's own recent outputs.

import aura/db
import aura/xdg
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

const conversation_message_limit = 80

const rendered_message_limit = 700

const rendered_field_limit = 320

pub type RecentOutput {
  RecentOutput(
    event_id: String,
    attention_action: String,
    target: String,
    summary: String,
    rationale: String,
    user_facing_message: String,
  )
}

type LedgerEntry {
  LedgerEntry(
    event_id: String,
    status: String,
    attention_action: String,
    target: String,
    channel_id: String,
    summary: String,
    rationale: String,
  )
}

/// Render recent delivered attention outputs for the current Discord channel.
pub fn render(
  paths: xdg.Paths,
  db_subject: Subject(db.DbMessage),
  channel_id: String,
  limit: Int,
) -> Result(String, String) {
  use outputs <- result.try(load(paths, db_subject, channel_id, limit))
  case outputs {
    [] -> Ok("")
    _ ->
      outputs
      |> list.map(render_output)
      |> string.join("\n")
      |> fn(items) {
        Ok(
          "\n\n## Recent Aura Attention Outputs"
          <> "\nThese are recent user-facing cognitive outputs Aura sent in this channel. When the user gives feedback about notifications, digests, surfacing, asks, or missed alerts, resolve against these outputs before calling search_events. Use search_events only when the referent is not present or remains ambiguous."
          <> "\n"
          <> items,
        )
      }
  }
}

/// Load recent delivered attention outputs for the current Discord channel.
pub fn load(
  paths: xdg.Paths,
  db_subject: Subject(db.DbMessage),
  channel_id: String,
  limit: Int,
) -> Result(List(RecentOutput), String) {
  use entries <- result.try(read_ledger_entries(paths))
  use messages <- result.try(db.load_messages(
    db_subject,
    "discord:" <> channel_id,
    conversation_message_limit,
  ))

  entries
  |> newest_unique_entries
  |> list.filter(fn(entry) {
    entry.status == "delivered" && entry.channel_id == channel_id
  })
  |> list.take(limit)
  |> list.map(fn(entry) {
    RecentOutput(
      event_id: entry.event_id,
      attention_action: entry.attention_action,
      target: entry.target,
      summary: entry.summary,
      rationale: entry.rationale,
      user_facing_message: find_user_facing_message(messages, entry.event_id),
    )
  })
  |> Ok
}

fn render_output(output: RecentOutput) -> String {
  "- event_id: "
  <> output.event_id
  <> "\n  attention: "
  <> output.attention_action
  <> "\n  target: "
  <> output.target
  <> "\n  summary: "
  <> clip_one_line(output.summary, rendered_field_limit)
  <> case output.rationale {
    "" -> ""
    rationale ->
      "\n  rationale: " <> clip_one_line(rationale, rendered_field_limit)
  }
  <> case output.user_facing_message {
    "" -> ""
    message ->
      "\n  user_facing_message: "
      <> clip_one_line(message, rendered_message_limit)
  }
}

fn find_user_facing_message(
  messages: List(db.StoredMessage),
  event_id: String,
) -> String {
  messages
  |> list.reverse
  |> list.find_map(fn(message) {
    case
      message.role == "assistant"
      && message_mentions_event(message.content, event_id)
    {
      True -> Ok(message.content)
      False -> Error(Nil)
    }
  })
  |> result.unwrap("")
}

fn message_mentions_event(content: String, event_id: String) -> Bool {
  string.contains(content, "Event: " <> event_id)
  || string.contains(content, "[" <> event_id <> "]")
}

fn clip_one_line(text: String, limit: Int) -> String {
  let one_line =
    text
    |> string.replace("\n", " ")
    |> string.replace("\r", " ")
    |> string.trim
  case string.length(one_line) > limit {
    True -> string.slice(one_line, 0, limit) <> "..."
    False -> one_line
  }
}

fn read_ledger_entries(paths: xdg.Paths) -> Result(List(LedgerEntry), String) {
  case simplifile.is_file(xdg.deliveries_path(paths)) {
    Ok(False) -> Ok([])
    Ok(True) -> {
      use content <- result.try(
        simplifile.read(xdg.deliveries_path(paths))
        |> result.map_error(fn(e) { string.inspect(e) }),
      )

      content
      |> string.split("\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> list.try_map(parse_ledger_line)
    }
    Error(err) -> Error(string.inspect(err))
  }
}

fn parse_ledger_line(line: String) -> Result(LedgerEntry, String) {
  json.parse(line, ledger_decoder())
  |> result.map_error(fn(e) { string.inspect(e) })
}

fn ledger_decoder() {
  use event_id <- decode.field("event_id", decode.string)
  use status <- decode.field("status", decode.string)
  use attention_action <- decode.optional_field(
    "attention_action",
    "",
    decode.string,
  )
  use target <- decode.optional_field("target", "", decode.string)
  use channel_id <- decode.optional_field("channel_id", "", decode.string)
  use summary <- decode.optional_field("summary", "", decode.string)
  use rationale <- decode.optional_field("rationale", "", decode.string)
  decode.success(LedgerEntry(
    event_id: event_id,
    status: status,
    attention_action: attention_action,
    target: target,
    channel_id: channel_id,
    summary: summary,
    rationale: rationale,
  ))
}

fn newest_unique_entries(entries: List(LedgerEntry)) -> List(LedgerEntry) {
  collect_newest_unique(list.reverse(entries), [], [])
}

fn collect_newest_unique(
  entries: List(LedgerEntry),
  seen_ids: List(String),
  acc: List(LedgerEntry),
) -> List(LedgerEntry) {
  case entries {
    [] -> acc
    [entry, ..rest] -> {
      case list.contains(seen_ids, entry.event_id) {
        True -> collect_newest_unique(rest, seen_ids, acc)
        False ->
          collect_newest_unique(
            rest,
            [entry.event_id, ..seen_ids],
            list.append(acc, [entry]),
          )
      }
    }
  }
}
