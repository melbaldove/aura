import aura/cron
import aura/llm
import aura/models
import aura/notification
import aura/skill
import aura/time
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile
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

pub type SchedulerMessage {
  Tick
  ManageSchedule(
    action: String,
    params: List(#(String, String)),
    reply_to: process.Subject(String),
  )
  ReloadSchedules
}

pub type SchedulerState {
  SchedulerState(
    entries: List(ScheduleEntry),
    skills: List(skill.SkillInfo),
    on_finding: fn(notification.Finding) -> Nil,
    config_path: String,
    self_subject: process.Subject(SchedulerMessage),
  )
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

// ---------------------------------------------------------------------------
// Actor — start / message handler
// ---------------------------------------------------------------------------

/// Start the scheduler actor. Reads schedules.toml from disk,
/// builds entry list, starts OTP actor, schedules first Tick after 60s.
pub fn start(
  config_path: String,
  skills: List(skill.SkillInfo),
  on_finding: fn(notification.Finding) -> Nil,
) -> Result(process.Subject(SchedulerMessage), String) {
  let toml_content = case simplifile.read(config_path) {
    Ok(content) -> content
    Error(_) -> ""
  }

  let entries = case parse_schedules(toml_content) {
    Ok(configs) ->
      list.map(configs, fn(c) { ScheduleEntry(config: c, last_run_ms: 0) })
    Error(e) -> {
      io.println("[scheduler] Failed to parse schedules: " <> e)
      []
    }
  }

  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let state =
        SchedulerState(
          entries: entries,
          skills: skills,
          on_finding: on_finding,
          config_path: config_path,
          self_subject: subject,
        )

      // Schedule first tick after 60 seconds
      process.send_after(subject, 60_000, Tick)

      Ok(actor.initialised(state) |> actor.returning(subject))
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> {
      io.println(
        "[scheduler] Started with "
        <> int.to_string(list.length(entries))
        <> " schedule(s)",
      )
      Ok(started.data)
    }
    Error(err) ->
      Error("Failed to start scheduler actor: " <> string.inspect(err))
  }
}

fn handle_message(
  state: SchedulerState,
  message: SchedulerMessage,
) -> actor.Next(SchedulerState, SchedulerMessage) {
  case message {
    Tick -> {
      let now_ms = time.now_ms()
      let new_entries =
        list.map(state.entries, fn(entry) {
          case is_due(entry, now_ms) {
            True -> {
              // Spawn execution in a separate process
              let skills = state.skills
              let on_finding = state.on_finding
              let config = entry.config
              process.spawn_unlinked(fn() {
                execute_schedule(config, skills, on_finding)
              })
              ScheduleEntry(..entry, last_run_ms: now_ms)
            }
            False -> entry
          }
        })

      // Schedule next tick in 60 seconds
      process.send_after(state.self_subject, 60_000, Tick)

      actor.continue(SchedulerState(..state, entries: new_entries))
    }

    ReloadSchedules -> {
      let toml_content = case simplifile.read(state.config_path) {
        Ok(content) -> content
        Error(_) -> ""
      }
      let new_entries = case parse_schedules(toml_content) {
        Ok(configs) -> {
          // Preserve last_run_ms for existing schedules by name
          let old_runs =
            list.fold(state.entries, dict.new(), fn(acc, e) {
              dict.insert(acc, e.config.name, e.last_run_ms)
            })
          list.map(configs, fn(c) {
            let last_run = case dict.get(old_runs, c.name) {
              Ok(ms) -> ms
              Error(_) -> 0
            }
            ScheduleEntry(config: c, last_run_ms: last_run)
          })
        }
        Error(e) -> {
          io.println("[scheduler] Failed to reload schedules: " <> e)
          state.entries
        }
      }
      io.println(
        "[scheduler] Reloaded "
        <> int.to_string(list.length(new_entries))
        <> " schedule(s)",
      )
      actor.continue(SchedulerState(..state, entries: new_entries))
    }

    ManageSchedule(action, params, reply_to) -> {
      let #(response, new_state) = handle_manage(state, action, params)
      process.send(reply_to, response)
      actor.continue(new_state)
    }
  }
}

// ---------------------------------------------------------------------------
// Schedule execution
// ---------------------------------------------------------------------------

fn execute_schedule(
  config: ScheduleConfig,
  skills: List(skill.SkillInfo),
  on_finding: fn(notification.Finding) -> Nil,
) -> Nil {
  io.println("[scheduler] Executing schedule: " <> config.name)
  let matched_skill =
    list.find(skills, fn(s) { s.name == config.skill })

  case matched_skill {
    Error(_) -> {
      io.println(
        "[scheduler] Skill '"
        <> config.skill
        <> "' not found, skipping schedule '"
        <> config.name
        <> "'",
      )
      Nil
    }
    Ok(info) -> {
      let args = case config.args {
        "" -> []
        a -> string.split(a, " ")
      }
      case skill.invoke(info, args, 30_000) {
        Ok(result) -> {
          case result.exit_code {
            0 -> {
              let urgency = classify_urgency(config, result.stdout)
              emit_findings(config, result.stdout, urgency, on_finding)
            }
            _code -> {
              io.println(
                "[scheduler] Schedule '"
                <> config.name
                <> "' exited with non-zero code, stderr: "
                <> string.slice(result.stderr, 0, 200),
              )
              Nil
            }
          }
        }
        Error(err) -> {
          io.println(
            "[scheduler] Schedule '"
            <> config.name
            <> "' failed: "
            <> err,
          )
          Nil
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Urgency classification
// ---------------------------------------------------------------------------

fn classify_urgency(config: ScheduleConfig, output: String) -> notification.Urgency {
  case models.build_llm_config(config.model) {
    Error(_) -> notification.Normal
    Ok(llm_config) -> {
      let system_prompt =
        "You are classifying the urgency of a monitoring check result. "
        <> "Respond with exactly one word: URGENT, NORMAL, or LOW."
      let user_prompt =
        "Check name: "
        <> config.name
        <> "\n\nOutput:\n"
        <> string.slice(output, 0, 2000)
      let messages = [
        llm.SystemMessage(system_prompt),
        llm.UserMessage(user_prompt),
      ]
      case llm.chat(llm_config, messages) {
        Ok(response) -> parse_urgency(response)
        Error(_) -> notification.Normal
      }
    }
  }
}

fn parse_urgency(response: String) -> notification.Urgency {
  let trimmed = string.trim(response) |> string.uppercase
  case trimmed {
    "URGENT" -> notification.Urgent
    "LOW" -> notification.Low
    _ -> notification.Normal
  }
}

// ---------------------------------------------------------------------------
// Finding emission
// ---------------------------------------------------------------------------

fn emit_findings(
  config: ScheduleConfig,
  output: String,
  urgency: notification.Urgency,
  on_finding: fn(notification.Finding) -> Nil,
) -> Nil {
  list.each(config.domains, fn(domain) {
    let summary = string.slice(output, 0, 50)
    io.println("[scheduler:" <> config.name <> "] Finding: " <> summary)
    let finding =
      notification.Finding(
        domain: domain,
        summary: output,
        urgency: urgency,
        source: config.name,
      )
    on_finding(finding)
  })
}

// ---------------------------------------------------------------------------
// manage_schedule CRUD handler
// ---------------------------------------------------------------------------

fn handle_manage(
  state: SchedulerState,
  action: String,
  params: List(#(String, String)),
) -> #(String, SchedulerState) {
  case action {
    "list" -> handle_list(state)
    "pause" -> handle_pause(state, params)
    "resume" -> handle_resume(state, params)
    "create" -> handle_create(state, params)
    "delete" -> handle_delete(state, params)
    _ ->
      #(
        "Unknown schedule action: '"
          <> action
          <> "'. Valid actions: list, pause, resume, create, delete",
        state,
      )
  }
}

fn handle_list(state: SchedulerState) -> #(String, SchedulerState) {
  case state.entries {
    [] -> #("No schedules configured.", state)
    entries -> {
      let now_ms = time.now_ms()
      let lines =
        list.map(entries, fn(entry) {
          let c = entry.config
          let status = case c.enabled {
            True -> "active"
            False -> "paused"
          }
          let type_info = case c.schedule_type {
            "cron" -> "cron: " <> c.cron
            "interval" -> "every: " <> c.every
            other -> other
          }
          let domains_str = string.join(c.domains, ", ")
          let last_str = case entry.last_run_ms {
            0 -> "never"
            ms -> {
              let ago_s = { now_ms - ms } / 1000
              int.to_string(ago_s) <> "s ago"
            }
          }
          c.name
          <> " ["
          <> status
          <> "] "
          <> type_info
          <> " | skill: "
          <> c.skill
          <> " | domains: "
          <> domains_str
          <> " | last: "
          <> last_str
        })
      #(string.join(lines, "\n"), state)
    }
  }
}

fn handle_pause(
  state: SchedulerState,
  params: List(#(String, String)),
) -> #(String, SchedulerState) {
  case get_param(params, "name") {
    Error(_) -> #("Missing 'name' parameter for pause action.", state)
    Ok(name) -> {
      case list.any(state.entries, fn(e) { e.config.name == name }) {
        False -> #("Schedule not found: " <> name, state)
        True -> {
          let new_entries =
            list.map(state.entries, fn(e) {
              case e.config.name == name {
                True ->
                  ScheduleEntry(
                    ..e,
                    config: ScheduleConfig(..e.config, enabled: False),
                  )
                False -> e
              }
            })
          let new_state = SchedulerState(..state, entries: new_entries)
          write_schedules(new_state)
          #("Paused schedule: " <> name, new_state)
        }
      }
    }
  }
}

fn handle_resume(
  state: SchedulerState,
  params: List(#(String, String)),
) -> #(String, SchedulerState) {
  case get_param(params, "name") {
    Error(_) -> #("Missing 'name' parameter for resume action.", state)
    Ok(name) -> {
      case list.any(state.entries, fn(e) { e.config.name == name }) {
        False -> #("Schedule not found: " <> name, state)
        True -> {
          let new_entries =
            list.map(state.entries, fn(e) {
              case e.config.name == name {
                True ->
                  ScheduleEntry(
                    ..e,
                    config: ScheduleConfig(..e.config, enabled: True),
                  )
                False -> e
              }
            })
          let new_state = SchedulerState(..state, entries: new_entries)
          write_schedules(new_state)
          #("Resumed schedule: " <> name, new_state)
        }
      }
    }
  }
}

fn handle_create(
  state: SchedulerState,
  params: List(#(String, String)),
) -> #(String, SchedulerState) {
  case get_param(params, "name") {
    Error(_) -> #("Missing 'name' parameter for create action.", state)
    Ok(name) -> {
      // Check for duplicate
      case list.any(state.entries, fn(e) { e.config.name == name }) {
        True -> #("Schedule already exists: " <> name, state)
        False -> {
          let schedule_type =
            get_param(params, "type") |> result.unwrap("interval")
          let every = get_param(params, "every") |> result.unwrap("")
          let cron_str = get_param(params, "cron") |> result.unwrap("")
          let skill_name =
            get_param(params, "skill") |> result.unwrap("")
          let args = get_param(params, "args") |> result.unwrap("")
          let domains_str =
            get_param(params, "domains") |> result.unwrap("")
          let domains = case domains_str {
            "" -> []
            s ->
              string.split(s, ",")
              |> list.map(string.trim)
              |> list.filter(fn(d) { d != "" })
          }
          let model =
            get_param(params, "model")
            |> result.unwrap("zai/glm-5-turbo")

          case skill_name {
            "" -> #("Missing 'skill' parameter for create action.", state)
            _ -> {
              let config =
                ScheduleConfig(
                  name: name,
                  schedule_type: schedule_type,
                  every: every,
                  cron: cron_str,
                  skill: skill_name,
                  args: args,
                  domains: domains,
                  model: model,
                  enabled: True,
                )
              let entry = ScheduleEntry(config: config, last_run_ms: 0)
              let new_entries = list.append(state.entries, [entry])
              let new_state =
                SchedulerState(..state, entries: new_entries)
              write_schedules(new_state)
              #("Created schedule: " <> name, new_state)
            }
          }
        }
      }
    }
  }
}

fn handle_delete(
  state: SchedulerState,
  params: List(#(String, String)),
) -> #(String, SchedulerState) {
  case get_param(params, "name") {
    Error(_) -> #("Missing 'name' parameter for delete action.", state)
    Ok(name) -> {
      case list.any(state.entries, fn(e) { e.config.name == name }) {
        False -> #("Schedule not found: " <> name, state)
        True -> {
          let new_entries =
            list.filter(state.entries, fn(e) { e.config.name != name })
          let new_state = SchedulerState(..state, entries: new_entries)
          write_schedules(new_state)
          #("Deleted schedule: " <> name, new_state)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn get_param(
  params: List(#(String, String)),
  key: String,
) -> Result(String, Nil) {
  list.find_map(params, fn(p) {
    case p.0 == key {
      True -> Ok(p.1)
      False -> Error(Nil)
    }
  })
}

fn write_schedules(state: SchedulerState) -> Nil {
  let configs = list.map(state.entries, fn(e) { e.config })
  let toml_content = serialize_schedules(configs)
  case simplifile.write(state.config_path, toml_content) {
    Ok(_) ->
      io.println("[scheduler] Wrote schedules to " <> state.config_path)
    Error(e) ->
      io.println(
        "[scheduler] Failed to write schedules: " <> string.inspect(e),
      )
  }
}
