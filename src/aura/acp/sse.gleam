import gleam/erlang/process

/// Represents a parsed SSE event received from an ACP server.
pub type SseEvent {
  Event(event_type: String, data: String)
  Error(reason: String)
  Done
  Timeout
}

/// Start an SSE subscription in a spawned process.
/// Events are sent to callback_pid's mailbox as:
///   {sse_event, EventType, Data}
///   {sse_error, Reason}
///   sse_done
pub fn subscribe(
  url: String,
  headers: List(#(String, String)),
  callback_pid: process.Pid,
) -> Nil {
  subscribe_ffi(url, headers, callback_pid)
}

@external(erlang, "aura_acp_sse_ffi", "subscribe")
fn subscribe_ffi(
  url: String,
  headers: List(#(String, String)),
  callback_pid: process.Pid,
) -> Nil

/// Receive an SSE event from the process mailbox.
/// Blocks for up to `timeout_ms` milliseconds.
pub fn receive_event(timeout_ms: Int) -> SseEvent {
  case receive_event_ffi(timeout_ms) {
    #("event", event_type, data) -> Event(event_type, data)
    #("error", reason, _) -> Error(reason)
    #("done", _, _) -> Done
    _ -> Timeout
  }
}

@external(erlang, "aura_acp_sse_ffi", "receive_sse_event")
fn receive_event_ffi(timeout_ms: Int) -> #(String, String, String)
