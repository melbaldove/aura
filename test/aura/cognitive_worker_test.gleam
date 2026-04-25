import aura/cognitive_worker
import aura/db
import aura/event
import aura/event_ingest
import aura/llm
import aura/test_helpers
import aura/xdg
import gleam/dict
import gleam/erlang/process
import gleam/option.{type Option, Some}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

fn sample_event(id: String, external_id: String) -> event.AuraEvent {
  event.AuraEvent(
    id: id,
    source: "gmail",
    type_: "email.received",
    subject: "Please review REL-42 tomorrow",
    time_ms: 1000,
    tags: dict.from_list([#("from", "alice@example.com")]),
    external_id: external_id,
    data: "{\"from\":\"alice@example.com\",\"thread_id\":\"t-1\"}",
  )
}

fn temp_paths(label: String) -> #(String, xdg.Paths) {
  let base = "/tmp/aura-" <> label <> "-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  #(base, xdg.resolve_with_home(base))
}

fn fake_config() -> llm.LlmConfig {
  llm.LlmConfig(
    base_url: "http://example.invalid",
    api_key: "test",
    model: "test",
  )
}

fn valid_decision(event_id: String) -> String {
  "{"
  <> "\"event_id\":\""
  <> event_id
  <> "\","
  <> "\"concern_refs\":[],"
  <> "\"summary\":\"Record the email for later review.\","
  <> "\"citations\":[\"evidence:"
  <> event_id
  <> ":e1\",\"policy:attention.md\"],"
  <> "\"attention\":{\"action\":\"record\",\"why_now\":\"\",\"deferral_cost\":\"\",\"why_not_digest\":\"\"},"
  <> "\"work\":{\"action\":\"none\",\"target\":\"\",\"proof_required\":\"\"},"
  <> "\"authority\":{\"required\":\"none\",\"reason\":\"\"},"
  <> "\"gaps\":[],"
  <> "\"proposed_patches\":[]"
  <> "}"
}

fn fake_valid_chat(
  _config: llm.LlmConfig,
  messages: List(llm.Message),
  _temperature: Option(Float),
) -> Result(String, String) {
  let rendered = string.inspect(messages)
  case string.contains(rendered, "event_id: ev-1") {
    True -> Ok(valid_decision("ev-1"))
    False -> Ok(valid_decision("unknown"))
  }
}

fn fake_invalid_chat(
  _config: llm.LlmConfig,
  _messages: List(llm.Message),
  _temperature: Option(Float),
) -> Result(String, String) {
  Ok(
    "{"
    <> "\"event_id\":\"ev-1\","
    <> "\"concern_refs\":[],"
    <> "\"summary\":\"Bad envelope.\","
    <> "\"citations\":[],"
    <> "\"attention\":{\"action\":\"record\",\"why_now\":\"\",\"deferral_cost\":\"\",\"why_not_digest\":\"\"},"
    <> "\"work\":{\"action\":\"none\",\"target\":\"\",\"proof_required\":\"\"},"
    <> "\"authority\":{\"required\":\"none\",\"reason\":\"\"},"
    <> "\"gaps\":[],"
    <> "\"proposed_patches\":[]"
    <> "}",
  )
}

fn stop_subject(subject) -> Nil {
  case process.subject_owner(subject) {
    Ok(pid) -> {
      process.unlink(pid)
      process.kill(pid)
    }
    Error(_) -> Nil
  }
}

pub fn worker_logs_decision_ready_report_and_decision_jsonl_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-worker-ready")
  let reports = process.new_subject()
  let assert Ok(started) =
    cognitive_worker.start_with(
      db_subject,
      paths,
      fake_config(),
      fake_valid_chat,
      Some(reports),
    )

  let assert Ok(True) =
    db.insert_event(db_subject, sample_event("ev-1", "msg-1"))
  cognitive_worker.build_context(started.data, "ev-1")

  let assert Ok(report) = process.receive(reports, 2000)
  report.event_id |> should.equal("ev-1")
  report.status |> should.equal(cognitive_worker.DecisionReady)
  { report.evidence_count > 0 } |> should.be_true
  { report.resource_ref_count > 0 } |> should.be_true
  report.raw_ref_count |> should.equal(1)
  report.citation_count |> should.equal(2)
  report.attention_action |> should.equal("record")
  report.work_action |> should.equal("none")
  report.authority_required |> should.equal("none")
  report.errors |> should.equal([])

  let log = simplifile.read(xdg.decisions_path(paths)) |> should.be_ok
  log |> string.contains("\"event_id\":\"ev-1\"") |> should.be_true
  log
  |> string.contains("\"attention\":{\"action\":\"record\"")
  |> should.be_true

  stop_subject(started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn worker_reports_missing_event_without_calling_model_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-worker-missing")
  let reports = process.new_subject()
  let assert Ok(started) =
    cognitive_worker.start_with(
      db_subject,
      paths,
      fake_config(),
      fake_valid_chat,
      Some(reports),
    )

  cognitive_worker.build_context(started.data, "missing")

  let assert Ok(report) = process.receive(reports, 2000)
  report.status |> should.equal(cognitive_worker.MissingEvent)
  report.errors |> should.equal(["event not found"])

  stop_subject(started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn worker_reports_invalid_decision_without_log_write_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-worker-invalid")
  let reports = process.new_subject()
  let assert Ok(started) =
    cognitive_worker.start_with(
      db_subject,
      paths,
      fake_config(),
      fake_invalid_chat,
      Some(reports),
    )

  let assert Ok(True) =
    db.insert_event(db_subject, sample_event("ev-1", "msg-1"))
  cognitive_worker.build_context(started.data, "ev-1")

  let assert Ok(report) = process.receive(reports, 2000)
  report.status |> should.equal(cognitive_worker.InvalidDecision)
  report.errors |> should.not_equal([])
  simplifile.is_file(xdg.decisions_path(paths)) |> should.not_equal(Ok(True))

  stop_subject(started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn event_ingest_notifies_worker_only_for_new_events_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-worker-ingest")
  let reports = process.new_subject()
  let assert Ok(worker_started) =
    cognitive_worker.start_with(
      db_subject,
      paths,
      fake_config(),
      fake_valid_chat,
      Some(reports),
    )
  let assert Ok(ingest_started) =
    event_ingest.start_with_cognitive(db_subject, Some(worker_started.data))

  let e = sample_event("ev-1", "msg-1")
  event_ingest.ingest(ingest_started.data, e)
  event_ingest.ingest(ingest_started.data, e)

  let assert Ok(report) = process.receive(reports, 2000)
  report.status |> should.equal(cognitive_worker.DecisionReady)
  process.sleep(100)
  case process.receive(reports, 100) {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }

  stop_subject(ingest_started.data)
  stop_subject(worker_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}
