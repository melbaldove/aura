import aura/acp/monitor as acp_monitor
import gleeunit/should

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
