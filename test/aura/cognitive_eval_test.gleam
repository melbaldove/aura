import aura/cognitive_eval
import aura/db
import aura/event_ingest
import aura/memory
import aura/test_helpers
import aura/xdg
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

fn temp_paths(label: String) -> #(String, xdg.Paths) {
  let base = "/tmp/aura-" <> label <> "-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  #(base, xdg.resolve_with_home(base))
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

fn routine_fixture_json() -> String {
  "{"
  <> "\"id\":\"routine\","
  <> "\"subject\":\"Payment confirmed\","
  <> "\"tags\":{\"from\":\"receipts@example.com\",\"to\":\"melbournebaldove@gmail.com\"},"
  <> "\"data\":{\"body_text\":\"Your payment has been confirmed. No action is required.\"},"
  <> "\"expect\":{"
  <> "\"attention_any\":[\"record\"],"
  <> "\"work_any\":[\"none\"],"
  <> "\"authority_any\":[\"none\"],"
  <> "\"min_citations\":2"
  <> "}"
  <> "}"
}

fn fake_decision(
  event_id: String,
  attention: String,
  work: String,
  authority: String,
  gaps: List(String),
) -> json.Json {
  json.object([
    #("timestamp_ms", json.int(1000)),
    #("event_id", json.string(event_id)),
    #("concern_refs", json.array([], json.string)),
    #("summary", json.string("Fixture decision.")),
    #(
      "citations",
      json.array(["evidence:e4", "policy:attention.md"], json.string),
    ),
    #(
      "attention",
      json.object([
        #("action", json.string(attention)),
        #("rationale", json.string("Matches the fixture expectation.")),
        #("why_now", json.string("")),
        #("deferral_cost", json.string("")),
        #("why_not_digest", json.string("")),
      ]),
    ),
    #(
      "work",
      json.object([
        #("action", json.string(work)),
        #("target", json.string("")),
        #("proof_required", json.string("")),
      ]),
    ),
    #(
      "authority",
      json.object([
        #("required", json.string(authority)),
        #("reason", json.string("")),
      ]),
    ),
    #("gaps", json.array(gaps, json.string)),
    #("proposed_patches", json.array([], json.string)),
    #("raw_response", json.string("{}")),
  ])
}

pub fn parse_fixture_reads_predicates_test() {
  let fixture =
    cognitive_eval.parse_fixture(routine_fixture_json()) |> should.be_ok

  fixture.id |> should.equal("routine")
  fixture.source |> should.equal("gmail-eval")
  fixture.type_ |> should.equal("email.received")
  fixture.expect.attention_any |> should.equal(["record"])
  fixture.expect.min_citations |> should.equal(2)
}

pub fn fixture_event_uses_unique_eval_id_without_marking_body_test() {
  let fixture =
    cognitive_eval.parse_fixture(routine_fixture_json()) |> should.be_ok
  let e = cognitive_eval.fixture_event(fixture, "run 1", 1234)

  e.id |> should.equal("eval-routine-run-1")
  e.source |> should.equal("gmail-eval")
  e.subject |> should.equal("Payment confirmed")
  e.data |> string.contains("Your payment has been confirmed") |> should.be_true
  e.data |> string.contains("cognitive smoke test") |> should.be_false
}

pub fn run_fixtures_injects_events_and_checks_expected_decision_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(ingest_started) = event_ingest.start(db_subject)
  let #(base, paths) = temp_paths("cognitive-eval")
  let fixture_dir = base <> "/fixtures"
  let _ = simplifile.create_directory_all(fixture_dir)
  let _ =
    simplifile.write(fixture_dir <> "/001-routine.json", routine_fixture_json())
  let run_id = "unit"
  let event_id = cognitive_eval.eval_event_id("routine", run_id)
  let ctx =
    cognitive_eval.Context(
      paths: paths,
      db_subject: db_subject,
      event_ingest_subject: ingest_started.data,
    )

  let _ =
    process.spawn(fn() {
      process.sleep(50)
      let _ = simplifile.create_directory_all(xdg.cognitive_dir(paths))
      let _ =
        memory.append_jsonl(
          xdg.decisions_path(paths),
          fake_decision(event_id, "record", "none", "none", []),
        )
      Nil
    })

  let report =
    cognitive_eval.run_fixtures_with(ctx, fixture_dir, run_id, 1000, 2000, 25)
    |> should.be_ok

  report |> string.contains("OK: cognitive-eval fixtures") |> should.be_true
  report |> string.contains("PASS routine") |> should.be_true

  let assert Ok(option.Some(persisted)) = db.get_event(db_subject, event_id)
  persisted.source |> should.equal("gmail-eval")
  persisted.subject |> should.equal("Payment confirmed")

  stop_subject(ingest_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn run_fixtures_reports_predicate_failures_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(ingest_started) = event_ingest.start(db_subject)
  let #(base, paths) = temp_paths("cognitive-eval-fail")
  let fixture_dir = base <> "/fixtures"
  let _ = simplifile.create_directory_all(fixture_dir)
  let _ =
    simplifile.write(fixture_dir <> "/001-routine.json", routine_fixture_json())
  let run_id = "bad"
  let event_id = cognitive_eval.eval_event_id("routine", run_id)
  let ctx =
    cognitive_eval.Context(
      paths: paths,
      db_subject: db_subject,
      event_ingest_subject: ingest_started.data,
    )

  let _ =
    process.spawn(fn() {
      process.sleep(50)
      let _ = simplifile.create_directory_all(xdg.cognitive_dir(paths))
      let _ =
        memory.append_jsonl(
          xdg.decisions_path(paths),
          fake_decision(event_id, "ask_now", "none", "none", []),
        )
      Nil
    })

  let report =
    cognitive_eval.run_fixtures_with(ctx, fixture_dir, run_id, 1000, 2000, 25)
    |> should.be_error

  report |> string.contains("cognitive-eval fixtures failed") |> should.be_true
  report |> string.contains("FAIL routine") |> should.be_true
  report |> string.contains("attention.action=ask_now") |> should.be_true

  stop_subject(ingest_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn run_fixtures_finds_spaced_decision_json_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(ingest_started) = event_ingest.start(db_subject)
  let #(base, paths) = temp_paths("cognitive-eval-spaced")
  let fixture_dir = base <> "/fixtures"
  let _ = simplifile.create_directory_all(fixture_dir)
  let _ =
    simplifile.write(fixture_dir <> "/001-routine.json", routine_fixture_json())
  let run_id = "spaced"
  let event_id = cognitive_eval.eval_event_id("routine", run_id)
  let ctx =
    cognitive_eval.Context(
      paths: paths,
      db_subject: db_subject,
      event_ingest_subject: ingest_started.data,
    )

  let _ =
    process.spawn(fn() {
      process.sleep(50)
      let _ = simplifile.create_directory_all(xdg.cognitive_dir(paths))
      let line =
        fake_decision(event_id, "record", "none", "none", [])
        |> json.to_string
        |> string.replace("\"event_id\":", "\"event_id\" : ")
      let _ = simplifile.write(xdg.decisions_path(paths), line <> "\n")
      Nil
    })

  let report =
    cognitive_eval.run_fixtures_with(ctx, fixture_dir, run_id, 1000, 2000, 25)
    |> should.be_ok

  report |> string.contains("PASS routine") |> should.be_true

  stop_subject(ingest_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}
