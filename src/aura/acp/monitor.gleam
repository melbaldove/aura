import aura/acp/tmux
import aura/acp/types
import aura/llm
import aura/models
import aura/time
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
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
    result_text: String,
  )
  /// A turn completed (end_turn) but the session is still alive.
  /// Used by stdio transport where end_turn means "finished responding"
  /// not "finished all work". The event loop continues after this.
  AcpTurnCompleted(
    session_name: String,
    domain: String,
    result_text: String,
  )
  // AcpTimedOut removed — flares run until done or explicitly stopped
  AcpFailed(session_name: String, domain: String, error: String)
  AcpProgress(
    session_name: String,
    domain: String,
    title: String,
    status: String,
    summary: String,
    is_idle: Bool,
  )
}

// ---------------------------------------------------------------------------
// Push-based stdio monitor
// ---------------------------------------------------------------------------

/// Configuration for the push-based monitor.
pub type MonitorConfig {
  MonitorConfig(
    emit_interval_ms: Int,
    idle_interval_ms: Int,
    idle_surface_threshold: Int,
  )
}

/// Messages the push-based monitor receives.
pub type StdioMonitorMsg {
  RawLine(line: String)
  Tick
  UpdateStdioSummary(summary: String)
  GetLastSummary(reply_to: process.Subject(String))
  LlmBackoff
  Shutdown
}

/// Default monitor config using the existing constants.
pub fn default_monitor_config() -> MonitorConfig {
  MonitorConfig(
    emit_interval_ms: check_interval_ms,
    idle_interval_ms: idle_check_interval_ms,
    idle_surface_threshold: idle_surface_threshold,
  )
}

/// Start a push-based monitor actor. Returns the subject to send RawLines to.
/// The monitor self-schedules Tick messages on emit_interval_ms cadence.
pub fn start_push_monitor(
  config: MonitorConfig,
  session_name: String,
  domain: String,
  task_prompt: String,
  monitor_model: String,
  on_event: fn(AcpEvent) -> Nil,
) -> process.Subject(StdioMonitorMsg) {
  let llm_config = case monitor_model {
    "" -> None
    model -> case models.build_llm_config(model) {
      Ok(c) -> Some(c)
      Error(e) -> {
        io.println("[acp-monitor] No LLM config for " <> model <> ": " <> e)
        None
      }
    }
  }

  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      process.send_after(subject, config.emit_interval_ms, Tick)

      let state =
        PushMonitorState(
          config: config,
          session_name: session_name,
          domain: domain,
          task_prompt: task_prompt,
          raw_lines: [],
          last_summary: "",
          idle_checks: 0,
          idle_surfaced: False,
          started_at_ms: time.now_ms(),
          llm_config: llm_config,
          on_event: on_event,
          self_subject: subject,
          skip_ticks: 0,
        )

      Ok(actor.initialised(state) |> actor.returning(subject))
    })
    |> actor.on_message(handle_push_msg)

  case actor.start(builder) {
    Ok(started) -> started.data
    Error(err) -> {
      io.println(
        "[acp-monitor] Failed to start push monitor: "
        <> string.inspect(err),
      )
      process.new_subject()
    }
  }
}

type PushMonitorState {
  PushMonitorState(
    config: MonitorConfig,
    session_name: String,
    domain: String,
    task_prompt: String,
    raw_lines: List(String),
    last_summary: String,
    idle_checks: Int,
    idle_surfaced: Bool,
    started_at_ms: Int,
    llm_config: Option(llm.LlmConfig),
    on_event: fn(AcpEvent) -> Nil,
    self_subject: process.Subject(StdioMonitorMsg),
    skip_ticks: Int,
  )
}

fn handle_push_msg(
  state: PushMonitorState,
  msg: StdioMonitorMsg,
) -> actor.Next(PushMonitorState, StdioMonitorMsg) {
  case msg {
    RawLine(line) -> {
      actor.continue(PushMonitorState(
        ..state,
        raw_lines: list.append(state.raw_lines, [line]),
      ))
    }
    Tick -> handle_push_tick(state)
    UpdateStdioSummary(summary) -> {
      actor.continue(PushMonitorState(..state, last_summary: summary))
    }
    GetLastSummary(reply_to) -> {
      process.send(reply_to, state.last_summary)
      actor.continue(state)
    }
    LlmBackoff -> {
      // Back off for 4 ticks (~60s at 15s interval)
      actor.continue(PushMonitorState(..state, skip_ticks: 4))
    }
    Shutdown -> actor.stop()
  }
}

