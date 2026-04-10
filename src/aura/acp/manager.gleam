import aura/acp/client
import aura/acp/monitor as acp_monitor
import aura/acp/provider
import aura/acp/session_store
import aura/acp/sse
import aura/acp/tmux
import aura/acp/transport
import aura/acp/types
import aura/time
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
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
    run_id: String,
    state: SessionState,
    started_at_ms: Int,
    thread_id: String,
    prompt: String,
    cwd: String,
    idle_surfaced: Bool,
    handle: Option(transport.SessionHandle),
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
    transport: transport.Transport,
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
  acp_transport: transport.Transport,
) -> Result(process.Subject(AcpMessage), String) {
  let builder =
    actor.new_with_initialiser(10_000, fn(self_subject) {
      // Recovery: load persisted sessions, check status, start monitors
      let sessions =
        recover_sessions(
          self_subject,
          store_path,
          monitor_model,
          on_brain_event,
          acp_transport,
        )

      let state =
        AcpActorState(
          sessions: sessions,
          max_concurrent: max_concurrent,
          store_path: store_path,
          monitor_model: monitor_model,
          on_brain_event: on_brain_event,
          self_subject: self_subject,
          transport: acp_transport,
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
// Dispatch — single path via transport abstraction
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
          run_id: "",
          state: Starting,
          started_at_ms: time.now_ms(),
          thread_id: thread_id,
          prompt: task_spec.prompt,
          cwd: task_spec.cwd,
          idle_surfaced: False,
          handle: None,
        )

      // Insert and persist BEFORE dispatch
      let new_sessions = dict.insert(state.sessions, session_name, session)
      let new_state = AcpActorState(..state, sessions: new_sessions)
      persist(new_state)

      let on_event = fn(event) {
        process.send(state.self_subject, MonitorEvent(event))
      }
      case
        transport.dispatch(
          state.transport,
          session_name,
          task_spec,
          state.monitor_model,
          on_event,
        )
      {
        Ok(result) -> {
          let updated_session =
            ActiveSession(
              ..session,
              run_id: result.run_id,
              handle: Some(result.handle),
            )
          let final_sessions =
            dict.insert(new_sessions, session_name, updated_session)
          let final_state =
            AcpActorState(..state, sessions: final_sessions)
          persist(final_state)
          #(final_state, Ok(session_name))
        }
        Error(err) -> {
          // Clean up: remove from state and persist
          let rolled_back = dict.delete(new_sessions, session_name)
          let rolled_state = AcpActorState(..state, sessions: rolled_back)
          persist(rolled_state)
          #(rolled_state, Error(err))
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Kill — via transport abstraction
// ---------------------------------------------------------------------------

fn handle_kill(
  state: AcpActorState,
  session_name: String,
) -> #(AcpActorState, Result(Nil, String)) {
  case dict.get(state.sessions, session_name) {
    Ok(session) -> {
      let handle = option.unwrap(session.handle, transport.TmuxHandle)
      case transport.kill(state.transport, handle, session_name) {
        Ok(_) -> Nil
        Error(e) ->
          io.println(
            "[acp] Kill failed for " <> session_name <> ": " <> e,
          )
      }
    }
    Error(_) -> Nil
  }
  let new_state = unregister(state, session_name, Failed("killed"))
  #(new_state, Ok(Nil))
}

// ---------------------------------------------------------------------------
// Send input — via transport abstraction
// ---------------------------------------------------------------------------

fn handle_send_input(
  state: AcpActorState,
  session_name: String,
  input: String,
) -> Result(Nil, String) {
  case dict.get(state.sessions, session_name) {
    Ok(session) -> {
      let handle = option.unwrap(session.handle, transport.TmuxHandle)
      transport.send_input(state.transport, handle, session_name, input)
    }
    Error(_) -> {
      // Fallback: for tmux transport, check if tmux session exists directly
      case state.transport {
        transport.Tmux -> {
          case tmux.session_exists(session_name) {
            True -> tmux.send_input(session_name, input)
            False -> Error("Session not found: " <> session_name)
          }
        }
        _ -> Error("Session not found: " <> session_name)
      }
    }
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
    acp_monitor.AcpCompleted(session_name, _, _, _) ->
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
        run_id: s.run_id,
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
// Recovery — uses transport.is_alive for status checks
// ---------------------------------------------------------------------------

fn recover_sessions(
  self_subject: process.Subject(AcpMessage),
  store_path: String,
  monitor_model: String,
  on_brain_event: fn(acp_monitor.AcpEvent) -> Nil,
  acp_transport: transport.Transport,
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
          recover_session(
            s,
            self_subject,
            store_path,
            monitor_model,
            on_brain_event,
            acp_transport,
          )
        })
      dict.from_list(pairs)
    }
  }
}

/// Recover a single session using transport.is_alive to check status.
fn recover_session(
  s: session_store.StoredSession,
  self_subject: process.Subject(AcpMessage),
  store_path: String,
  monitor_model: String,
  on_brain_event: fn(acp_monitor.AcpEvent) -> Nil,
  acp_transport: transport.Transport,
) -> Result(#(String, ActiveSession), Nil) {
  case transport.is_alive(acp_transport, s.run_id, s.session_name) {
    True -> {
      io.println("[acp] Recovering alive session: " <> s.session_name)
      let session =
        ActiveSession(
          session_name: s.session_name,
          domain: s.domain,
          task_id: s.task_id,
          run_id: s.run_id,
          state: Running,
          started_at_ms: s.started_at_ms,
          thread_id: s.thread_id,
          prompt: s.prompt,
          cwd: s.cwd,
          idle_surfaced: s.idle_surfaced,
          handle: None,
        )

      // Start appropriate listener/monitor for the recovered session
      let on_event = fn(event) {
        process.send(self_subject, MonitorEvent(event))
      }

      case acp_transport {
        transport.Tmux -> {
          // Re-attach tmux monitor
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
              io.println("[acp] Monitor re-attached: " <> s.session_name)
            Error(e) ->
              io.println(
                "[acp] Failed to re-attach monitor for "
                <> s.session_name
                <> ": "
                <> e,
              )
          }
        }
        transport.Http(server_url, _) -> {
          // Re-start SSE listener for HTTP sessions
          let run_id = s.run_id
          let domain = s.domain
          let session_name = s.session_name
          process.spawn_unlinked(fn() {
            let self_pid = process.self()
            process.spawn_unlinked(fn() {
              client.subscribe_events(server_url, run_id, self_pid)
            })
            http_recovery_event_loop(
              on_event,
              session_name,
              domain,
              run_id,
              server_url,
            )
          })
          Nil
        }
        transport.Stdio(_) -> {
          // Stdio sessions can't survive restarts — should never reach here
          // because is_alive returns False for stdio
          Nil
        }
      }

      Ok(#(s.session_name, session))
    }
    False -> {
      io.println(
        "[acp] Session dead, marking failed: " <> s.session_name,
      )
      let _ =
        session_store.upsert(
          store_path,
          session_store.StoredSession(..s, state: "failed(restart-dead)"),
        )
      on_brain_event(acp_monitor.AcpFailed(
        s.session_name,
        s.domain,
        "session disappeared during restart",
      ))
      Error(Nil)
    }
  }
}

/// SSE event loop for HTTP recovery — uses on_event callback.
fn http_recovery_event_loop(
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
  session_name: String,
  domain: String,
  run_id: String,
  server_url: String,
) -> Nil {
  case sse.receive_event(300_000) {
    sse.Event(event_type, data) -> {
      case event_type {
        "run.in-progress" ->
          on_event(acp_monitor.AcpStarted(session_name, domain, run_id))
        "run.awaiting" ->
          on_event(
            acp_monitor.AcpAlert(
              session_name,
              domain,
              types.Blocked,
              "Agent awaiting input",
            ),
          )
        "run.completed" ->
          on_event(
            acp_monitor.AcpCompleted(
              session_name,
              domain,
              types.AcpReport(
                outcome: types.Clean,
                files_changed: [],
                decisions: "",
                tests: "",
                blockers: "",
                anchor: data,
              ),
              data,
            ),
          )
        "run.failed" ->
          on_event(acp_monitor.AcpFailed(session_name, domain, data))
        "run.cancelled" ->
          on_event(acp_monitor.AcpFailed(session_name, domain, "cancelled"))
        "message.part" ->
          on_event(
            acp_monitor.AcpProgress(session_name, domain, "", "", data, False),
          )
        _ -> Nil
      }
      case event_type {
        "run.completed" | "run.failed" | "run.cancelled" -> Nil
        _ ->
          http_recovery_event_loop(
            on_event,
            session_name,
            domain,
            run_id,
            server_url,
          )
      }
    }
    sse.Error(reason) -> {
      io.println("[acp-sse] Error for " <> session_name <> ": " <> reason)
      process.sleep(5000)
      let self_pid = process.self()
      process.spawn_unlinked(fn() {
        client.subscribe_events(server_url, run_id, self_pid)
      })
      http_recovery_event_loop(
        on_event,
        session_name,
        domain,
        run_id,
        server_url,
      )
    }
    sse.Done -> {
      io.println("[acp-sse] Stream ended for " <> session_name)
      Nil
    }
    sse.Timeout -> {
      io.println("[acp-sse] Timeout for " <> session_name <> ", reconnecting")
      let self_pid = process.self()
      process.spawn_unlinked(fn() {
        client.subscribe_events(server_url, run_id, self_pid)
      })
      http_recovery_event_loop(
        on_event,
        session_name,
        domain,
        run_id,
        server_url,
      )
    }
  }
}
