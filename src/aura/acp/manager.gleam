import aura/acp/monitor as acp_monitor
import aura/acp/provider
import aura/acp/session_store
import aura/acp/tmux
import aura/acp/types
import aura/time
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/erlang/process
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type SessionState {
  Starting
  Running
  Complete
  Failed(reason: String)
  TimedOut
}

pub type ActiveSession {
  ActiveSession(
    session_name: String,
    domain: String,
    task_id: String,
    state: SessionState,
    started_at_ms: Int,
    thread_id: String,
    prompt: String,
    cwd: String,
    idle_surfaced: Bool,
  )
}

pub type AcpMessage {
  Dispatch(
    reply_to: process.Subject(Result(String, String)),
    task_spec: types.TaskSpec,
    thread_id: String,
  )
  Kill(
    reply_to: process.Subject(Result(Nil, String)),
    session_name: String,
  )
  GetSession(
    reply_to: process.Subject(Result(ActiveSession, Nil)),
    session_name: String,
  )
  ListSessions(
    reply_to: process.Subject(List(ActiveSession)),
  )
  SendInput(
    reply_to: process.Subject(Result(Nil, String)),
    session_name: String,
    input: String,
  )
  MonitorEvent(acp_monitor.AcpEvent)
  SetBrainCallback(on_brain_event: fn(acp_monitor.AcpEvent) -> Nil)
}

pub type AcpActorState {
  AcpActorState(
    sessions: Dict(String, ActiveSession),
    max_concurrent: Int,
    store_path: String,
    monitor_model: String,
    on_brain_event: fn(acp_monitor.AcpEvent) -> Nil,
    self_subject: process.Subject(AcpMessage),
  )
}

// ---------------------------------------------------------------------------
// Public API (convenience wrappers around process.call)
// ---------------------------------------------------------------------------

pub fn dispatch(
  subject: process.Subject(AcpMessage),
  task_spec: types.TaskSpec,
  thread_id: String,
) -> Result(String, String) {
  process.call(subject, 30_000, fn(reply_to) {
    Dispatch(reply_to: reply_to, task_spec: task_spec, thread_id: thread_id)
  })
}

pub fn kill(
  subject: process.Subject(AcpMessage),
  session_name: String,
) -> Result(Nil, String) {
  process.call(subject, 10_000, fn(reply_to) {
    Kill(reply_to: reply_to, session_name: session_name)
  })
}

pub fn get_session(
  subject: process.Subject(AcpMessage),
  session_name: String,
) -> Result(ActiveSession, Nil) {
  process.call(subject, 5000, fn(reply_to) {
    GetSession(reply_to: reply_to, session_name: session_name)
  })
}

pub fn list_sessions(
  subject: process.Subject(AcpMessage),
) -> List(ActiveSession) {
  process.call(subject, 5000, fn(reply_to) {
    ListSessions(reply_to: reply_to)
  })
}

pub fn send_input(
  subject: process.Subject(AcpMessage),
  session_name: String,
  input: String,
) -> Result(Nil, String) {
  process.call(subject, 10_000, fn(reply_to) {
    SendInput(reply_to: reply_to, session_name: session_name, input: input)
  })
}

/// Convert a session state to a human-readable string.
pub fn session_state_to_string(state: SessionState) -> String {
  case state {
    Starting -> "starting"
    Running -> "running"
    Complete -> "complete"
    Failed(reason) -> "failed(" <> reason <> ")"
    TimedOut -> "timed_out"
  }
}

// ---------------------------------------------------------------------------
// Actor lifecycle
// ---------------------------------------------------------------------------

