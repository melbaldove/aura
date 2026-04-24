import aura/cognitive_worker
import aura/db
import aura/event
import aura/event_ingest
import gleam/dict
import gleam/erlang/process
import gleam/option.{Some}
import gleeunit
import gleeunit/should

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

fn stop_subject(subject) -> Nil {
  case process.subject_owner(subject) {
    Ok(pid) -> {
      process.unlink(pid)
      process.kill(pid)
    }
    Error(_) -> Nil
  }
}

pub fn worker_logs_context_ready_report_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let reports = process.new_subject()
  let assert Ok(started) =
    cognitive_worker.start_with(db_subject, Some(reports))

  let assert Ok(True) =
    db.insert_event(db_subject, sample_event("ev-1", "msg-1"))
  cognitive_worker.build_context(started.data, "ev-1")

  let assert Ok(report) = process.receive(reports, 2000)
  report.event_id |> should.equal("ev-1")
  report.status |> should.equal(cognitive_worker.ContextReady)
  { report.evidence_count > 0 } |> should.be_true
  { report.resource_ref_count > 0 } |> should.be_true
  report.raw_ref_count |> should.equal(1)
  report.errors |> should.equal([])

  stop_subject(started.data)
  process.send(db_subject, db.Shutdown)
}

pub fn worker_reports_missing_event_without_crashing_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let reports = process.new_subject()
  let assert Ok(started) =
    cognitive_worker.start_with(db_subject, Some(reports))

  cognitive_worker.build_context(started.data, "missing")

  let assert Ok(report) = process.receive(reports, 2000)
  report.status |> should.equal(cognitive_worker.MissingEvent)
  report.errors |> should.equal(["event not found"])

  stop_subject(started.data)
  process.send(db_subject, db.Shutdown)
}

pub fn event_ingest_notifies_worker_only_for_new_events_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let reports = process.new_subject()
  let assert Ok(worker_started) =
    cognitive_worker.start_with(db_subject, Some(reports))
  let assert Ok(ingest_started) =
    event_ingest.start_with_cognitive(db_subject, Some(worker_started.data))

  let e = sample_event("ev-1", "msg-1")
  event_ingest.ingest(ingest_started.data, e)
  event_ingest.ingest(ingest_started.data, e)

  let assert Ok(report) = process.receive(reports, 2000)
  report.status |> should.equal(cognitive_worker.ContextReady)
  process.sleep(100)
  case process.receive(reports, 100) {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }

  stop_subject(ingest_started.data)
  stop_subject(worker_started.data)
  process.send(db_subject, db.Shutdown)
}
