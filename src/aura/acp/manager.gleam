import aura/acp/monitor
import aura/acp/tmux
import aura/acp/types
import gleam/int
import gleam/list

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type AcpManager {
  AcpManager(max_concurrent: Int, active_sessions: List(ActiveSession))
}

pub type ActiveSession {
  ActiveSession(session_name: String, workstream: String, task_id: String)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn new(max_concurrent: Int) -> AcpManager {
  AcpManager(max_concurrent: max_concurrent, active_sessions: [])
}

pub fn can_start(manager: AcpManager) -> Bool {
  list.length(manager.active_sessions) < manager.max_concurrent
}

pub fn register(manager: AcpManager, session: ActiveSession) -> AcpManager {
  AcpManager(..manager, active_sessions: [session, ..manager.active_sessions])
}

pub fn unregister(manager: AcpManager, session_name: String) -> AcpManager {
  let remaining =
    list.filter(manager.active_sessions, fn(s) {
      s.session_name != session_name
    })
  AcpManager(..manager, active_sessions: remaining)
}

pub fn dispatch(
  manager: AcpManager,
  task_spec: types.TaskSpec,
  monitor_model: String,
  on_event: fn(monitor.AcpEvent) -> Nil,
) -> Result(AcpManager, String) {
  case can_start(manager) {
    False ->
      Error(
        "ACP concurrency limit reached ("
        <> int.to_string(manager.max_concurrent)
        <> ")",
      )
    True -> {
      case monitor.start(task_spec, monitor_model, on_event) {
        Ok(_subject) -> {
          let session =
            ActiveSession(
              session_name: tmux.build_session_name(
                task_spec.workstream,
                task_spec.id,
              ),
              workstream: task_spec.workstream,
              task_id: task_spec.id,
            )
          Ok(register(manager, session))
        }
        Error(err) -> Error(err)
      }
    }
  }
}
