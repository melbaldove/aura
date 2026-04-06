import aura/acp/monitor
import aura/acp/session_store
import aura/acp/tmux
import aura/acp/types
import aura/time
import gleam/int
import gleam/io
import gleam/list

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type AcpManager {
  AcpManager(
    max_concurrent: Int,
    active_sessions: List(ActiveSession),
    store_path: String,
  )
}

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
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn new(max_concurrent: Int, store_path: String) -> AcpManager {
  AcpManager(
    max_concurrent: max_concurrent,
    active_sessions: [],
    store_path: store_path,
  )
}

pub fn can_start(manager: AcpManager) -> Bool {
  list.length(manager.active_sessions) < manager.max_concurrent
}

pub fn register(
  manager: AcpManager,
  session: ActiveSession,
  prompt: String,
  cwd: String,
) -> AcpManager {
  // Persist to store
  let stored =
    session_store.StoredSession(
      session_name: session.session_name,
      domain: session.domain,
      task_id: session.task_id,
      thread_id: session.thread_id,
      started_at_ms: session.started_at_ms,
      state: session_state_to_string(session.state),
      prompt: prompt,
      cwd: cwd,
    )
  let _ = session_store.upsert(manager.store_path, stored)
  AcpManager(..manager, active_sessions: [session, ..manager.active_sessions])
}

pub fn unregister(
  manager: AcpManager,
  session_name: String,
  terminal_state: SessionState,
) -> AcpManager {
  // Update the store to mark as terminal (keep for history, don't remove)
  let sessions = session_store.load(manager.store_path)
  let updated =
    list.map(sessions, fn(s) {
      case s.session_name == session_name {
        True ->
          session_store.StoredSession(
            ..s,
            state: session_state_to_string(terminal_state),
          )
        False -> s
      }
    })
  let _ = session_store.save(manager.store_path, updated)
  // Remove from in-memory active list
  let remaining =
    list.filter(manager.active_sessions, fn(s) {
      s.session_name != session_name
    })
  AcpManager(..manager, active_sessions: remaining)
}

/// Update a session's state and log the transition.
pub fn update_state(
  manager: AcpManager,
  session_name: String,
  new_state: SessionState,
) -> AcpManager {
  let new_sessions =
    list.map(manager.active_sessions, fn(s) {
      case s.session_name == session_name {
        True -> {
          io.println(
            "[acp] Session "
            <> session_name
            <> " state: "
            <> session_state_to_string(s.state)
            <> " → "
            <> session_state_to_string(new_state),
          )
          ActiveSession(..s, state: new_state)
        }
        False -> s
      }
    })
  // Persist state change to store
  let stored_sessions = session_store.load(manager.store_path)
  let updated_stored =
    list.map(stored_sessions, fn(s) {
      case s.session_name == session_name {
        True ->
          session_store.StoredSession(
            ..s,
            state: session_state_to_string(new_state),
          )
        False -> s
      }
    })
  let _ = session_store.save(manager.store_path, updated_stored)
  AcpManager(..manager, active_sessions: new_sessions)
}

/// Look up a session by name.
pub fn get_session(
  manager: AcpManager,
  session_name: String,
) -> Result(ActiveSession, Nil) {
  list.find(manager.active_sessions, fn(s) {
    s.session_name == session_name
  })
}

/// List all active sessions.
pub fn list_sessions(manager: AcpManager) -> List(ActiveSession) {
  manager.active_sessions
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

pub fn dispatch(
  manager: AcpManager,
  task_spec: types.TaskSpec,
  monitor_model: String,
  on_event: fn(monitor.AcpEvent) -> Nil,
  thread_id: String,
) -> Result(AcpManager, String) {
  case can_start(manager) {
    False ->
      Error(
        "ACP concurrency limit reached ("
        <> int.to_string(manager.max_concurrent)
        <> ")",
      )
    True -> {
      // Register session BEFORE starting monitor — monitor emits AcpStarted
      // during init, and the brain needs to find the session to resolve the thread_id
      let session =
        ActiveSession(
          session_name: tmux.build_session_name(
            task_spec.domain,
            task_spec.id,
          ),
          domain: task_spec.domain,
          task_id: task_spec.id,
          state: Starting,
          started_at_ms: time.now_ms(),
          thread_id: thread_id,
        )
      let new_manager =
        register(manager, session, task_spec.prompt, task_spec.cwd)
      case monitor.start(task_spec, monitor_model, on_event) {
        Ok(_subject) -> {
          Ok(new_manager)
        }
        Error(err) -> Error(err)
      }
    }
  }
}
