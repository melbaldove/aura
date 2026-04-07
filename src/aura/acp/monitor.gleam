import aura/acp/provider
import aura/acp/tmux
import aura/acp/types
import aura/llm
import aura/models
import aura/time
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type AcpEvent {
  AcpStarted(session_name: String, domain: String, task_id: String)
  AcpAlert(
    session_name: String,
    domain: String,
    status: types.SessionStatus,
    summary: String,
  )
  AcpCompleted(
    session_name: String,
    domain: String,
    report: types.AcpReport,
  )
  AcpTimedOut(session_name: String, domain: String)
  AcpFailed(session_name: String, domain: String, error: String)
  AcpProgress(session_name: String, domain: String, summary: String)
}

pub type MonitorMessage {
  CheckSession
}

pub type MonitorState {
  MonitorState(
    task_spec: types.TaskSpec,
    session_name: String,
    last_output: String,
    started_at_ms: Int,
    last_progress_ms: Int,
    idle_checks: Int,
    idle_surfaced: Bool,
    llm_config: Option(llm.LlmConfig),
    on_event: fn(AcpEvent) -> Nil,
    self_subject: process.Subject(MonitorMessage),
  )
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const check_interval_ms = 15_000

const idle_check_interval_ms = 60_000

const idle_threshold = 3

const progress_interval_ms = 120_000

const max_output_size = 50_000

/// Number of consecutive idle checks before declaring session complete
const idle_surface_threshold = 6

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn start(
  task_spec: types.TaskSpec,
  monitor_model: String,
  on_event: fn(AcpEvent) -> Nil,
) -> Result(process.Subject(MonitorMessage), String) {
  // Trust the directory if using Claude Code provider
  case task_spec.provider {
    provider.ClaudeCode -> {
      let _ = tmux.ensure_trusted(task_spec.cwd)
      Nil
    }
    _ -> Nil
  }
  let session_name =
    tmux.build_session_name(task_spec.domain, task_spec.id)
  let shell_command = provider.build_command(
    task_spec.provider,
    task_spec.prompt,
    task_spec.cwd,
    session_name,
    task_spec.worktree,
  )

  // Create the tmux session
  case tmux.create_session(session_name, shell_command) {
    Error(reason) -> Error("Failed to create tmux session: " <> reason)
    Ok(Nil) ->
      start_monitor_actor(task_spec, session_name, monitor_model, on_event, True)
  }
}

/// Start a monitor for an existing tmux session (recovery after restart).
/// Unlike `start`, this does NOT create a tmux session or emit AcpStarted.
pub fn start_recovery(
  task_spec: types.TaskSpec,
  monitor_model: String,
  on_event: fn(AcpEvent) -> Nil,
) -> Result(process.Subject(MonitorMessage), String) {
  let session_name =
    tmux.build_session_name(task_spec.domain, task_spec.id)
  start_monitor_actor(task_spec, session_name, monitor_model, on_event, False)
}

/// Shared actor creation for both start and start_recovery.
/// When `emit_started` is True, the AcpStarted event is emitted during init.
fn start_monitor_actor(
  task_spec: types.TaskSpec,
  session_name: String,
  monitor_model: String,
  on_event: fn(AcpEvent) -> Nil,
  emit_started: Bool,
) -> Result(process.Subject(MonitorMessage), String) {
  let llm_config =
    models.build_llm_config(monitor_model)
    |> option.from_result

  let started_at = time.now_ms()

  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let state =
        MonitorState(
          task_spec: task_spec,
          session_name: session_name,
          last_output: "",
          started_at_ms: started_at,
          last_progress_ms: started_at,
          idle_checks: 0,
              idle_surfaced: False,
          llm_config: llm_config,
          on_event: on_event,
          self_subject: subject,
        )

      let label = case emit_started {
        True -> "Monitor"
        False -> "Recovery monitor"
      }
      io.println("[acp-monitor] " <> label <> " initialized for " <> session_name)

      // Schedule the first check
      schedule_next(subject)

      // Only emit AcpStarted for new sessions, not recovery
      case emit_started {
        True ->
          on_event(AcpStarted(
            session_name: session_name,
            domain: task_spec.domain,
            task_id: task_spec.id,
          ))
        False -> Nil
      }

      Ok(actor.initialised(state) |> actor.returning(subject))
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(err) ->
      Error(
        "Failed to start monitor actor: " <> string.inspect(err),
      )
  }
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: MonitorState,
  message: MonitorMessage,
) -> actor.Next(MonitorState, MonitorMessage) {
  case message {
    CheckSession -> handle_check(state)
  }
}

