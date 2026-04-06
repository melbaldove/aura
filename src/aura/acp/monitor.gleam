import aura/acp/report
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
    llm_config: Option(llm.LlmConfig),
    on_event: fn(AcpEvent) -> Nil,
    self_subject: process.Subject(MonitorMessage),
  )
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const check_interval_ms = 15_000

const progress_interval_ms = 120_000

const max_output_size = 50_000

const report_marker = "---AURA-REPORT---"

const report_instructions = "Before exiting, output exactly this format as your final message:\n\n---AURA-REPORT---\nOUTCOME: clean | partial | failed\nFILES_CHANGED: [list of files]\nDECISIONS: [key decisions and why]\nTESTS: [pass/fail summary]\nBLOCKERS: [unresolved items]\nANCHOR: [one sentence worth remembering long-term]\n---END-REPORT---"

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn start(
  task_spec: types.TaskSpec,
  monitor_model: String,
  on_event: fn(AcpEvent) -> Nil,
) -> Result(process.Subject(MonitorMessage), String) {
  let session_name =
    tmux.build_session_name(task_spec.domain, task_spec.id)

  // Ensure the working directory is trusted by Claude Code
  let _ = tmux.ensure_trusted(task_spec.cwd)

  // Build claude command with report instructions appended to prompt
  let full_prompt = task_spec.prompt <> "\n\n" <> report_instructions
  let shell_command = tmux.build_claude_command(full_prompt, task_spec.cwd)

  // Create the tmux session
  case tmux.create_session(session_name, shell_command) {
    Error(reason) -> Error("Failed to create tmux session: " <> reason)
    Ok(Nil) -> {
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
              llm_config: llm_config,
              on_event: on_event,
              self_subject: subject,
            )

          io.println("[acp-monitor] Monitor initialized for " <> session_name)

          // Schedule the first check
          schedule_next(subject)

          // Emit started event
          on_event(AcpStarted(
            session_name: session_name,
            domain: task_spec.domain,
            task_id: task_spec.id,
          ))

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
  io.println("[acp-monitor] Session " <> state.session_name <> " ended. Last output length: " <> string.inspect(string.length(state.last_output)))
  // Session disappeared — try to parse report from last output
  case report.parse(state.last_output) {
    Ok(rpt) -> {
      state.on_event(AcpCompleted(
        session_name: state.session_name,
        domain: state.task_spec.domain,
        report: rpt,
      ))
    }
    Error(_) -> {
      state.on_event(AcpFailed(
        session_name: state.session_name,
        domain: state.task_spec.domain,
        error: "Session ended without a valid report",
      ))
    }
  }
  actor.stop()
}

fn handle_session_alive(
  state: MonitorState,
) -> actor.Next(MonitorState, MonitorMessage) {
  // 2. Capture pane output
  case tmux.capture_pane(state.session_name) {
    Error(err) -> {
      io.println(
        "[acp-monitor] Failed to capture pane for "
        <> state.session_name
        <> ": "
        <> err,
      )
      schedule_next(state.self_subject)
      actor.continue(state)
    }
    Ok(output) -> {
      // 3. If output unchanged, just reschedule
      case output == state.last_output {
        True -> {
          // Still check timeout even if output unchanged
          check_timeout_and_continue(state, output)
        }
        False -> {
          // 4. Check for report marker
          case string.contains(output, report_marker) {
            True -> {
              case report.parse(output) {
                Ok(rpt) -> {
                  state.on_event(AcpCompleted(
                    session_name: state.session_name,
                    domain: state.task_spec.domain,
                    report: rpt,
                  ))
                  actor.stop()
                }
                Error(_) -> {
                  // Marker found but parse failed, keep monitoring
                  schedule_next(state.self_subject)
                  actor.continue(MonitorState(..state, last_output: cap_output(output)))
                }
              }
            }
            False -> {
              // 5. Classify if substantial new output
              let diff_len =
                string.length(output) - string.length(state.last_output)
              let abs_diff = case diff_len < 0 {
                True -> 0 - diff_len
                False -> diff_len
              }
              case abs_diff > 100 {
                True -> {
                  // Spawn to avoid blocking the monitor actor
                  let s = state
                  let o = output
                  process.spawn_unlinked(fn() { classify_and_alert(s, o) })
                  Nil
                }
                False -> Nil
              }

              // 6. Emit progress update if enough time has passed
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

              // 7. Check timeout
              check_timeout_and_continue(
                MonitorState(..state, last_progress_ms: new_progress_ms),
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
      let tail = string.slice(output, string.length(output) - 1500, 1500)
      let elapsed_min = { time.now_ms() - state.started_at_ms } / 60_000
      let system_prompt =
        "You are monitoring an AI coding session. "
        <> "Summarize what the session is currently doing in 1-2 sentences. "
        <> "Be specific about files, tools, or tasks. No preamble."
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
