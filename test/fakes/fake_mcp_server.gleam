//// Fake MCP server for driving deterministic tests of `aura/mcp/client`.
////
//// The actual server is an Erlang escript at
//// `scripts/fake_mcp_server.escript`. This Gleam module is a thin builder:
//// you describe the expected interaction as a list of `Step` values, and
//// `start/1` writes them to a temp file and returns a `FakeMcpServer` whose
//// `command` is the escript path and whose `args` point at the script file.
////
//// The escript reads JSON-RPC from stdin, asserts each request matches the
//// next `ExpectRequest` / `ExpectNotification` step, and emits the scripted
//// responses / notifications in order. On mismatch it writes to stderr and
//// exits 1 — the client sees the process exit, which is itself an observable
//// failure signal.
////
//// Why an escript and not a Gleam/Python binary?
////  - Python isn't guaranteed on the Nix machines we test on.
////  - A Gleam test binary needs a separate build target; too much overhead
////    for a single fixture.
////  - escript runs anywhere the BEAM runs, which is exactly where we need it.

import aura/time
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import simplifile

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One step in the scripted conversation. Steps are interpreted in order:
/// `ExpectRequest` / `ExpectNotification` block for the next line on stdin,
/// `RespondResult` / `RespondError` write a response correlated with the id
/// of the most recently expected request, and `EmitNotification` /
/// `EmitRaw` send server-initiated output.
pub type Step {
  /// Assert the next incoming line is a JSON-RPC request with this method.
  /// Remembers the id for the next `RespondResult` / `RespondError`.
  ExpectRequest(method: String)
  /// Assert the next incoming line is a notification with this method
  /// (i.e. no `id` field).
  ExpectNotification(method: String)
  /// Send a success response with the remembered id and the given raw JSON
  /// as the `"result"` field.
  RespondResult(result_json: String)
  /// Send an error response with the remembered id.
  RespondError(code: Int, message: String)
  /// Send a server-initiated notification.
  EmitNotification(method: String, params_json: String)
  /// Send a raw line verbatim, bypassing JSON validity. Used for the
  /// malformed-JSON test.
  EmitRaw(line: String)
  /// Terminate the escript with the given exit code. Used by the crash-exit
  /// test to exercise the abnormal-stop path.
  ExitWithCode(code: Int)
}

pub opaque type FakeMcpServer {
  FakeMcpServer(script_path: String, steps: List(Step))
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Locate the escript (relative to the repo root — tests always run with
/// cwd = repo root).
pub fn escript_path() -> String {
  "scripts/fake_mcp_server.escript"
}

/// Write a script file for the given `steps`, returning a `FakeMcpServer`
/// you can pass to `command` / `args` to spawn via the MCP client. Files
/// live under `/tmp/aura-fake-mcp-<ts>.script` and are cleaned up by
/// `stop/1`.
pub fn start(steps: List(Step)) -> FakeMcpServer {
  // Include a monotonically-increasing unique integer alongside the ms
  // timestamp so tests that run in the same millisecond don't share a
  // script path and race on delete-vs-exec.
  let ts = int.to_string(time.now_ms())
  let uniq = int.to_string(unique_integer())
  let path = "/tmp/aura-fake-mcp-" <> ts <> "-" <> uniq <> ".script"
  let content = serialize(steps)
  let assert Ok(_) = simplifile.write(path, content)
  FakeMcpServer(script_path: path, steps: steps)
}

fn unique_integer() -> Int {
  int.absolute_value(erlang_unique_integer())
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

/// The command to spawn this fake. Always `escript`, since we use a
/// pre-existing Erlang binary.
pub fn command(server: FakeMcpServer) -> String {
  let _ = server
  "escript"
}

/// Command-line args. The escript reads its script file from `argv[1]`.
pub fn args(server: FakeMcpServer) -> List(String) {
  [escript_path(), server.script_path]
}

/// Delete the temp script file. Does not kill the subprocess — the client
/// owns that.
pub fn stop(server: FakeMcpServer) -> Nil {
  let _ = simplifile.delete(server.script_path)
  Nil
}

// ---------------------------------------------------------------------------
// Helpers for building common scripted result values
// ---------------------------------------------------------------------------

/// A canonical `initialize` response body (result JSON only). Matches the MCP
/// 2025-06-18 shape enough to let the client advance past the handshake.
pub fn initialize_result_json() -> String {
  json.object([
    #("protocolVersion", json.string("2025-06-18")),
    #(
      "serverInfo",
      json.object([
        #("name", json.string("fake-mcp")),
        #("version", json.string("0.0.1")),
      ]),
    ),
    #(
      "capabilities",
      json.object([#("resources", json.object([]))]),
    ),
  ])
  |> json.to_string
}

// ---------------------------------------------------------------------------
// Script serialisation
// ---------------------------------------------------------------------------

fn serialize(steps: List(Step)) -> String {
  steps
  |> list.map(step_line)
  |> string.join("\n")
  |> string.append("\n")
}

fn step_line(step: Step) -> String {
  case step {
    ExpectRequest(method) -> "EXPECT_REQUEST " <> method
    ExpectNotification(method) -> "EXPECT_NOTIFICATION " <> method
    RespondResult(result_json) -> "RESPOND_RESULT " <> result_json
    RespondError(code, message) ->
      "RESPOND_ERROR " <> int.to_string(code) <> " " <> message
    EmitNotification(method, params_json) ->
      "EMIT_NOTIFICATION " <> method <> " " <> params_json
    EmitRaw(line) -> "EMIT_RAW " <> line
    ExitWithCode(code) -> "EXIT_WITH_CODE " <> int.to_string(code)
  }
}
