import aura/acp/monitor as acp_monitor
import gleam/string
import gleeunit/should

@external(erlang, "aura_acp_stdio_ffi_test_helpers", "string_contains")
fn string_contains(haystack: String, needle: String) -> Bool

pub fn empty_snapshot_is_idle_test() {
  let snap = acp_monitor.ActivitySnapshot(
    tool_calls: [],
    message_chunks: "",
    event_count: 0,
    last_event_type: "",
  )
  acp_monitor.snapshot_is_active(snap)
  |> should.be_false
}

pub fn snapshot_with_tool_calls_is_active_test() {
  let snap = acp_monitor.ActivitySnapshot(
    tool_calls: ["Read src/main.ts"],
    message_chunks: "",
    event_count: 1,
    last_event_type: "tool_call",
  )
  acp_monitor.snapshot_is_active(snap)
  |> should.be_true
}

pub fn snapshot_with_message_chunks_is_active_test() {
  let snap = acp_monitor.ActivitySnapshot(
    tool_calls: [],
    message_chunks: "Analyzing the code...",
    event_count: 3,
    last_event_type: "agent_message_chunk",
  )
  acp_monitor.snapshot_is_active(snap)
  |> should.be_true
}

pub fn format_snapshot_with_tools_test() {
  let snap = acp_monitor.ActivitySnapshot(
    tool_calls: ["Read src/lib/exclusion.ts", "Search isExcluded"],
    message_chunks: "Analyzing scope resolution...",
    event_count: 5,
    last_event_type: "agent_message_chunk",
  )
  let result = acp_monitor.format_snapshot(snap)
  result |> string_contains("\u{1F527} Read src/lib/exclusion.ts") |> should.be_true
  result |> string_contains("\u{1F527} Search isExcluded") |> should.be_true
  result |> string_contains("\u{1F4AC} Analyzing scope resolution...") |> should.be_true
}

pub fn format_snapshot_empty_test() {
  let snap = acp_monitor.ActivitySnapshot(
    tool_calls: [],
    message_chunks: "",
    event_count: 0,
    last_event_type: "",
  )
  let result = acp_monitor.format_snapshot(snap)
  result |> should.equal("")
}

pub fn format_snapshot_truncates_long_message_test() {
  let long_text = string.repeat("a", 200)
  let snap = acp_monitor.ActivitySnapshot(
    tool_calls: [],
    message_chunks: long_text,
    event_count: 10,
    last_event_type: "agent_message_chunk",
  )
  let result = acp_monitor.format_snapshot(snap)
  { string.length(result) < 160 } |> should.be_true
}

pub fn format_snapshot_limits_tool_calls_test() {
  let snap = acp_monitor.ActivitySnapshot(
    tool_calls: ["Tool 1", "Tool 2", "Tool 3", "Tool 4", "Tool 5", "Tool 6", "Tool 7"],
    message_chunks: "",
    event_count: 7,
    last_event_type: "tool_call",
  )
  let result = acp_monitor.format_snapshot(snap)
  result |> string_contains("Tool 3") |> should.be_true
  result |> string_contains("Tool 7") |> should.be_true
  result |> string_contains("Tool 1") |> should.be_false
}