fn handle_check(
  state: MonitorState,
) -> actor.Next(MonitorState, MonitorMessage) {
  io.println("[acp-monitor] Checking " <> state.session_name)
  // 1. Check if session still exists
  case tmux.session_exists(state.session_name) {
    False -> handle_session_ended(state)
    True -> handle_session_alive(state)
  }
}

fn handle_session_ended(
  state: MonitorState,
) -> actor.Next(MonitorState, MonitorMessage) {
  io.println("[acp-monitor] Session " <> state.session_name <> " tmux session disappeared")
  state.on_event(AcpFailed(
    session_name: state.session_name,
    domain: state.task_spec.domain,
    error: "tmux session disappeared",
  ))
  actor.stop()
}

fn handle_session_alive(
  state: MonitorState,
) -> actor.Next(MonitorState, MonitorMessage) {
  case tmux.capture_pane(state.session_name) {
    Error(err) -> {
      io.println("[acp-monitor] Failed to capture pane for " <> state.session_name <> ": " <> err)
      schedule_next(state.self_subject)
      actor.continue(state)
    }
    Ok(output) -> {
      let output_changed = output != state.last_output
      let new_idle_checks = case output_changed {
        True -> 0
        False -> state.idle_checks + 1
      }

      // Reset idle_surfaced when output actually changes
      let new_idle_surfaced = case output_changed {
        True -> False
        False -> state.idle_surfaced
      }

      // Idle detection — surface status ONCE, then shut up until output changes
      case new_idle_checks >= idle_surface_threshold && !new_idle_surfaced {
        True -> {
          io.println("[acp-monitor] Session " <> state.session_name <> " idle — surfacing status")
          let tail = string.slice(output, string.length(output) - 500, 500)
          state.on_event(AcpProgress(
            session_name: state.session_name,
            domain: state.task_spec.domain,
            summary: "**idle** — waiting at prompt\n```\n" <> tail <> "\n```",
          ))
          process.send_after(state.self_subject, idle_check_interval_ms, CheckSession)
          actor.continue(MonitorState(..state, last_output: cap_output(output), idle_checks: new_idle_checks, idle_surfaced: True))
        }
        _ -> {
          case new_idle_checks >= idle_threshold {
            True -> {
              // Already idle — back off to slow interval, no spam
              process.send_after(state.self_subject, idle_check_interval_ms, CheckSession)
              actor.continue(MonitorState(..state, last_output: cap_output(output), idle_checks: new_idle_checks, idle_surfaced: new_idle_surfaced))
            }
            False -> {
              // Active — classify if substantial new output
              let diff_len = string.length(output) - string.length(state.last_output)
              let abs_diff = case diff_len < 0 { True -> 0 - diff_len False -> diff_len }
              case abs_diff > 100 {
                True -> {
                  let s = state
                  let o = output
                  process.spawn_unlinked(fn() { classify_and_alert(s, o) })
                  Nil
                }
                False -> Nil
              }

              // Progress update if enough time passed
              let now = time.now_ms()
              let new_progress_ms = case now - state.last_progress_ms >= progress_interval_ms {
                True -> {
                  let s = state
                  let o = output
                  process.spawn_unlinked(fn() { summarize_and_report(s, o) })
                  now
                }
                False -> state.last_progress_ms
              }

              check_timeout_and_continue(
                MonitorState(..state, last_progress_ms: new_progress_ms, idle_checks: new_idle_checks),
                output,
              )
            }
          }
        }
      }
    }
  }
}

