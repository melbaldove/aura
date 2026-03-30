import aura/llm
import aura/models
import aura/notification
import aura/skill
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type CheckConfig {
  CheckConfig(
    name: String,
    interval_ms: Int,
    skill_name: String,
    skill_args: List(String),
    workstreams: List(String),
    model: String,
  )
}

pub type CheckMessage {
  RunCheck
}

pub type CheckState {
  CheckState(
    config: CheckConfig,
    skill_info: Option(skill.SkillInfo),
    llm_config: Option(llm.LlmConfig),
    on_finding: fn(notification.Finding) -> Nil,
    self_subject: process.Subject(CheckMessage),
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start a heartbeat check actor that periodically invokes a skill and
/// generates findings for each configured workstream.
pub fn start(
  config: CheckConfig,
  all_skills: List(skill.SkillInfo),
  on_finding: fn(notification.Finding) -> Nil,
) -> Result(process.Subject(CheckMessage), String) {
  let matched_skill =
    list.find(all_skills, fn(s) { s.name == config.skill_name })
    |> option.from_result

  let llm_config =
    models.build_llm_config(config.model)
    |> option.from_result

  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let state =
        CheckState(
          config: config,
          skill_info: matched_skill,
          llm_config: llm_config,
          on_finding: on_finding,
          self_subject: subject,
        )

      // Schedule the first check
      schedule_next(subject, config.interval_ms)

      Ok(actor.initialised(state) |> actor.returning(subject))
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(err) ->
      Error(
        "Failed to start heartbeat actor '"
        <> config.name
        <> "': "
        <> string.inspect(err),
      )
  }
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: CheckState,
  message: CheckMessage,
) -> actor.Next(CheckState, CheckMessage) {
  case message {
    RunCheck -> {
      run_check(state)
      schedule_next(state.self_subject, state.config.interval_ms)
      actor.continue(state)
    }
  }
}

// ---------------------------------------------------------------------------
// Check execution
// ---------------------------------------------------------------------------

fn run_check(state: CheckState) -> Nil {
  io.println("[heartbeat:" <> state.config.name <> "] Running check")
  case state.skill_info {
    None -> {
      io.println(
        "[heartbeat] Skill '"
        <> state.config.skill_name
        <> "' not found, skipping check '"
        <> state.config.name
        <> "'",
      )
      Nil
    }
    Some(info) -> {
      case skill.invoke(info, state.config.skill_args, 30_000) {
        Ok(result) -> {
          case result.exit_code {
            0 -> {
              let urgency = classify_urgency(state, result.stdout)
              emit_findings(state, result.stdout, urgency)
            }
            _code -> {
              io.println(
                "[heartbeat] Check '"
                <> state.config.name
                <> "' exited with non-zero code, stderr: "
                <> string.slice(result.stderr, 0, 200),
              )
              Nil
            }
          }
        }
        Error(err) -> {
          io.println(
            "[heartbeat] Check '"
            <> state.config.name
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

fn classify_urgency(
  state: CheckState,
  output: String,
) -> notification.Urgency {
  case state.llm_config {
    None -> notification.Normal
    Some(config) -> {
      let system_prompt =
        "You are classifying the urgency of a monitoring check result. "
        <> "Respond with exactly one word: URGENT, NORMAL, or LOW."
      let user_prompt =
        "Check name: "
        <> state.config.name
        <> "\n\nOutput:\n"
        <> string.slice(output, 0, 2000)
      let messages = [
        llm.SystemMessage(system_prompt),
        llm.UserMessage(user_prompt),
      ]
      case llm.chat(config, messages) {
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
  state: CheckState,
  output: String,
  urgency: notification.Urgency,
) -> Nil {
  list.each(state.config.workstreams, fn(workstream) {
    let summary = string.slice(output, 0, 50)
    io.println("[heartbeat:" <> state.config.name <> "] Finding: " <> summary)
    let finding =
      notification.Finding(
        workstream: workstream,
        summary: output,
        urgency: urgency,
        source: state.config.name,
      )
    state.on_finding(finding)
  })
}

// ---------------------------------------------------------------------------
// Scheduling
// ---------------------------------------------------------------------------

fn schedule_next(
  subject: process.Subject(CheckMessage),
  interval_ms: Int,
) -> Nil {
  process.send_after(subject, interval_ms, RunCheck)
  Nil
}
