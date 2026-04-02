import aura/cron
import aura/notification
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import tom

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type ScheduleConfig {
  ScheduleConfig(
    name: String,
    schedule_type: String,
    every: String,
    cron: String,
    skill: String,
    args: String,
    domains: List(String),
    model: String,
    enabled: Bool,
  )
}

pub type ScheduleEntry {
  ScheduleEntry(config: ScheduleConfig, last_run_ms: Int)
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

/// Convert epoch milliseconds to #(minute, hour, day, month, weekday).
/// Weekday uses 0=Sunday..6=Saturday convention.
@external(erlang, "aura_scheduler_ffi", "ms_to_time_parts")
pub fn ms_to_time_parts(ms: Int) -> #(Int, Int, Int, Int, Int)

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parse `[[schedule]]` array-of-tables from a TOML string.
/// Returns Ok([]) for empty input.
pub fn parse_schedules(
  toml_string: String,
) -> Result(List(ScheduleConfig), String) {
  case string.trim(toml_string) {
    "" -> Ok([])
    trimmed -> {
      use doc <- result.try(
        tom.parse(trimmed)
        |> result.map_error(fn(e) { "TOML parse error: " <> parse_error_string(e) }),
      )

      let schedules_result =
        tom.get_array(doc, ["schedule"])
        |> result.unwrap([])

      list.try_map(schedules_result, parse_one_schedule)
    }
  }
}

fn parse_one_schedule(toml: tom.Toml) -> Result(ScheduleConfig, String) {
  case toml {
    tom.Table(tbl) -> parse_schedule_table(tbl)
    tom.InlineTable(tbl) -> parse_schedule_table(tbl)
    _ -> Error("Expected table in [[schedule]] array")
  }
}

fn parse_schedule_table(
  tbl: dict.Dict(String, tom.Toml),
) -> Result(ScheduleConfig, String) {
  use name <- result.try(
    tom.get_string(tbl, ["name"])
    |> result.map_error(fn(_) { "Missing schedule.name" }),
  )
  use schedule_type <- result.try(
    tom.get_string(tbl, ["type"])
    |> result.map_error(fn(_) { "Missing schedule.type" }),
  )
  use skill <- result.try(
    tom.get_string(tbl, ["skill"])
    |> result.map_error(fn(_) { "Missing schedule.skill" }),
  )
  use domains_raw <- result.try(
    tom.get_array(tbl, ["domains"])
    |> result.map_error(fn(_) { "Missing schedule.domains" }),
  )

  let every =
    tom.get_string(tbl, ["every"])
    |> result.unwrap("")
  let cron_str =
    tom.get_string(tbl, ["cron"])
    |> result.unwrap("")
  let args =
    tom.get_string(tbl, ["args"])
    |> result.unwrap("")
  let model =
    tom.get_string(tbl, ["model"])
    |> result.unwrap("zai/glm-5-turbo")
  let enabled =
    tom.get_bool(tbl, ["enabled"])
    |> result.unwrap(True)

  let domains = extract_strings(domains_raw)

  Ok(ScheduleConfig(
    name: name,
    schedule_type: schedule_type,
    every: every,
    cron: cron_str,
    skill: skill,
    args: args,
    domains: domains,
    model: model,
    enabled: enabled,
  ))
}

fn extract_strings(values: List(tom.Toml)) -> List(String) {
  values
  |> list.filter_map(fn(v) {
    case v {
      tom.String(s) -> Ok(s)
      _ -> Error(Nil)
    }
  })
}

fn parse_error_string(e: tom.ParseError) -> String {
  case e {
    tom.Unexpected(got, expected) ->
      "unexpected " <> got <> ", expected " <> expected
    tom.KeyAlreadyInUse(key) -> "key already in use: " <> string.join(key, ".")
  }
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/// Serialize a list of schedule configs back to TOML format.
pub fn serialize_schedules(schedules: List(ScheduleConfig)) -> String {
  schedules
  |> list.map(serialize_one)
  |> string.join("\n")
}

fn serialize_one(config: ScheduleConfig) -> String {
  let lines = ["[[schedule]]"]
  let lines = list.append(lines, [
    "name = " <> quote(config.name),
  ])
  let lines = list.append(lines, [
    "type = " <> quote(config.schedule_type),
  ])
  let lines = case config.schedule_type {
    "cron" ->
      list.append(lines, ["cron = " <> quote(config.cron)])
    _ ->
      list.append(lines, ["every = " <> quote(config.every)])
  }
  let lines = list.append(lines, [
    "skill = " <> quote(config.skill),
  ])
  let lines = case config.args {
    "" -> lines
    a -> list.append(lines, ["args = " <> quote(a)])
  }
  let domains_str =
    config.domains
    |> list.map(quote)
    |> string.join(", ")
  let lines = list.append(lines, [
    "domains = [" <> domains_str <> "]",
  ])
  let lines = list.append(lines, [
    "model = " <> quote(config.model),
  ])
  let lines = list.append(lines, [
    "enabled = " <> bool_string(config.enabled),
  ])
  string.join(lines, "\n") <> "\n"
}

fn quote(s: String) -> String {
  "\"" <> s <> "\""
}

fn bool_string(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

// ---------------------------------------------------------------------------
// Due logic
// ---------------------------------------------------------------------------

/// Determine if a schedule entry is due to run at the given time (epoch ms).
pub fn is_due(entry: ScheduleEntry, now_ms: Int) -> Bool {
  case entry.config.enabled {
    False -> False
    True ->
      case entry.config.schedule_type {
        "interval" -> is_due_interval(entry, now_ms)
        "cron" -> is_due_cron(entry, now_ms)
        _ -> False
      }
  }
}

fn is_due_interval(entry: ScheduleEntry, now_ms: Int) -> Bool {
  case notification.parse_interval(entry.config.every) {
    Ok(interval_ms) -> now_ms - entry.last_run_ms >= interval_ms
    Error(_) -> False
  }
}

fn is_due_cron(entry: ScheduleEntry, now_ms: Int) -> Bool {
  case cron.parse(entry.config.cron) {
    Ok(expr) -> {
      let #(minute, hour, day, month, weekday) = ms_to_time_parts(now_ms)
      let matches =
        cron.matches(
          expr,
          minute: minute,
          hour: hour,
          day: day,
          month: month,
          weekday: weekday,
        )
      // Prevent double-firing: only fire if last_run was before the
      // start of the current minute
      let start_of_minute = now_ms - { now_ms % 60_000 }
      matches && entry.last_run_ms < start_of_minute
    }
    Error(_) -> False
  }
}