fn check_timeout_and_continue(
  state: MonitorState,
  output: String,
) -> actor.Next(MonitorState, MonitorMessage) {
  let elapsed = time.now_ms() - state.started_at_ms
  case elapsed > state.task_spec.timeout_ms {
    True -> {
      state.on_event(AcpTimedOut(
        session_name: state.session_name,
        domain: state.task_spec.domain,
      ))
      actor.stop()
    }
    False -> {
      schedule_next(state.self_subject)
      actor.continue(MonitorState(..state, last_output: cap_output(output)))
    }
  }
}

// ---------------------------------------------------------------------------
// LLM classification
// ---------------------------------------------------------------------------

fn summarize_and_report(state: MonitorState, output: String) -> Nil {
  case state.llm_config {
    None -> Nil
    Some(config) -> {
      let tail = string.slice(output, string.length(output) - 3000, 3000)
      let elapsed_min = { time.now_ms() - state.started_at_ms } / 60_000
      let system_prompt =
        "You are reporting on an AI coding session to a busy developer. "
        <> "Format your response EXACTLY like this — use these headers, keep each section to 1 line:\n"
        <> "**Done:** what was accomplished\n"
        <> "**Needs input:** decisions or questions for the developer (or 'none')\n"
        <> "**Next:** what the session will do next or 'idle — waiting for instructions'\n"
        <> "Be specific. File names, ticket numbers, concrete questions. No filler."
      let user_prompt =
        "Session: " <> state.session_name
        <> " (" <> int.to_string(elapsed_min) <> " minutes elapsed)"
        <> "\n\nLatest output:\n" <> tail
      let messages = [
        llm.SystemMessage(system_prompt),
        llm.UserMessage(user_prompt),
      ]
      case llm.chat(config, messages) {
        Ok(summary) -> {
          state.on_event(AcpProgress(
            session_name: state.session_name,
            domain: state.task_spec.domain,
            summary: string.trim(summary),
          ))
        }
        Error(_) -> Nil
      }
    }
  }
}

fn classify_and_alert(state: MonitorState, output: String) -> Nil {
  case state.llm_config {
    None -> Nil
    Some(config) -> {
      let tail = string.slice(output, string.length(output) - 500, 500)
      let system_prompt =
        "You are monitoring an AI coding session. "
        <> "Based on the latest output, classify the session status. "
        <> "Respond with exactly one word: PROGRESSING, STUCK, BLOCKED, or DANGEROUS."
      let user_prompt =
        "Session: "
        <> state.session_name
        <> "\n\nLatest output:\n"
        <> tail
      let messages = [
        llm.SystemMessage(system_prompt),
        llm.UserMessage(user_prompt),
      ]
      case llm.chat(config, messages) {
        Ok(response) -> {
          let status = parse_status(response)
          case status {
            types.Running -> Nil
            _ -> {
              state.on_event(AcpAlert(
                session_name: state.session_name,
                domain: state.task_spec.domain,
                status: status,
                summary: string.slice(tail, 0, 200),
              ))
            }
          }
        }
        Error(_) -> Nil
      }
    }
  }
}

fn parse_status(response: String) -> types.SessionStatus {
  let trimmed = string.trim(response) |> string.uppercase
  case trimmed {
    "PROGRESSING" -> types.Running
    "STUCK" -> types.Stuck
    "BLOCKED" -> types.Blocked
    "DANGEROUS" -> types.Dangerous
    _ -> types.Running
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn cap_output(output: String) -> String {
  case string.length(output) > max_output_size {
    True ->
      string.slice(output, string.length(output) - max_output_size, max_output_size)
    False -> output
  }
}

// ---------------------------------------------------------------------------
// Scheduling
// ---------------------------------------------------------------------------

fn schedule_next(subject: process.Subject(MonitorMessage)) -> Nil {
  process.send_after(subject, check_interval_ms, CheckSession)
  Nil
}
