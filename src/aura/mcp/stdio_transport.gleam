//// Thin Gleam wrapper around `aura_mcp_stdio_ffi`. The FFI owns the Erlang
//// port; this module exposes the three operations a client needs: start
//// the subprocess, send a JSON-RPC line, and close it down.
////
//// The FFI forwards raw stdout lines to the receiver pid as
//// `{mcp_line, Handle, RawLine}` and subprocess exit as
//// `{mcp_exit, Handle, Status}`. Callers translate those tagged tuples into
//// their own actor messages via `process.select_record`.

import gleam/erlang/process.{type Pid}

/// Opaque handle returned by `start`. Under the hood this is the pid of the
/// owner process that holds the Erlang port.
pub type Handle

/// Spawn the subprocess and register `receiver_pid` to receive parsed lines.
///
/// Each complete newline-terminated line from the subprocess stdout is
/// delivered to `receiver_pid` as the raw tagged tuple
/// `{mcp_line, Handle, RawLine}`. Subprocess exit delivers
/// `{mcp_exit, Handle, Status}`. Both are Erlang tuples, not Gleam Subjects —
/// use `process.select_record` to translate them into actor messages.
@external(erlang, "aura_mcp_stdio_ffi", "start")
pub fn start(
  command: String,
  args: List(String),
  env: List(#(String, String)),
  receiver_pid: Pid,
) -> Result(Handle, String)

/// Send a single JSON-RPC line to the subprocess stdin. The FFI appends the
/// newline, so pass the JSON object without a trailing `\n`.
@external(erlang, "aura_mcp_stdio_ffi", "send_line")
pub fn send_line(handle: Handle, json_line: String) -> Result(Nil, String)

/// Close the subprocess. Idempotent.
@external(erlang, "aura_mcp_stdio_ffi", "close")
pub fn close(handle: Handle) -> Nil
