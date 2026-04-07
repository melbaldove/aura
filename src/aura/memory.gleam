import aura/time
import aura/types
import gleam/json
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

/// Append a log entry to the domain's log.jsonl
pub fn append_domain_log(
  domain_dir: String,
  entry: String,
) -> Result(Nil, String) {
  let path = domain_dir <> "/log.jsonl"
  let line =
    json.object([
      #("timestamp", json.int(time.now_ms())),
      #("entry", json.string(entry)),
    ])
    |> json.to_string
  case simplifile.append(path, line <> "\n") {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error("Failed to append to log: " <> string.inspect(e))
  }
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
