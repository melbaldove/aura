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

/// Start a stdio ACP session resuming a previous conversation.
/// The --resume flag tells Claude Code to load the previous session's context.
pub fn start_session_resume(
  command: String,
  cwd: String,
  resume_session_id: String,
  prompt: String,
) -> Result(#(SessionOwner, String), String) {
  let self_pid = process.self()
  start_session_resume_ffi(command, cwd, resume_session_id, prompt, self_pid)
}

@external(erlang, "aura_acp_stdio_ffi", "start_session_resume")
fn start_session_resume_ffi(
  command: String,
  cwd: String,
  resume_session_id: String,
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

// ---------------------------------------------------------------------------
// Test helpers — expose pure FFI functions for regression testing
// ---------------------------------------------------------------------------

/// Encode a Gleam value to JSON using the FFI encoder.
@external(erlang, "aura_acp_stdio_ffi", "jsx_encode")
pub fn ffi_jsx_encode(value: a) -> String

/// Escape a string for JSON embedding.
@external(erlang, "aura_acp_stdio_ffi", "json_escape")
pub fn ffi_json_escape(value: String) -> String

/// Extract a string field from a JSON line by marker.
@external(erlang, "aura_acp_stdio_ffi", "extract_field")
pub fn ffi_extract_field(line: String, marker: String) -> String

/// Extract the sessionId from a JSON-RPC response line.
@external(erlang, "aura_acp_stdio_ffi", "extract_session_id")
pub fn ffi_extract_session_id(line: String) -> String

/// Check if a JSON-RPC response is an error.
pub type ErrorCheck {
  IsError(message: String)
  NotError
}

/// Check if a JSON-RPC response line contains an error.
pub fn ffi_is_error_response(line: String) -> ErrorCheck {
  case ffi_is_error_response_raw(line) {
    #(True, msg) -> IsError(msg)
    #(False, _) -> NotError
  }
}

@external(erlang, "aura_acp_stdio_ffi", "is_error_response")
fn ffi_is_error_response_raw(line: String) -> #(Bool, String)