fn handle_push_tick(
  state: PushMonitorState,
) -> actor.Next(PushMonitorState, StdioMonitorMsg) {
  let is_active = state.raw_lines != []
  let new_idle_checks = case is_active {
    True -> 0
    False -> state.idle_checks + 1
  }

  // If backing off from LLM rate limit, decrement and skip LLM call
  case state.skip_ticks > 0 {
        True -> {
          process.send_after(state.self_subject, state.config.emit_interval_ms, Tick)
          actor.continue(PushMonitorState(
            ..state,
            idle_checks: new_idle_checks,
            skip_ticks: state.skip_ticks - 1,
          ))
        }
        False -> {
          let is_idle = !is_active
          let should_emit =
            is_active
            || {
              new_idle_checks >= state.config.idle_surface_threshold
              && !state.idle_surfaced
            }

          let new_state = case should_emit {
            True -> {
              // Spawn LLM summarization (non-blocking)
              let s = state
              let lines = state.raw_lines
              process.spawn_unlinked(fn() {
                generate_stdio_progress(s, lines, is_idle)
              })

              PushMonitorState(
                ..state,
                raw_lines: [],
                idle_checks: new_idle_checks,
                idle_surfaced: case is_idle {
                  True -> True
                  False -> False
                },
              )
            }
            False ->
              PushMonitorState(
                ..state,
                idle_checks: new_idle_checks,
                idle_surfaced: case is_active {
                  True -> False
                  False -> state.idle_surfaced
                },
              )
          }

          let next_interval = case
            new_idle_checks >= state.config.idle_surface_threshold
          {
            True -> state.config.idle_interval_ms
            False -> state.config.emit_interval_ms
          }
          process.send_after(state.self_subject, next_interval, Tick)
          actor.continue(new_state)
        }
      }
}

/// Generate a structured progress update for stdio sessions using LLM.
/// Spawned in a separate process so it doesn't block the actor.
fn generate_stdio_progress(
  state: PushMonitorState,
  raw_lines: List(String),
  is_idle: Bool,
) -> Nil {
  case state.llm_config {
    None -> {
      // No LLM — emit a basic fallback
      let line_count = list.length(raw_lines)
      let summary = case is_idle {
        True -> "Session idle"
        False -> "[" <> int.to_string(line_count) <> " events received]"
      }
      // Update actor's last_summary for continuity (same as LLM path)
      process.send(state.self_subject, UpdateStdioSummary(summary))
      state.on_event(AcpProgress(
        session_name: state.session_name,
        domain: state.domain,
        title: "",
        status: case is_idle { True -> "Idle" False -> "Working" },
        summary: summary,
        is_idle: is_idle,
      ))
    }
    Some(config) -> {
      // Cap raw lines to last ~3000 chars
      let joined = string.join(raw_lines, "\n")
      let tail = case string.length(joined) > 3000 {
        True -> string.slice(joined, string.length(joined) - 3000, 3000)
        False -> joined
      }

      let elapsed_min = { time.now_ms() - state.started_at_ms } / 60_000

      let previous_section = case state.last_summary {
        "" -> ""
        prev ->
          "\n\nPrevious update:\n"
          <> prev
          <> "\n\nIMPORTANT: The Done field MUST include everything from the previous update's Done field PLUS any new accomplishments. Never drop previous Done items. The developer reads Done to see cumulative progress."
      }

      let idle_hint = case is_idle {
        True ->
          "\nNo new events have arrived — the session appears idle or finished. Summarize ALL accomplishments in the Done field (carry forward from previous update). Set Status to 'Idle'. Set Current to what was last happening. Set Next to 'idle — waiting' or 'may be complete'."
        False -> ""
      }

      let system_prompt =
        "You are reporting on an AI coding session to a busy developer via Discord. MAX 280 characters per field.\n\n"
        <> "Output EXACTLY these 6 lines. ALL mandatory. No extra text.\n\n"
        <> "Title: one-line session description\n"
        <> "Status: Working | Stuck | Blocked | Idle | Needs input | Dangerous\n"
        <> "Done: short summary of cumulative progress. Group by category, not individual files. e.g. 'Read 8 exclusion files, grepped for `isExcluded` (not in pipeline), checked Rust (none found)'. Carry forward from previous update.\n"
        <> "Current: what is happening right now\n"
        <> "Needs input: decisions needed, or none\n"
        <> "Next: what happens next\n\n"
        <> "Rules:\n"
        <> "- CONCISE. This is Discord, not a report. Each field is ONE short line.\n"
        <> "- Done summarizes, not lists. '5 test files read' not each file name.\n"
        <> "- `backticks` for key file paths only. No bullet points — commas instead."

      let user_prompt =
        "Task: " <> state.task_prompt
        <> "\nElapsed: " <> int.to_string(elapsed_min) <> " minutes"
        <> idle_hint
        <> previous_section
        <> "\n\nLatest ACP events:\n" <> tail

      let messages = [
        llm.SystemMessage(system_prompt),
        llm.UserMessage(user_prompt),
      ]

      case llm.chat(config, messages) {
        Ok(response) -> {
          let trimmed = string.trim(response)

          // Send summary back to actor for continuity
          process.send(state.self_subject, UpdateStdioSummary(trimmed))

          let title = extract_field(trimmed, "Title:")
          let status = extract_field(trimmed, "Status:")

          // Alert for non-normal statuses
          let parsed_status = case string.uppercase(string.trim(status)) {
            "STUCK" -> Some(types.Stuck)
            "BLOCKED" -> Some(types.Blocked)
            "DANGEROUS" -> Some(types.Dangerous)
            _ -> None
          }

          case parsed_status {
            Some(alert_status) ->
              state.on_event(AcpAlert(
                session_name: state.session_name,
                domain: state.domain,
                status: alert_status,
                summary: trimmed,
              ))
            None -> Nil
          }

          state.on_event(AcpProgress(
            session_name: state.session_name,
            domain: state.domain,
            title: title,
            status: status,
            summary: trimmed,
            is_idle: is_idle,
          ))
        }
        Error(e) -> {
          io.println(
            "[acp-monitor] Stdio progress LLM failed for "
            <> state.session_name <> ": " <> e,
          )
          // Back off on rate limit errors
          case string.contains(e, "429") || string.contains(e, "overloaded") {
            True -> process.send(state.self_subject, LlmBackoff)
            False -> Nil
          }
        }
      }
    }
  }
}

