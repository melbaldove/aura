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

/// Append an event to data_dir/events.jsonl
pub fn append_event(data_dir: String, event: types.Event) -> Result(Nil, String) {
  let path = data_dir <> "/events.jsonl"
  append_jsonl(path, types.event_to_json(event))
}

/// Append an anchor to data_dir/domains/<domain>/anchors.jsonl
pub fn append_anchor(
  domain_dir: String,
  anchor: types.Anchor,
) -> Result(Nil, String) {
  let path = domain_dir <> "/anchors.jsonl"
  append_jsonl(path, types.anchor_to_json(anchor))
}

/// Append a JSON value to the daily log for a domain
pub fn append_log(
  domain_dir: String,
  date: String,
  json_value: json.Json,
) -> Result(Nil, String) {
  let dir = domain_dir <> "/logs"
  let path = dir <> "/" <> date <> ".jsonl"
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(e) {
      "Failed to create log directory " <> dir <> ": " <> string.inspect(e)
    }),
  )
  append_jsonl(path, json_value)
}

/// Read the last N anchors from the domain's anchors.jsonl
pub fn read_anchors(
  domain_dir: String,
  limit: Int,
) -> Result(List(String), String) {
  let path = domain_dir <> "/anchors.jsonl"
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

/// Read a daily log for a domain. Returns "" if missing.
pub fn read_daily_log(
  domain_dir: String,
  date: String,
) -> Result(String, String) {
  let path = domain_dir <> "/logs/" <> date <> ".jsonl"
  case simplifile.read(path) {
    Ok(content) -> Ok(content)
    Error(_) -> Ok("")
  }
}

/// Read a weekly summary for a domain. Returns "" if missing.
pub fn read_summary(
  data_dir: String,
  domain: String,
  week: String,
) -> Result(String, String) {
  let path =
    data_dir <> "/domains/" <> domain <> "/summaries/" <> week <> ".md"
  case simplifile.read(path) {
    Ok(content) -> Ok(content)
    Error(_) -> Ok("")
  }
}

/// Write a weekly summary for a domain
pub fn write_summary(
  data_dir: String,
  domain: String,
  week: String,
  content: String,
) -> Result(Nil, String) {
  let dir = data_dir <> "/domains/" <> domain <> "/summaries"
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
