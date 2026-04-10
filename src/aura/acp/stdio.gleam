import gleam/erlang/process

/// Opaque handle to a stdio session owner process.
pub type SessionOwner

/// Events received from a stdio session.
pub type SessionEvent {
  Event(event_type: String, data: String)
  Complete(stop_reason: String)
  Exit(code: String)
  Error(reason: String)
  Timeout
}

/// Start a stdio ACP session. Spawns the child process, runs the
/// initialize + session/new + session/prompt handshake, and returns
/// the session owner pid + session ID.
/// The owner process stays alive, reading events and accepting input.
/// Events are sent to the calling process's mailbox.
pub fn start_session(
  command: String,
  cwd: String,
  prompt: String,
) -> Result(#(SessionOwner, String), String) {
  let self_pid = process.self()
  start_session_ffi(command, cwd, prompt, self_pid)
}

@external(erlang, "aura_acp_stdio_ffi", "start_session")
fn start_session_ffi(
  command: String,
  cwd: String,
  prompt: String,
  event_pid: process.Pid,
) -> Result(#(SessionOwner, String), String)

/// Send input to a running session (subsequent prompt).
pub fn send_input(
  owner: SessionOwner,
  session_id: String,
  text: String,
) -> Result(Nil, String) {
  send_input_ffi(owner, session_id, text)
}

@external(erlang, "aura_acp_stdio_ffi", "send_input")
fn send_input_ffi(
  owner: SessionOwner,
  session_id: String,
  text: String,
) -> Result(Nil, String)

/// Close the session (sends cancel + closes port).
pub fn close(owner: SessionOwner) -> Nil {
  close_ffi(owner)
}

@external(erlang, "aura_acp_stdio_ffi", "close_session")
fn close_ffi(owner: SessionOwner) -> Nil

/// Receive an event from the session owner process.
pub fn receive_event(timeout_ms: Int) -> SessionEvent {
  case receive_event_ffi(timeout_ms) {
    #("event", event_type, data) -> Event(event_type, data)
    #("complete", stop_reason, _) -> Complete(stop_reason)
    #("exit", code, _) -> Exit(code)
    #("error", reason, _) -> Error(reason)
    _ -> Timeout
  }
}

@external(erlang, "aura_acp_stdio_ffi", "receive_event")
fn receive_event_ffi(timeout_ms: Int) -> #(String, String, String)