pub type MonitorMessage {
  CheckSession
  UpdateSummary(summary: String)
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
    last_summary: String,
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

/// Number of consecutive idle checks before surfacing idle status
const idle_surface_threshold = 3

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start a monitor actor for an existing tmux session.
/// Unlike `start`, this does NOT create a tmux session.
/// `emit_started` controls whether AcpStarted is emitted.
pub fn start_monitor_only(
  task_spec: types.TaskSpec,
  session_name: String,
  monitor_model: String,
  on_event: fn(AcpEvent) -> Nil,
  emit_started: Bool,
  idle_surfaced: Bool,
) -> Result(process.Subject(MonitorMessage), String) {
  start_monitor_actor(task_spec, session_name, monitor_model, on_event, emit_started, idle_surfaced)
}

/// Shared actor creation for both start and start_recovery.
/// When `emit_started` is True, the AcpStarted event is emitted during init.
fn start_monitor_actor(
  task_spec: types.TaskSpec,
  session_name: String,
  monitor_model: String,
  on_event: fn(AcpEvent) -> Nil,
  emit_started: Bool,
  idle_surfaced: Bool,
) -> Result(process.Subject(MonitorMessage), String) {
  let llm_config = case models.build_llm_config(monitor_model) {
    Ok(config) -> Some(config)
    Error(e) -> {
      io.println("[acp-monitor] No LLM config for " <> monitor_model <> ": " <> e <> " — progress updates disabled")
      None
    }
  }

  let started_at = time.now_ms()

  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      // For recovery: pre-load current tmux output so first check doesn't see a false change
      let initial_output = case emit_started {
        True -> ""
        False -> case tmux.capture_pane(session_name) {
          Ok(o) -> cap_output(o)
          Error(_) -> ""
        }
      }

      let state =
        MonitorState(
          task_spec: task_spec,
          session_name: session_name,
          last_output: initial_output,
          started_at_ms: started_at,
          last_progress_ms: started_at,
          idle_checks: 0,
          idle_surfaced: idle_surfaced,
          last_summary: "",
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
    UpdateSummary(summary) -> {
      actor.continue(MonitorState(..state, last_summary: summary))
    }
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
    Ok(raw_output) -> {
      let output = cap_output(raw_output)
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
          let s = state
          let o = output
          process.spawn_unlinked(fn() { generate_progress_update(s, o, True) })
          process.send_after(state.self_subject, idle_check_interval_ms, CheckSession)
          actor.continue(MonitorState(..state, last_output: output, idle_checks: new_idle_checks, idle_surfaced: True))
        }
        _ -> {
          case new_idle_checks >= idle_threshold {
            True -> {
              // Already idle — back off to slow interval, no spam
              process.send_after(state.self_subject, idle_check_interval_ms, CheckSession)
              actor.continue(MonitorState(..state, last_output: output, idle_checks: new_idle_checks, idle_surfaced: new_idle_surfaced))
            }
            False -> {
              // Active — generate progress update if enough time passed or substantial output change
              let now = time.now_ms()
              let diff_len = string.length(output) - string.length(state.last_output)
              let abs_diff = case diff_len < 0 { True -> 0 - diff_len False -> diff_len }
              let new_progress_ms = case now - state.last_progress_ms >= progress_interval_ms || abs_diff > 500 {
                True -> {
                  let s = state
                  let o = output
                  process.spawn_unlinked(fn() { generate_progress_update(s, o, False) })
                  now
                }
                False -> state.last_progress_ms
              }

              schedule_next(state.self_subject)
              actor.continue(
                MonitorState(..state, last_output: output, last_progress_ms: new_progress_ms, idle_checks: new_idle_checks),
              )
            }
          }
        }
      }
    }
  }
}


