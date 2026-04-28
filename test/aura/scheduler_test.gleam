import aura/scheduler
import gleam/int
import gleam/list
import gleeunit/should

// ---------------------------------------------------------------------------
// parse_schedules
// ---------------------------------------------------------------------------

pub fn parse_interval_schedule_test() {
  let toml =
    "
[[schedule]]
name = \"digest\"
type = \"interval\"
every = \"15m\"
skill = \"daily-digest\"
args = \"--verbose\"
domains = [\"cm2\", \"hy\"]
model = \"zai/glm-5.1\"
enabled = true
"
  let assert Ok(schedules) = scheduler.parse_schedules(toml)
  let assert [s] = schedules
  s.name |> should.equal("digest")
  s.schedule_type |> should.equal("interval")
  s.every |> should.equal("15m")
  s.cron |> should.equal("")
  s.skill |> should.equal("daily-digest")
  s.args |> should.equal("--verbose")
  s.domains |> should.equal(["cm2", "hy"])
  s.model |> should.equal("zai/glm-5.1")
  s.enabled |> should.equal(True)
}

pub fn parse_cron_schedule_test() {
  let toml =
    "
[[schedule]]
name = \"morning-check\"
type = \"cron\"
cron = \"0 9 * * 1\"
skill = \"standup\"
domains = [\"work\"]
model = \"zai/glm-5-turbo\"
enabled = true
"
  let assert Ok(schedules) = scheduler.parse_schedules(toml)
  let assert [s] = schedules
  s.name |> should.equal("morning-check")
  s.schedule_type |> should.equal("cron")
  s.cron |> should.equal("0 9 * * 1")
  s.every |> should.equal("")
  s.skill |> should.equal("standup")
  s.domains |> should.equal(["work"])
  s.model |> should.equal("zai/glm-5-turbo")
  s.enabled |> should.equal(True)
}

pub fn parse_with_defaults_test() {
  let toml =
    "
[[schedule]]
name = \"minimal\"
type = \"interval\"
every = \"1h\"
skill = \"check\"
domains = [\"home\"]
"
  let assert Ok(schedules) = scheduler.parse_schedules(toml)
  let assert [s] = schedules
  s.name |> should.equal("minimal")
  s.model |> should.equal("zai/glm-5-turbo")
  s.enabled |> should.equal(True)
  s.args |> should.equal("")
}

pub fn parse_multiple_schedules_test() {
  let toml =
    "
[[schedule]]
name = \"first\"
type = \"interval\"
every = \"15m\"
skill = \"a\"
domains = [\"x\"]

[[schedule]]
name = \"second\"
type = \"cron\"
cron = \"*/5 * * * *\"
skill = \"b\"
domains = [\"y\", \"z\"]
"
  let assert Ok(schedules) = scheduler.parse_schedules(toml)
  list.length(schedules) |> should.equal(2)
}

pub fn parse_empty_string_test() {
  scheduler.parse_schedules("") |> should.equal(Ok([]))
}

// ---------------------------------------------------------------------------
// serialize -> parse roundtrip
// ---------------------------------------------------------------------------

pub fn serialize_roundtrip_test() {
  let s1 =
    scheduler.ScheduleConfig(
      name: "digest",
      schedule_type: "interval",
      every: "15m",
      cron: "",
      skill: "daily-digest",
      args: "--verbose",
      domains: ["cm2", "hy"],
      model: "zai/glm-5.1",
      enabled: True,
    )
  let s2 =
    scheduler.ScheduleConfig(
      name: "standup",
      schedule_type: "cron",
      every: "",
      cron: "0 9 * * 1",
      skill: "standup",
      args: "",
      domains: ["work"],
      model: "zai/glm-5-turbo",
      enabled: False,
    )

  let toml_str = scheduler.serialize_schedules([s1, s2])
  let assert Ok(parsed) = scheduler.parse_schedules(toml_str)
  list.length(parsed) |> should.equal(2)

  let assert [p1, p2] = parsed
  p1.name |> should.equal("digest")
  p1.schedule_type |> should.equal("interval")
  p1.every |> should.equal("15m")
  p1.skill |> should.equal("daily-digest")
  p1.args |> should.equal("--verbose")
  p1.domains |> should.equal(["cm2", "hy"])
  p1.model |> should.equal("zai/glm-5.1")
  p1.enabled |> should.equal(True)

  p2.name |> should.equal("standup")
  p2.schedule_type |> should.equal("cron")
  p2.cron |> should.equal("0 9 * * 1")
  p2.skill |> should.equal("standup")
  p2.args |> should.equal("")
  p2.domains |> should.equal(["work"])
  p2.model |> should.equal("zai/glm-5-turbo")
  p2.enabled |> should.equal(False)
}

// ---------------------------------------------------------------------------
// is_due
// ---------------------------------------------------------------------------

pub fn is_due_interval_due_test() {
  let config =
    scheduler.ScheduleConfig(
      name: "test",
      schedule_type: "interval",
      every: "15m",
      cron: "",
      skill: "check",
      args: "",
      domains: ["x"],
      model: "zai/glm-5-turbo",
      enabled: True,
    )
  // 15 minutes = 900_000ms elapsed
  let entry = scheduler.ScheduleEntry(config: config, last_run_ms: 100_000)
  scheduler.is_due(entry, 1_000_000) |> should.be_true
}

pub fn is_due_interval_not_due_test() {
  let config =
    scheduler.ScheduleConfig(
      name: "test",
      schedule_type: "interval",
      every: "15m",
      cron: "",
      skill: "check",
      args: "",
      domains: ["x"],
      model: "zai/glm-5-turbo",
      enabled: True,
    )
  // Only 5 minutes elapsed (300_000ms < 900_000ms)
  let entry = scheduler.ScheduleEntry(config: config, last_run_ms: 700_000)
  scheduler.is_due(entry, 1_000_000) |> should.be_false
}

pub fn is_due_disabled_test() {
  let config =
    scheduler.ScheduleConfig(
      name: "test",
      schedule_type: "interval",
      every: "15m",
      cron: "",
      skill: "check",
      args: "",
      domains: ["x"],
      model: "zai/glm-5-turbo",
      enabled: False,
    )
  // Would be due if enabled (enough time elapsed)
  let entry = scheduler.ScheduleEntry(config: config, last_run_ms: 0)
  scheduler.is_due(entry, 1_000_000) |> should.be_false
}

pub fn mark_schedule_run_completed_updates_only_finished_schedule_test() {
  let config_a =
    scheduler.ScheduleConfig(
      name: "a",
      schedule_type: "interval",
      every: "15m",
      cron: "",
      skill: "check-a",
      args: "",
      domains: ["x"],
      model: "zai/glm-5-turbo",
      enabled: True,
    )
  let config_b =
    scheduler.ScheduleConfig(
      name: "b",
      schedule_type: "interval",
      every: "15m",
      cron: "",
      skill: "check-b",
      args: "",
      domains: ["x"],
      model: "zai/glm-5-turbo",
      enabled: True,
    )
  let entries = [
    scheduler.ScheduleEntry(config: config_a, last_run_ms: 100),
    scheduler.ScheduleEntry(config: config_b, last_run_ms: 200),
  ]

  let updated = scheduler.mark_schedule_run_completed(entries, "b", 900)

  list.map(updated, fn(entry) { #(entry.config.name, entry.last_run_ms) })
  |> should.equal([#("a", 100), #("b", 900)])
}

// ---------------------------------------------------------------------------
// is_flare_trigger_due
// ---------------------------------------------------------------------------

pub fn flare_delay_trigger_due_test() {
  scheduler.is_flare_trigger_due(
    "{\"type\":\"delay\",\"rekindle_at_ms\":1000}",
    2000,
  )
  |> should.be_true
}

pub fn flare_delay_trigger_not_due_test() {
  scheduler.is_flare_trigger_due(
    "{\"type\":\"delay\",\"rekindle_at_ms\":3000}",
    2000,
  )
  |> should.be_false
}

pub fn flare_empty_trigger_not_due_test() {
  scheduler.is_flare_trigger_due("[]", 2000)
  |> should.be_false
}

pub fn flare_invalid_trigger_not_due_test() {
  scheduler.is_flare_trigger_due("not json", 2000)
  |> should.be_false
}

pub fn flare_schedule_trigger_due_with_whitespace_test() {
  let now_ms = 1_713_232_800_000
  let #(minute, hour, _day, _month, _weekday) =
    scheduler.ms_to_time_parts(now_ms)
  let cron_str = int.to_string(minute) <> " " <> int.to_string(hour) <> " * * *"

  scheduler.is_flare_trigger_due(
    "{ \"type\": \"schedule\", \"cron\": \"" <> cron_str <> "\" }",
    now_ms,
  )
  |> should.be_true
}

pub fn flare_schedule_trigger_due_with_reordered_fields_test() {
  let now_ms = 1_713_232_800_000
  let #(minute, hour, _day, _month, _weekday) =
    scheduler.ms_to_time_parts(now_ms)
  let cron_str = int.to_string(minute) <> " " <> int.to_string(hour) <> " * * *"

  scheduler.is_flare_trigger_due(
    "{\"cron\":\"" <> cron_str <> "\",\"type\":\"schedule\"}",
    now_ms,
  )
  |> should.be_true
}

// ---------------------------------------------------------------------------
// is_dream_due
// ---------------------------------------------------------------------------

pub fn dream_due_when_cron_matches_and_not_recently_run_test() {
  // "0 4 * * *" = 4:00 AM every day
  // Use ms_to_time_parts to find a time that matches 4:00
  // 4:00 AM = minute 0, hour 4
  // We need a now_ms where ms_to_time_parts returns (0, 4, _, _, _)
  // and last_dream_ms is before the start of this minute
  let now_ms = 1_713_232_800_000
  // Verify this is actually at minute 0, hour 4
  let #(minute, hour, _day, _month, _weekday) =
    scheduler.ms_to_time_parts(now_ms)
  // If this timestamp doesn't land on 4:00, adjust the cron to match
  let cron_str = int.to_string(minute) <> " " <> int.to_string(hour) <> " * * *"
  // last_dream was over a minute ago
  let last_dream_ms = now_ms - 120_000
  scheduler.is_dream_due(cron_str, now_ms, last_dream_ms)
  |> should.be_true
}

pub fn dream_not_due_when_cron_does_not_match_test() {
  // Use a cron that definitely won't match: minute 59, hour 23
  // and a now_ms where that's not the time
  let now_ms = 1_713_232_800_000
  let #(minute, hour, _day, _month, _weekday) =
    scheduler.ms_to_time_parts(now_ms)
  // Pick a different hour to guarantee no match
  let wrong_hour = { hour + 6 } % 24
  let cron_str =
    int.to_string(minute) <> " " <> int.to_string(wrong_hour) <> " * * *"
  scheduler.is_dream_due(cron_str, now_ms, 0)
  |> should.be_false
}

pub fn dream_not_due_when_already_ran_this_minute_test() {
  let now_ms = 1_713_232_800_000
  let #(minute, hour, _day, _month, _weekday) =
    scheduler.ms_to_time_parts(now_ms)
  let cron_str = int.to_string(minute) <> " " <> int.to_string(hour) <> " * * *"
  // last_dream_ms is in the current minute (start_of_minute = now_ms - now_ms % 60000)
  let start_of_minute = now_ms - { now_ms % 60_000 }
  let last_dream_ms = start_of_minute + 5000
  scheduler.is_dream_due(cron_str, now_ms, last_dream_ms)
  |> should.be_false
}

pub fn dream_not_due_with_invalid_cron_test() {
  scheduler.is_dream_due("not a cron", 1_713_232_800_000, 0)
  |> should.be_false
}
