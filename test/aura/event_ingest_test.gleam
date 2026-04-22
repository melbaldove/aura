import aura/db
import aura/event
import aura/event_ingest
import aura/time
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import poll

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

type System {
  System(
    db_subject: process.Subject(db.DbMessage),
    ingest_subject: process.Subject(event_ingest.IngestMessage),
  )
}

fn fresh_system() -> System {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(started) = event_ingest.start(db_subject)
  System(db_subject: db_subject, ingest_subject: started.data)
}

fn teardown(sys: System) -> Nil {
  case process.subject_owner(sys.ingest_subject) {
    Ok(pid) -> {
      process.unlink(pid)
      process.kill(pid)
    }
    Error(_) -> Nil
  }
  process.send(sys.db_subject, db.Shutdown)
  Nil
}

fn sample_event(
  id: String,
  source: String,
  type_: String,
  subject: String,
  external_id: String,
  time_ms: Int,
  data: String,
) -> event.AuraEvent {
  event.AuraEvent(
    id: id,
    source: source,
    type_: type_,
    subject: subject,
    time_ms: time_ms,
    tags: dict.new(),
    external_id: external_id,
    data: data,
  )
}

/// Poll until the db has at least `min_count` events matching `external_id`
/// under `source`. Returns the matching list.
fn wait_for_events(
  sys: System,
  source: String,
  min_count: Int,
) -> List(event.AuraEvent) {
  let _ =
    poll.poll_until(
      fn() {
        case db.search_events(sys.db_subject, "", None, option.Some(source), 50)
        {
          Ok(events) -> list.length(events) >= min_count
          Error(_) -> False
        }
      },
      2000,
    )
  let assert Ok(events) =
    db.search_events(sys.db_subject, "", None, option.Some(source), 50)
  events
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn ingest_persists_event_test() {
  let sys = fresh_system()

  let e =
    sample_event(
      "e1",
      "gmail",
      "email.received",
      "hello",
      "msg-1",
      1000,
      "{\"from\":\"alice@example.com\"}",
    )

  event_ingest.ingest(sys.ingest_subject, e)

  let events = wait_for_events(sys, "gmail", 1)
  list.length(events) |> should.equal(1)
  let assert [stored] = events
  stored.id |> should.equal("e1")
  stored.subject |> should.equal("hello")

  teardown(sys)
}

pub fn ingest_deduplicates_test() {
  let sys = fresh_system()

  let e =
    sample_event(
      "e1",
      "gmail",
      "email.received",
      "hello",
      "msg-1",
      1000,
      "{}",
    )

  event_ingest.ingest(sys.ingest_subject, e)
  event_ingest.ingest(sys.ingest_subject, e)

  // Wait briefly — neither send takes long, and the dedup check runs in
  // the db actor. We need to ensure both sends were processed before we
  // assert on the count.
  let _ = wait_for_events(sys, "gmail", 1)
  process.sleep(50)

  let assert Ok(events) =
    db.search_events(sys.db_subject, "", None, option.Some("gmail"), 50)
  list.length(events) |> should.equal(1)

  teardown(sys)
}

pub fn ingest_attaches_tagger_tags_test() {
  let sys = fresh_system()

  let payload =
    "{\"from\":\"alice@example.com\",\"thread_id\":\"t-42\",\"subject\":\"hi\"}"
  let e =
    sample_event(
      "e1",
      "gmail",
      "email.received",
      "hello",
      "msg-1",
      1000,
      payload,
    )

  event_ingest.ingest(sys.ingest_subject, e)

  let events = wait_for_events(sys, "gmail", 1)
  let assert [stored] = events
  dict.get(stored.tags, "from") |> should.equal(Ok("alice@example.com"))
  dict.get(stored.tags, "thread_id") |> should.equal(Ok("t-42"))

  teardown(sys)
}

pub fn ingest_incoming_tags_override_tagger_test() {
  let sys = fresh_system()

  let payload = "{\"from\":\"auto@example.com\",\"thread_id\":\"t-42\"}"
  let base =
    sample_event(
      "e1",
      "gmail",
      "email.received",
      "hello",
      "msg-1",
      1000,
      payload,
    )
  let e =
    event.AuraEvent(
      ..base,
      tags: dict.from_list([#("from", "override@x.com")]),
    )

  event_ingest.ingest(sys.ingest_subject, e)

  let events = wait_for_events(sys, "gmail", 1)
  let assert [stored] = events
  // Caller-supplied `from` wins over tagger-extracted `from`.
  dict.get(stored.tags, "from") |> should.equal(Ok("override@x.com"))
  // The tagger-supplied thread_id should still be attached.
  dict.get(stored.tags, "thread_id") |> should.equal(Ok("t-42"))

  teardown(sys)
}

pub fn ingest_fills_missing_time_ms_test() {
  let sys = fresh_system()

  let before = time.now_ms()

  let e =
    sample_event("e1", "gmail", "email.received", "hello", "msg-1", 0, "{}")

  event_ingest.ingest(sys.ingest_subject, e)

  let events = wait_for_events(sys, "gmail", 1)
  let assert [stored] = events
  // The stored event should have a time_ms that's at least `before`.
  // Exact equality isn't guaranteed because of scheduling latency.
  { stored.time_ms >= before } |> should.be_true
  // And it should definitely not still be 0.
  { stored.time_ms > 0 } |> should.be_true

  teardown(sys)
}

pub fn ingest_fills_missing_id_test() {
  let sys = fresh_system()

  let e = sample_event("", "gmail", "email.received", "hello", "msg-1", 1000, "{}")

  event_ingest.ingest(sys.ingest_subject, e)

  let events = wait_for_events(sys, "gmail", 1)
  let assert [stored] = events
  { stored.id != "" } |> should.be_true

  teardown(sys)
}