// ---------------------------------------------------------------------------
// LLM classification
// ---------------------------------------------------------------------------

/// Generate a structured progress update using one LLM call.
/// Replaces the old separate classify_and_alert + summarize_and_report.
fn generate_progress_update(state: MonitorState, output: String, is_idle: Bool) -> Nil {
  case state.llm_config {
    None -> Nil
    Some(config) -> {
      let tail = string.slice(output, string.length(output) - 3000, 3000)
      let elapsed_min = { time.now_ms() - state.started_at_ms } / 60_000

      let previous_section = case state.last_summary {
        "" -> ""
        prev -> "\n\nPrevious update:\n" <> prev <> "\n\nUpdate the summary. Accumulate Done items — don't drop previous accomplishments."
      }

      let idle_hint = case is_idle {
        True -> "\nThe session output has not changed — it appears idle or waiting for input. Set Status to 'Idle' or 'Needs input' as appropriate."
        False -> ""
      }

      let system_prompt =
        "You are reporting on an AI coding session to a busy developer via Discord. Keep it scannable.\n\n"
        <> "Respond with EXACTLY this format (no other text):\n\n"
        <> "Title: [one-line description of what this session is doing]\n"
        <> "Status: [Working | Stuck | Blocked | Idle | Needs input | Dangerous]\n"
        <> "Done: [what was accomplished — file names, ticket numbers, concrete results. Use bullet points if multiple items.]\n"
        <> "Current: [what's happening right now based on the output]\n"
        <> "Needs input: [decisions or questions for the developer, or 'none']\n"
        <> "Next: [what the session will do next, or 'idle — waiting for instructions']\n\n"
        <> "Use markdown: `file paths`, `commands`, `ticket numbers` in backticks. URLs as links. Bullet points for multiple items. Be specific and concise."

      let user_prompt =
        "Task: " <> state.task_spec.prompt
        <> "\nElapsed: " <> int.to_string(elapsed_min) <> " minutes"
        <> idle_hint
        <> previous_section
        <> "\n\nLatest output:\n" <> tail

      let messages = [
        llm.SystemMessage(system_prompt),
        llm.UserMessage(user_prompt),
      ]
      case llm.chat(config, messages) {
        Ok(response) -> {
          let trimmed = string.trim(response)

          // Send summary back to monitor actor for continuity
          process.send(state.self_subject, UpdateSummary(trimmed))

          let title = extract_field(trimmed, "Title:")
          let status = extract_field(trimmed, "Status:")

          // Determine alert status for non-normal statuses
          let parsed_status = case string.uppercase(string.trim(status)) {
            "STUCK" -> Some(types.Stuck)
            "BLOCKED" -> Some(types.Blocked)
            "DANGEROUS" -> Some(types.Dangerous)
            _ -> None
          }

          // Emit alert for non-normal statuses
          case parsed_status {
            Some(alert_status) -> {
              state.on_event(AcpAlert(
                session_name: state.session_name,
                domain: state.task_spec.domain,
                status: alert_status,
                summary: trimmed,
              ))
            }
            None -> Nil
          }

          // Always emit progress
          state.on_event(AcpProgress(
            session_name: state.session_name,
            domain: state.task_spec.domain,
            title: title,
            status: status,
            summary: trimmed,
            is_idle: is_idle,
          ))
        }
        Error(e) -> {
          io.println("[acp-monitor] Progress LLM call failed for " <> state.session_name <> ": " <> e)
        }
      }
    }
  }
}

/// Extract a field value from structured LLM response.
/// Given "Title: Fix the bug\nStatus: Working\n...", extract_field(text, "Title:") returns "Fix the bug".
pub fn extract_field(text: String, field: String) -> String {
  case string.split(text, "\n") {
    [] -> ""
    lines -> {
      case list.find(lines, fn(line) { string.starts_with(string.trim(line), field) }) {
        Ok(line) -> string.trim(string.drop_start(string.trim(line), string.length(field)))
        Error(_) -> ""
      }
    }
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
