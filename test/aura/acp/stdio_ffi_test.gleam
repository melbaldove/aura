import aura/acp/stdio
import gleeunit/should

// ---------------------------------------------------------------------------
// jsx_encode — regression tests for malformed JSON bug
// The original bug: maps:fold collected 4 separate iolist elements per pair,
// so lists:join put commas between each element instead of between pairs.
// Output was: {"key",":",value,...} instead of {"key":value,...}
// ---------------------------------------------------------------------------

pub fn jsx_encode_empty_map_test() {
  stdio.ffi_jsx_encode(make_empty_map())
  |> should.equal("{}")
}

pub fn jsx_encode_single_key_map_test() {
  stdio.ffi_jsx_encode(make_single_map("name", "aura"))
  |> should.equal("{\"name\":\"aura\"}")
}

pub fn jsx_encode_nested_map_test() {
  // Simulates the session/new params: {"cwd":"/tmp","mcpServers":[]}
  let json = stdio.ffi_jsx_encode(make_session_new_params("/tmp"))
  // Must contain proper key:value pairs, not broken {[...
  json |> string_contains("\"cwd\":\"/tmp\"") |> should.be_true
  json |> string_contains("\"mcpServers\":[]") |> should.be_true
  // Must start with { and end with }
  json |> string_starts_with("{") |> should.be_true
  json |> string_ends_with("}") |> should.be_true
}

pub fn jsx_encode_prompt_params_test() {
  // Simulates session/prompt params — the exact structure that was broken
  let json =
    stdio.ffi_jsx_encode(
      make_prompt_params("sess_123", "Analyze the code"),
    )
  json |> string_contains("\"sessionId\":\"sess_123\"") |> should.be_true
  json |> string_contains("\"prompt\":[") |> should.be_true
  json |> string_contains("\"type\":\"text\"") |> should.be_true
  json |> string_contains("\"text\":\"Analyze the code\"") |> should.be_true
  // Must NOT have the broken {[ pattern
  json |> string_contains("{[") |> should.be_false
}

pub fn jsx_encode_list_test() {
  stdio.ffi_jsx_encode(make_string_list())
  |> should.equal("[\"a\",\"b\",\"c\"]")
}

pub fn jsx_encode_integer_test() {
  stdio.ffi_jsx_encode(1)
  |> should.equal("1")
}

pub fn jsx_encode_boolean_test() {
  stdio.ffi_jsx_encode(True)
  |> should.equal("true")
}

// ---------------------------------------------------------------------------
// json_escape — special character handling
// ---------------------------------------------------------------------------

pub fn json_escape_plain_test() {
  stdio.ffi_json_escape("hello")
  |> should.equal("hello")
}

pub fn json_escape_quotes_test() {
  stdio.ffi_json_escape("say \"hi\"")
  |> should.equal("say \\\"hi\\\"")
}

pub fn json_escape_newlines_test() {
  stdio.ffi_json_escape("line1\nline2")
  |> should.equal("line1\\nline2")
}

pub fn json_escape_backslash_test() {
  stdio.ffi_json_escape("path\\to\\file")
  |> should.equal("path\\\\to\\\\file")
}

pub fn json_escape_tabs_test() {
  stdio.ffi_json_escape("col1\tcol2")
  |> should.equal("col1\\tcol2")
}

// ---------------------------------------------------------------------------
// extract_session_id — regression test for "unknown" session ID bug
// The bug: session/new might return an error response, or the field
// might be nested differently than expected.
// ---------------------------------------------------------------------------

pub fn extract_session_id_from_valid_response_test() {
  // Exact format per ACP spec: {"jsonrpc":"2.0","id":1,"result":{"sessionId":"sess_abc123"}}
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"sess_abc123\"}}"
  stdio.ffi_extract_session_id(line)
  |> should.equal("sess_abc123")
}

pub fn extract_session_id_missing_returns_unknown_test() {
  // Error response has no sessionId
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Invalid params\"}}"
  stdio.ffi_extract_session_id(line)
  |> should.equal("unknown")
}

pub fn extract_session_id_with_uuid_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"a1b2c3d4-e5f6-7890-abcd-ef1234567890\"}}"
  stdio.ffi_extract_session_id(line)
  |> should.equal("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
}

// ---------------------------------------------------------------------------
// extract_field — general field extraction
// ---------------------------------------------------------------------------

pub fn extract_field_stop_reason_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"stopReason\":\"end_turn\"}}"
  stdio.ffi_extract_field(line, "\"stopReason\":\"")
  |> should.equal("end_turn")
}

pub fn extract_field_session_update_type_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Hello\"}}}}"
  stdio.ffi_extract_field(line, "\"sessionUpdate\":\"")
  |> should.equal("agent_message_chunk")
}

pub fn extract_field_missing_returns_empty_test() {
  let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
  stdio.ffi_extract_field(line, "\"sessionId\":\"")
  |> should.equal("")
}

pub fn extract_field_with_escaped_quotes_test() {
  let line = "{\"field\":\"value with \\\"quotes\\\"\"}"
  stdio.ffi_extract_field(line, "\"field\":\"")
  |> should.equal("value with \"quotes\"")
}

// ---------------------------------------------------------------------------
// is_error_response — regression test for silent error swallowing
// The bug: wait_response treated error responses as success, causing
// extract_session_id to return "unknown" and session/prompt to fail.
// ---------------------------------------------------------------------------

pub fn is_error_response_detects_error_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Invalid params\",\"data\":{\"details\":\"Missing mcpServers\"}}}"
  case stdio.ffi_is_error_response(line) {
    stdio.IsError(msg) ->
      msg |> string_contains("Invalid params") |> should.be_true
    stdio.NotError -> should.fail()
  }
}

pub fn is_error_response_passes_success_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"sess_123\"}}"
  stdio.ffi_is_error_response(line)
  |> should.equal(stdio.NotError)
}

pub fn is_error_response_includes_details_test() {
  let line =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"Internal error\",\"data\":{\"details\":\"Session not found\"}}}"
  case stdio.ffi_is_error_response(line) {
    stdio.IsError(msg) ->
      msg |> string_contains("Session not found") |> should.be_true
    stdio.NotError -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// Erlang FFI helpers — construct Erlang-native types for testing
// ---------------------------------------------------------------------------

@external(erlang, "aura_acp_stdio_ffi_test_helpers", "make_empty_map")
fn make_empty_map() -> a

@external(erlang, "aura_acp_stdio_ffi_test_helpers", "make_single_map")
fn make_single_map(key: String, value: String) -> a

@external(erlang, "aura_acp_stdio_ffi_test_helpers", "make_session_new_params")
fn make_session_new_params(cwd: String) -> a

@external(erlang, "aura_acp_stdio_ffi_test_helpers", "make_prompt_params")
fn make_prompt_params(session_id: String, text: String) -> a

@external(erlang, "aura_acp_stdio_ffi_test_helpers", "make_string_list")
fn make_string_list() -> a

// ---------------------------------------------------------------------------
// String helpers
// ---------------------------------------------------------------------------

@external(erlang, "aura_acp_stdio_ffi_test_helpers", "string_contains")
fn string_contains(haystack: String, needle: String) -> Bool

@external(erlang, "aura_acp_stdio_ffi_test_helpers", "string_starts_with")
fn string_starts_with(string: String, prefix: String) -> Bool

@external(erlang, "aura_acp_stdio_ffi_test_helpers", "string_ends_with")
fn string_ends_with(string: String, suffix: String) -> Bool
