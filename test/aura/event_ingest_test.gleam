import aura/db
import aura/event
import aura/event_ingest
import aura/operating_contracts
import aura/test_helpers
import aura/time
import aura/xdg
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import poll
import simplifile

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
        case
          db.search_events(sys.db_subject, "", None, option.Some(source), 50)
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
    sample_event("e1", "gmail", "email.received", "hello", "msg-1", 1000, "{}")

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
    event.AuraEvent(..base, tags: dict.from_list([#("from", "override@x.com")]))

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

  let e =
    sample_event("", "gmail", "email.received", "hello", "msg-1", 1000, "{}")

  event_ingest.ingest(sys.ingest_subject, e)

  let events = wait_for_events(sys, "gmail", 1)
  let assert [stored] = events
  { stored.id != "" } |> should.be_true

  teardown(sys)
}

fn normalized_evidence(event_id: String, external_id: String) {
  operating_contracts.EvidenceEvent(
    schema_version: 1,
    event_id: event_id,
    source: "synthetic",
    source_kind: "connector",
    event_type: "record.changed",
    external_id: option.Some(external_id),
    resource: dict.from_list([
      #("kind", operating_contracts.StructuredString("record")),
      #("id", operating_contracts.StructuredString(external_id)),
    ]),
    observed_at: 1000,
    summary: "Record changed.",
    normalized_data: dict.from_list([
      #("status", operating_contracts.StructuredString("changed")),
    ]),
    raw_ref: option.Some("opaque://synthetic/" <> external_id),
    content_hash: "hash-" <> external_id,
    provenance: dict.from_list([
      #("adapter", operating_contracts.StructuredString("synthetic_fixture")),
      #("concern_link_confidence", operating_contracts.StructuredFloat(0.75)),
      #(
        "concern_link_provenance",
        operating_contracts.StructuredString("fixture.rule"),
      ),
      #("concern_link_confirmed", operating_contracts.StructuredBool(False)),
    ]),
    candidate_domain_refs: ["domain:inferred-only"],
    candidate_concern_refs: ["concern:domain:ops:watch"],
    verification_status: "verified",
  )
}

pub fn normalized_duplicate_returns_one_canonical_event_test() {
  let sys = fresh_system()
  let first =
    event_ingest.submit_evidence(
      sys.ingest_subject,
      normalized_evidence("canonical-event", "same-resource"),
    )
    |> should.be_ok
  let duplicate =
    event_ingest.submit_evidence(
      sys.ingest_subject,
      normalized_evidence("different-event", "same-resource"),
    )
    |> should.be_ok
  first.event_id |> should.equal("canonical-event")
  duplicate.event_id |> should.equal("canonical-event")
  duplicate.inserted |> should.be_false
  teardown(sys)
}

pub fn normalized_duplicate_with_changed_payload_is_rejected_test() {
  let sys = fresh_system()
  event_ingest.submit_evidence(
    sys.ingest_subject,
    normalized_evidence("canonical-event", "same-changed-resource"),
  )
  |> should.be_ok
  event_ingest.submit_evidence(
    sys.ingest_subject,
    operating_contracts.EvidenceEvent(
      ..normalized_evidence("different-event", "same-changed-resource"),
      content_hash: "changed-hash",
    ),
  )
  |> should.equal(Error("idempotency_conflict"))
  teardown(sys)
}

pub fn common_ingress_accepts_all_required_source_fixtures_test() {
  let sys = fresh_system()
  [
    #("gmail", "connector"),
    #("calendar", "connector"),
    #("slack", "connector"),
    #("jira", "connector"),
    #("confluence", "connector"),
    #("github", "connector"),
    #("scheduler", "schedule"),
    #("hook", "hook"),
    #("codex", "codex"),
    #("claude", "claude"),
    #("mcp", "mcp_tool"),
  ]
  |> list.each(fn(source_fixture) {
    let source = source_fixture.0
    let envelope =
      operating_contracts.EvidenceEvent(
        ..normalized_evidence("event-" <> source, "resource-" <> source),
        source: source,
        source_kind: source_fixture.1,
      )
    event_ingest.submit_evidence(sys.ingest_subject, envelope) |> should.be_ok
  })
  let events = wait_for_events(sys, "gmail", 1)
  list.length(events) |> should.equal(1)
  teardown(sys)
}

pub fn normalized_duplicate_backfills_legacy_canonical_event_test() {
  let sys = fresh_system()
  let legacy =
    sample_event(
      "legacy-event",
      "synthetic",
      "record.changed",
      "Legacy record",
      "legacy-resource",
      900,
      "{}",
    )
  db.insert_event(sys.db_subject, legacy) |> should.equal(Ok(True))

  let inserted =
    event_ingest.submit_evidence(
      sys.ingest_subject,
      normalized_evidence("new-event", "legacy-resource"),
    )
    |> should.be_ok
  inserted.inserted |> should.be_false
  inserted.event_id |> should.equal("legacy-event")
  let assert option.Some(stored) =
    db.get_stored_evidence(sys.db_subject, "legacy-event") |> should.be_ok
  stored.envelope.event_id |> should.equal("legacy-event")
  teardown(sys)
}

pub fn normalized_evidence_persists_explicit_concern_link_metadata_test() {
  let sys = fresh_system()
  let inserted =
    event_ingest.submit_evidence(
      sys.ingest_subject,
      normalized_evidence("linked-event", "linked-resource"),
    )
    |> should.be_ok
  let stored =
    db.get_stored_evidence(sys.db_subject, inserted.event_id) |> should.be_ok
  let assert option.Some(record) = stored
  record.raw_ref |> should.equal("opaque://synthetic/linked-resource")
  let links =
    db.list_evidence_concern_links(sys.db_subject, inserted.event_id)
    |> should.be_ok
  let assert [link] = links
  link.confidence |> should.equal(0.75)
  link.provenance |> should.equal("fixture.rule")
  link.confirmed |> should.be_false
  teardown(sys)
}

pub fn unconfirmed_inferred_domain_never_creates_domain_test() {
  let sys = fresh_system()
  let base = "/tmp/aura-evidence-domain-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(base)
  event_ingest.submit_evidence(
    sys.ingest_subject,
    normalized_evidence("domain-event", "domain-resource"),
  )
  |> should.be_ok
  simplifile.is_file(xdg.domain_manifest_path(paths, "inferred-only"))
  |> should.equal(Ok(False))
  let _ = simplifile.delete_all([base])
  teardown(sys)
}
