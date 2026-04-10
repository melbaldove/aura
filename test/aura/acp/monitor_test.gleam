import aura/acp/monitor as acp_monitor
import gleam/erlang/process
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

pub fn monitor_accumulates_tool_calls_test() {
  let event_subject = process.new_subject()
  let on_event = fn(event) { process.send(event_subject, event) }

  let monitor =
    acp_monitor.start_push_monitor(
      acp_monitor.MonitorConfig(
        emit_interval_ms: 100,
        idle_interval_ms: 500,
        idle_surface_threshold: 3,
        timeout_ms: 60_000,
      ),
      "test-session",
      "test-domain",
      on_event,
    )

  process.send(monitor, acp_monitor.RawEvent("tool_call", "Read src/main.ts"))
  process.send(
    monitor,
    acp_monitor.RawEvent("tool_call", "Search isExcluded"),
  )
  process.send(
    monitor,
    acp_monitor.RawEvent("agent_message_chunk", "Analyzing..."),
  )

  case process.receive(event_subject, 500) {
    Ok(acp_monitor.AcpProgress(_, _, _, _, summary, False)) -> {
      summary
      |> string_contains("\u{1F527} Read src/main.ts")
      |> should.be_true
      summary
      |> string_contains("\u{1F527} Search isExcluded")
      |> should.be_true
      summary
      |> string_contains("\u{1F4AC} Analyzing...")
      |> should.be_true
    }
    Ok(_other) -> should.fail()
    Error(_) -> should.fail()
  }
}

pub fn monitor_idle_detection_test() {
  let event_subject = process.new_subject()
  let on_event = fn(event) { process.send(event_subject, event) }

  let _monitor =
    acp_monitor.start_push_monitor(
      acp_monitor.MonitorConfig(
        emit_interval_ms: 50,
        idle_interval_ms: 50,
        idle_surface_threshold: 2,
        timeout_ms: 60_000,
      ),
      "test-idle",
      "test-domain",
      on_event,
    )

  // Send no events, wait for idle detection (2 ticks at 50ms + threshold 2)
  process.sleep(250)
  let is_idle = drain_for_idle(event_subject)
  is_idle |> should.be_true
}

pub fn monitor_resets_after_emit_test() {
  let event_subject = process.new_subject()
  let on_event = fn(event) { process.send(event_subject, event) }

  let monitor =
    acp_monitor.start_push_monitor(
      acp_monitor.MonitorConfig(
        emit_interval_ms: 100,
        idle_interval_ms: 500,
        idle_surface_threshold: 3,
        timeout_ms: 60_000,
      ),
      "test-reset",
      "test-domain",
      on_event,
    )

  process.send(monitor, acp_monitor.RawEvent("tool_call", "First tool"))
  case process.receive(event_subject, 500) {
    Ok(acp_monitor.AcpProgress(_, _, _, _, summary1, _)) -> {
      summary1 |> string_contains("First tool") |> should.be_true
      process.send(monitor, acp_monitor.RawEvent("tool_call", "Second tool"))
      case process.receive(event_subject, 500) {
        Ok(acp_monitor.AcpProgress(_, _, _, _, summary2, _)) -> {
          summary2 |> string_contains("Second tool") |> should.be_true
          summary2 |> string_contains("First tool") |> should.be_false
        }
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

fn drain_for_idle(
  subject: process.Subject(acp_monitor.AcpEvent),
) -> Bool {
  case process.receive(subject, 300) {
    Ok(acp_monitor.AcpProgress(_, _, _, _, _, True)) -> True
    Ok(_) -> drain_for_idle(subject)
    Error(_) -> False
  }
}
