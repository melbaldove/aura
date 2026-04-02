import aura/scheduler
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
