import aura/cognitive_smoke
import aura/db
import aura/event_ingest
import aura/memory
import aura/test_helpers
import aura/xdg
import gleam/dict
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

fn fake_decision(event_id: String) -> json.Json {
  json.object([
    #("timestamp_ms", json.int(1000)),
    #("event_id", json.string(event_id)),
    #("concern_refs", json.array([], json.string)),
    #(
      "summary",
      json.string(
        "Synthetic smoke event requesting REL-42 review tomorrow; record only.",
      ),
    ),
    #(
      "citations",
      json.array(["evidence:e4", "policy:attention.md"], json.string),
    ),
    #(
      "attention",
      json.object([
        #("action", json.string("record")),
        #(
          "rationale",
          json.string(
            "This is a synthetic smoke event, so it proves the path without interrupting the user.",
          ),
        ),
        #("why_now", json.string("")),
        #("deferral_cost", json.string("")),
        #("why_not_digest", json.string("")),
      ]),
    ),
    #(
      "work",
      json.object([
        #("action", json.string("none")),
        #("target", json.string("")),
        #("proof_required", json.string("")),
      ]),
    ),
    #(
      "authority",
      json.object([
        #("required", json.string("none")),
        #("reason", json.string("")),
      ]),
    ),
    #("gaps", json.array([], json.string)),
    #("proposed_patches", json.array([], json.string)),
    #("raw_response", json.string("{}")),
  ])
}

pub fn gmail_rel42_event_is_tagged_synthetic_and_gmail_shaped_test() {
  let e = cognitive_smoke.gmail_rel42_event("test run", 1234)

  e.id |> should.equal("smoke-gmail-rel42-test-run")
  e.source |> should.equal("gmail-smoke")
  e.type_ |> should.equal("email.received")
  dict.get(e.tags, "synthetic") |> should.equal(Ok("true"))
  dict.get(e.tags, "smoke_kind") |> should.equal(Ok("gmail-rel42"))
  e.data |> string.contains("REL-42 tomorrow") |> should.be_true
  e.data |> string.contains("must not notify") |> should.be_true
}

pub fn parse_decision_line_extracts_proof_fields_test() {
  let event_id = cognitive_smoke.gmail_rel42_event_id("parse")
  let line = fake_decision(event_id) |> json.to_string

  let decision = cognitive_smoke.parse_decision_line(line) |> should.be_ok

  decision.event_id |> should.equal(event_id)
  decision.citation_count |> should.equal(2)
  decision.attention_action |> should.equal("record")
  decision.attention_rationale
  |> string.contains("synthetic smoke event")
  |> should.be_true
  decision.work_action |> should.equal("none")
  decision.authority_required |> should.equal("none")
}

pub fn run_gmail_rel42_injects_event_and_waits_for_decision_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(ingest_started) = event_ingest.start(db_subject)
  let #(base, paths) = temp_paths("cognitive-smoke")
  let run_id = "unit"
  let event_id = cognitive_smoke.gmail_rel42_event_id(run_id)
  let ctx =
    cognitive_smoke.Context(
      paths: paths,
      db_subject: db_subject,
      event_ingest_subject: ingest_started.data,
      delivery_subject: option.None,
    )

  let _ =
    process.spawn(fn() {
      process.sleep(50)
      let _ = simplifile.create_directory_all(xdg.cognitive_dir(paths))
      let _ =
        memory.append_jsonl(xdg.decisions_path(paths), fake_decision(event_id))
      Nil
    })

  let report =
    cognitive_smoke.run_gmail_rel42_with(ctx, run_id, 1000, 2000, 25)
    |> should.be_ok

  report |> string.contains("OK: cognitive-smoke gmail-rel42") |> should.be_true
  report |> string.contains("event_id=" <> event_id) |> should.be_true
  report |> string.contains("body_len=") |> should.be_true
  report |> string.contains("evidence_count=") |> should.be_true
  report
  |> string.contains("rationale=This is a synthetic smoke event")
  |> should.be_true

  let assert Ok(option.Some(persisted)) = db.get_event(db_subject, event_id)
  persisted.source |> should.equal("gmail-smoke")
  persisted.subject |> should.equal("AURA cognitive smoke test: REL-42")
  persisted.data |> string.contains("REL-42 tomorrow") |> should.be_true

  stop_subject(ingest_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}
