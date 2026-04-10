import gleam/erlang/process
import gleam/json

/// Opaque Erlang port handle for a child process.
pub type Port

/// Messages received from a stdio child process.
pub type StdioMessage {
  Line(data: String)
  Exit(code: String)
  Error(reason: String)
  Timeout
}

/// Start a child process. Returns the Erlang port.
/// The callback_pid receives {stdio_line, Line} messages from the reader.
pub fn start(command: String, callback_pid: process.Pid) -> Port {
  start_ffi(command, callback_pid)
}

@external(erlang, "aura_acp_stdio_ffi", "start")
fn start_ffi(command: String, callback_pid: process.Pid) -> Port

/// Send a line of text to the child process stdin.
pub fn send_line(port: Port, data: String) -> Result(Nil, String) {
  send_line_ffi(port, data)
}

@external(erlang, "aura_acp_stdio_ffi", "send_line")
fn send_line_ffi(port: Port, data: String) -> Result(Nil, String)

/// Close the port (kills child process).
pub fn close(port: Port) -> Nil {
  close_ffi(port)
}

@external(erlang, "aura_acp_stdio_ffi", "close")
fn close_ffi(port: Port) -> Nil

/// Receive a message from the reader process mailbox.
/// Blocks for up to `timeout_ms` milliseconds.
pub fn receive_message(timeout_ms: Int) -> StdioMessage {
  case receive_line_ffi(timeout_ms) {
    #("line", data) -> Line(data)
    #("exit", code) -> Exit(code)
    #("error", reason) -> Error(reason)
    _ -> Timeout
  }
}

@external(erlang, "aura_acp_stdio_ffi", "receive_line")
fn receive_line_ffi(timeout_ms: Int) -> #(String, String)

/// Send a JSON-RPC request (has id, expects response).
pub fn send_jsonrpc(
  port: Port,
  id: Int,
  method: String,
  params: json.Json,
) -> Result(Nil, String) {
  let msg =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(id)),
      #("method", json.string(method)),
      #("params", params),
    ])
    |> json.to_string
  send_line(port, msg)
}

/// Send a JSON-RPC notification (no id, no response expected).
pub fn send_notification(
  port: Port,
  method: String,
  params: json.Json,
) -> Result(Nil, String) {
  let msg =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("method", json.string(method)),
      #("params", params),
    ])
    |> json.to_string
  send_line(port, msg)
}