pub fn start(
  max_concurrent: Int,
  store_path: String,
  monitor_model: String,
  on_brain_event: fn(acp_monitor.AcpEvent) -> Nil,
) -> Result(process.Subject(AcpMessage), String) {
  let builder =
    actor.new_with_initialiser(10_000, fn(self_subject) {
      // Recovery: load persisted sessions, check tmux, start monitors
      let sessions =
        recover_sessions(self_subject, store_path, monitor_model, on_brain_event)

      let state =
        AcpActorState(
          sessions: sessions,
          max_concurrent: max_concurrent,
          store_path: store_path,
          monitor_model: monitor_model,
          on_brain_event: on_brain_event,
          self_subject: self_subject,
        )
      Ok(actor.initialised(state) |> actor.returning(self_subject))
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(err) ->
      Error("Failed to start ACP manager actor: " <> string.inspect(err))
  }
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: AcpActorState,
  message: AcpMessage,
) -> actor.Next(AcpActorState, AcpMessage) {
  case message {
    Dispatch(reply_to:, task_spec:, thread_id:) -> {
      let #(new_state, result) = handle_dispatch(state, task_spec, thread_id)
      process.send(reply_to, result)
      actor.continue(new_state)
    }
    Kill(reply_to:, session_name:) -> {
      let #(new_state, result) = handle_kill(state, session_name)
      process.send(reply_to, result)
      actor.continue(new_state)
    }
    GetSession(reply_to:, session_name:) -> {
      process.send(reply_to, dict.get(state.sessions, session_name))
      actor.continue(state)
    }
    ListSessions(reply_to:) -> {
      process.send(reply_to, dict.values(state.sessions))
      actor.continue(state)
    }
    SendInput(reply_to:, session_name:, input:) -> {
      let result = handle_send_input(state, session_name, input)
      process.send(reply_to, result)
      actor.continue(state)
    }
    MonitorEvent(event) -> {
      let new_state = handle_monitor_event(state, event)
      actor.continue(new_state)
    }
    SetBrainCallback(on_brain_event:) -> {
      actor.continue(AcpActorState(..state, on_brain_event: on_brain_event))
    }
  }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

fn handle_dispatch(
  state: AcpActorState,
  task_spec: types.TaskSpec,
  thread_id: String,
) -> #(AcpActorState, Result(String, String)) {
  case dict.size(state.sessions) < state.max_concurrent {
    False -> #(
      state,
      Error(
        "ACP concurrency limit reached ("
        <> int.to_string(state.max_concurrent)
        <> ")",
      ),
    )
    True -> {
      let session_name =
        tmux.build_session_name(task_spec.domain, task_spec.id)
      let session =
        ActiveSession(
          session_name: session_name,
          domain: task_spec.domain,
          task_id: task_spec.id,
          state: Starting,
          started_at_ms: time.now_ms(),
          thread_id: thread_id,
          prompt: task_spec.prompt,
          cwd: task_spec.cwd,
          idle_surfaced: False,
        )

      // Insert and persist BEFORE starting tmux/monitor
      let new_sessions = dict.insert(state.sessions, session_name, session)
      let new_state = AcpActorState(..state, sessions: new_sessions)
      persist(new_state)

      // Trust directory if Claude Code provider
      case task_spec.provider {
        provider.ClaudeCode -> {
          let _ = tmux.ensure_trusted(task_spec.cwd)
          Nil
        }
        _ -> Nil
      }

      // Build shell command and start tmux
      let shell_command =
        provider.build_command(
          task_spec.provider,
          task_spec.prompt,
          task_spec.cwd,
          session_name,
          task_spec.worktree,
        )
      case tmux.create_session(session_name, shell_command) {
        Error(reason) -> {
          // Clean up: remove from state and persist
          let rolled_back = dict.delete(new_sessions, session_name)
          let rolled_state = AcpActorState(..state, sessions: rolled_back)
          persist(rolled_state)
          #(rolled_state, Error("Failed to create tmux session: " <> reason))
        }
        Ok(Nil) -> {
          // Start monitor — events route back to this actor
          let on_event = fn(event) {
            process.send(state.self_subject, MonitorEvent(event))
          }
          case
            acp_monitor.start_monitor_only(
              task_spec,
              session_name,
              state.monitor_model,
              on_event,
              True,
              False,
            )
          {
            Ok(_) -> #(new_state, Ok(session_name))
            Error(err) -> {
              // tmux started but monitor failed — kill tmux, clean up
              let _ = tmux.kill_session(session_name)
              let rolled_back = dict.delete(new_sessions, session_name)
              let rolled_state = AcpActorState(..state, sessions: rolled_back)
              persist(rolled_state)
              #(rolled_state, Error("Monitor start failed: " <> err))
            }
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Kill
// ---------------------------------------------------------------------------

fn handle_kill(
  state: AcpActorState,
  session_name: String,
) -> #(AcpActorState, Result(Nil, String)) {
  case tmux.kill_session(session_name) {
    Ok(_) -> Nil
    Error(e) -> io.println("[acp] tmux kill failed for " <> session_name <> ": " <> e)
  }
  let new_state = unregister(state, session_name, Failed("killed"))
  #(new_state, Ok(Nil))
}

// ---------------------------------------------------------------------------
// Send input
// ---------------------------------------------------------------------------

fn handle_send_input(
  state: AcpActorState,
  session_name: String,
  input: String,
) -> Result(Nil, String) {
  case dict.get(state.sessions, session_name) {
    Error(_) -> {
      // Check if tmux session exists even if not in our state
      case tmux.session_exists(session_name) {
        True -> tmux.send_input(session_name, input)
        False -> Error("Session not found: " <> session_name)
      }
    }
    Ok(_) -> tmux.send_input(session_name, input)
  }
}

// ---------------------------------------------------------------------------
// Monitor events
// ---------------------------------------------------------------------------

fn handle_monitor_event(
  state: AcpActorState,
  event: acp_monitor.AcpEvent,
) -> AcpActorState {
  let new_state = case event {
    acp_monitor.AcpStarted(session_name, _, _) ->
      update_session_state(state, session_name, Running)
    acp_monitor.AcpTimedOut(session_name, _) ->
      unregister(state, session_name, TimedOut)
    acp_monitor.AcpCompleted(session_name, _, _) ->
      unregister(state, session_name, Complete)
    acp_monitor.AcpFailed(session_name, _, reason) ->
      unregister(state, session_name, Failed(reason))
    // Track idle_surfaced from progress events for persistence
    acp_monitor.AcpProgress(session_name, _, _, _, _, is_idle) -> {
      case is_idle {
        True -> update_idle_surfaced(state, session_name, True)
        False -> update_idle_surfaced(state, session_name, False)
      }
    }
    acp_monitor.AcpAlert(_, _, _, _) -> state
  }
  // Forward ALL events to the brain for Discord notifications
  state.on_brain_event(event)
  new_state
}

// ---------------------------------------------------------------------------
// State helpers
// ---------------------------------------------------------------------------

fn update_session_state(
  state: AcpActorState,
  session_name: String,
  new_session_state: SessionState,
) -> AcpActorState {
  case dict.get(state.sessions, session_name) {
    Error(_) -> {
      io.println(
        "[acp] Warning: state update for unknown session " <> session_name,
      )
      state
    }
    Ok(session) -> {
      io.println(
        "[acp] Session "
        <> session_name
        <> " state: "
        <> session_state_to_string(session.state)
        <> " -> "
        <> session_state_to_string(new_session_state),
      )
      let updated = ActiveSession(..session, state: new_session_state)
      let new_sessions = dict.insert(state.sessions, session_name, updated)
      let new_state = AcpActorState(..state, sessions: new_sessions)
      persist(new_state)
      new_state
    }
  }
}

fn unregister(
  state: AcpActorState,
  session_name: String,
  terminal_state: SessionState,
) -> AcpActorState {
  // First persist the terminal state (for history)
  let state_with_terminal = case dict.get(state.sessions, session_name) {
    Ok(session) -> {
      io.println(
        "[acp] Session "
        <> session_name
        <> " -> "
        <> session_state_to_string(terminal_state),
      )
      let updated = ActiveSession(..session, state: terminal_state)
      let new_sessions = dict.insert(state.sessions, session_name, updated)
      AcpActorState(..state, sessions: new_sessions)
    }
    Error(_) -> state
  }
  persist(state_with_terminal)
  // Then remove from active
  let new_sessions = dict.delete(state_with_terminal.sessions, session_name)
  AcpActorState(..state_with_terminal, sessions: new_sessions)
}

fn update_idle_surfaced(
  state: AcpActorState,
  session_name: String,
  idle_surfaced: Bool,
) -> AcpActorState {
  case dict.get(state.sessions, session_name) {
    Ok(session) -> {
      case session.idle_surfaced == idle_surfaced {
        True -> state
        False -> {
          let updated = ActiveSession(..session, idle_surfaced: idle_surfaced)
          let new_sessions = dict.insert(state.sessions, session_name, updated)
          let new_state = AcpActorState(..state, sessions: new_sessions)
          persist(new_state)
          new_state
        }
      }
    }
    Error(_) -> state
  }
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

fn persist(state: AcpActorState) -> Nil {
  let active_stored =
    list.map(dict.values(state.sessions), fn(s) {
      session_store.StoredSession(
        session_name: s.session_name,
        domain: s.domain,
        task_id: s.task_id,
        thread_id: s.thread_id,
        started_at_ms: s.started_at_ms,
        state: session_state_to_string(s.state),
        prompt: s.prompt,
        cwd: s.cwd,
        idle_surfaced: s.idle_surfaced,
      )
    })
  // Merge: active sessions + terminal sessions from disk
  let existing = session_store.load(state.store_path)
  let active_names = list.map(active_stored, fn(s) { s.session_name })
  let terminal =
    list.filter(existing, fn(s) {
      session_store.is_terminal(s.state)
      && !list.contains(active_names, s.session_name)
    })
  case session_store.save(state.store_path, list.append(active_stored, terminal)) {
    Ok(_) -> Nil
    Error(e) -> io.println("[acp] Persist failed: " <> e)
  }
}

// ---------------------------------------------------------------------------
// Recovery
// ---------------------------------------------------------------------------

fn recover_sessions(
  self_subject: process.Subject(AcpMessage),
  store_path: String,
  monitor_model: String,
  on_brain_event: fn(acp_monitor.AcpEvent) -> Nil,
) -> Dict(String, ActiveSession) {
  let stored = session_store.load(store_path)
  let active =
    list.filter(stored, fn(s) { !session_store.is_terminal(s.state) })

  case active {
    [] -> dict.new()
    _ -> {
      io.println(
        "[acp] Recovering "
        <> int.to_string(list.length(active))
        <> " session(s)...",
      )
      let pairs =
        list.filter_map(active, fn(s) {
          case tmux.session_exists(s.session_name) {
            True -> {
              io.println(
                "[acp] Recovering alive session: " <> s.session_name,
              )
              let session =
                ActiveSession(
                  session_name: s.session_name,
                  domain: s.domain,
                  task_id: s.task_id,
                  state: Running,
                  started_at_ms: s.started_at_ms,
                  thread_id: s.thread_id,
                  prompt: s.prompt,
                  cwd: s.cwd,
                  idle_surfaced: s.idle_surfaced,
                )
              // Start monitor for this session
              let task_spec =
                types.TaskSpec(
                  id: s.task_id,
                  domain: s.domain,
                  prompt: s.prompt,
                  cwd: s.cwd,
                  timeout_ms: 30 * 60_000,
                  acceptance_criteria: [],
                  provider: provider.ClaudeCode,
                  worktree: True,
                )
              let on_event = fn(event) {
                process.send(self_subject, MonitorEvent(event))
              }
              case
                acp_monitor.start_monitor_only(
                  task_spec,
                  s.session_name,
                  monitor_model,
                  on_event,
                  False,
                  s.idle_surfaced,
                )
              {
                Ok(_) ->
                  io.println(
                    "[acp] Monitor re-attached: " <> s.session_name,
                  )
                Error(e) ->
                  io.println(
                    "[acp] Failed to re-attach monitor for "
                    <> s.session_name
                    <> ": "
                    <> e,
                  )
              }
              Ok(#(s.session_name, session))
            }
            False -> {
              io.println(
                "[acp] Session dead, marking failed: " <> s.session_name,
              )
              // Update on disk
              let _ =
                session_store.upsert(
                  store_path,
                  session_store.StoredSession(
                    ..s,
                    state: "failed(restart-dead)",
                  ),
                )
              // Notify brain
              on_brain_event(acp_monitor.AcpFailed(
                s.session_name,
                s.domain,
                "tmux session disappeared during restart",
              ))
              Error(Nil)
            }
          }
        })
      dict.from_list(pairs)
    }
  }
}
