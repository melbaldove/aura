import aura/acp/monitor as acp_monitor
import gleam/erlang/process
import gleeunit/should

pub fn monitor_emits_on_tick_test() {
  let event_subject = process.new_subject()
  let on_event = fn(event) { process.send(event_subject, event) }

  let monitor = acp_monitor.start_push_monitor(
    acp_monitor.MonitorConfig(
      emit_interval_ms: 200,
      idle_interval_ms: 500,
      idle_surface_threshold: 3,
      timeout_ms: 60_000,
    ),
    "test-session",
    "test-domain",
    "Analyze the code",
    "",
    on_event,
  )

  // Send raw lines
  process.send(monitor, acp_monitor.RawLine("{\"update\":{\"toolName\":\"Read\"}}"))
  process.send(monitor, acp_monitor.RawLine("{\"update\":{\"toolName\":\"Grep\"}}"))

  // Wait for tick (200ms + buffer)
  case process.receive(event_subject, 1000) {
    Ok(acp_monitor.AcpProgress(_, _, _, _, summary, False)) -> {
      // With no LLM config, should get fallback summary
      { summary != "" } |> should.be_true
    }
    _ -> should.fail()
  }
}

pub fn monitor_idle_detection_test() {
  let event_subject = process.new_subject()
  let on_event = fn(event) { process.send(event_subject, event) }

  let _monitor = acp_monitor.start_push_monitor(
    acp_monitor.MonitorConfig(
      emit_interval_ms: 50,
      idle_interval_ms: 50,
      idle_surface_threshold: 2,
      timeout_ms: 60_000,
    ),
    "test-idle",
    "test-domain",
    "Analyze the code",
    "",
    on_event,
  )

  // Send no events, wait for idle detection
  process.sleep(250)
  let is_idle = drain_for_idle(event_subject)
  is_idle |> should.be_true
}

pub fn monitor_resets_after_emit_test() {
  let event_subject = process.new_subject()
  let on_event = fn(event) { process.send(event_subject, event) }

  let monitor = acp_monitor.start_push_monitor(
    acp_monitor.MonitorConfig(
      emit_interval_ms: 200,
      idle_interval_ms: 500,
      idle_surface_threshold: 3,
      timeout_ms: 60_000,
    ),
    "test-reset",
    "test-domain",
    "Analyze the code",
    "",
    on_event,
  )

  // Send line, wait for first emit
  process.send(monitor, acp_monitor.RawLine("{\"first\":true}"))
  case process.receive(event_subject, 1000) {
    Ok(acp_monitor.AcpProgress(_, _, _, _, _, False)) -> {
      // Send different line, wait for second emit
      process.send(monitor, acp_monitor.RawLine("{\"second\":true}"))
      case process.receive(event_subject, 1000) {
        Ok(acp_monitor.AcpProgress(_, _, _, _, _, False)) -> {
          // If we got two separate emits, the buffer reset between them
          should.be_true(True)
        }
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

pub fn monitor_get_last_summary_test() {
  let event_subject = process.new_subject()
  let on_event = fn(event) { process.send(event_subject, event) }

  let monitor = acp_monitor.start_push_monitor(
    acp_monitor.MonitorConfig(
      emit_interval_ms: 100,
      idle_interval_ms: 500,
      idle_surface_threshold: 3,
      timeout_ms: 60_000,
    ),
    "test-summary",
    "test-domain",
    "Analyze the code",
    "",
    on_event,
  )

  // Send some data and wait for a tick to generate a summary
  process.send(monitor, acp_monitor.RawLine("{\"update\":true}"))
  process.sleep(300)
  // Drain the progress event
  let _ = process.receive(event_subject, 500)

  // Now ask for the summary
  let summary = process.call(monitor, 1000, fn(reply_to) {
    acp_monitor.GetLastSummary(reply_to)
  })
  { summary != "" } |> should.be_true
}

pub fn monitor_get_last_summary_empty_test() {
  let event_subject = process.new_subject()
  let on_event = fn(_event) { process.send(event_subject, Nil) }

  let monitor = acp_monitor.start_push_monitor(
    acp_monitor.MonitorConfig(
      emit_interval_ms: 5000,
      idle_interval_ms: 5000,
      idle_surface_threshold: 3,
      timeout_ms: 60_000,
    ),
    "test-summary-empty",
    "test-domain",
    "Analyze the code",
    "",
    fn(_) { Nil },
  )

  // No data sent, no tick fired — summary should be empty
  let summary = process.call(monitor, 1000, fn(reply_to) {
    acp_monitor.GetLastSummary(reply_to)
  })
  summary |> should.equal("")
}

fn drain_for_idle(subject: process.Subject(acp_monitor.AcpEvent)) -> Bool {
  case process.receive(subject, 500) {
    Ok(acp_monitor.AcpProgress(_, _, _, _, _, True)) -> True
    Ok(_) -> drain_for_idle(subject)
    Error(_) -> False
  }
}
