import aura/types
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Read file content, mapping error to string
pub fn read_file(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(e) {
    "Failed to read " <> path <> ": " <> string.inspect(e)
  })
}

/// Append a JSONL line (json.to_string + "\n") to the given path
pub fn append_jsonl(path: String, json_value: json.Json) -> Result(Nil, String) {
  let line = json.to_string(json_value) <> "\n"
  simplifile.append(to: path, contents: line)
  |> result.map_error(fn(e) {
    "Failed to append to " <> path <> ": " <> string.inspect(e)
  })
}

/// Append an event to base/events.jsonl
pub fn append_event(base: String, event: types.Event) -> Result(Nil, String) {
  let path = base <> "/events.jsonl"
  append_jsonl(path, types.event_to_json(event))
}

/// Append an anchor to base/workstreams/<ws>/anchors.jsonl
pub fn append_anchor(
  base: String,
  workstream: String,
  anchor: types.Anchor,
) -> Result(Nil, String) {
  let path = base <> "/workstreams/" <> workstream <> "/anchors.jsonl"
  append_jsonl(path, types.anchor_to_json(anchor))
}

/// Append a JSON value to the daily log for a workstream
pub fn append_log(
  base: String,
  workstream: String,
  date: String,
  json_value: json.Json,
) -> Result(Nil, String) {
  let dir = base <> "/workstreams/" <> workstream <> "/logs"
  let path = dir <> "/" <> date <> ".jsonl"
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(e) {
      "Failed to create log directory " <> dir <> ": " <> string.inspect(e)
    }),
  )
  append_jsonl(path, json_value)
}

/// Read the last N anchors from the workstream's anchors.jsonl
pub fn read_anchors(
  base: String,
  workstream: String,
  limit: Int,
) -> Result(List(String), String) {
  let path = base <> "/workstreams/" <> workstream <> "/anchors.jsonl"
  use content <- result.try(read_file(path))
  let lines =
    content
    |> string.split("\n")
    |> list.filter(fn(line) { string.length(line) > 0 })
  let count = list.length(lines)
  let drop_count = case count - limit {
    n if n > 0 -> n
    _ -> 0
  }
  Ok(list.drop(lines, drop_count))
}

/// Read a daily log for a workstream. Returns "" if missing.
pub fn read_daily_log(
  base: String,
  workstream: String,
  date: String,
) -> Result(String, String) {
  let path = base <> "/workstreams/" <> workstream <> "/logs/" <> date <> ".jsonl"
  case simplifile.read(path) {
    Ok(content) -> Ok(content)
    Error(_) -> Ok("")
  }
}

/// Read a weekly summary for a workstream. Returns "" if missing.
pub fn read_summary(
  base: String,
  workstream: String,
  week: String,
) -> Result(String, String) {
  let path =
    base <> "/workstreams/" <> workstream <> "/summaries/" <> week <> ".md"
  case simplifile.read(path) {
    Ok(content) -> Ok(content)
    Error(_) -> Ok("")
  }
}

/// Write a weekly summary for a workstream
pub fn write_summary(
  base: String,
  workstream: String,
  week: String,
  content: String,
) -> Result(Nil, String) {
  let dir = base <> "/workstreams/" <> workstream <> "/summaries"
  let path = dir <> "/" <> week <> ".md"
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(e) {
      "Failed to create summaries directory " <> dir <> ": " <> string.inspect(e)
    }),
  )
  simplifile.write(path, content)
  |> result.map_error(fn(e) {
    "Failed to write summary " <> path <> ": " <> string.inspect(e)
  })
}
