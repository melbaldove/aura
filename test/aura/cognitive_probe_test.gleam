import aura/cognitive_probe
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

fn fake_decision(event_id: String) -> json.Json {
  json.object([
    #("timestamp_ms", json.int(1000)),
    #("event_id", json.string(event_id)),
    #("concern_refs", json.array([], json.string)),
    #(
      "summary",
      json.string("Production rollback approval is needed within 90 minutes."),
    ),
    #(
      "citations",
      json.array(["evidence:e4", "policy:attention.md"], json.string),
    ),
    #(
      "attention",
      json.object([
        #("action", json.string("ask_now")),
        #(
          "rationale",
          json.string("A human decision is required within the active deadline."),
        ),
        #("why_now", json.string("The rollback window closes today.")),
        #("deferral_cost", json.string("Waiting carries production risk.")),
        #("why_not_digest", json.string("Digest would be too late.")),
      ]),
    ),
    #(
      "work",
      json.object([
        #("action", json.string("prepare")),
        #("target", json.string("rollback context")),
        #("proof_required", json.string("context summarized")),
      ]),
    ),
    #(
      "authority",
      json.object([
        #("required", json.string("human_judgment")),
        #("reason", json.string("Only the user can approve rollback risk.")),
      ]),
    ),
    #(
      "delivery",
      json.object([
        #("target", json.string("default")),
        #("rationale", json.string("Default channel is appropriate.")),
      ]),
    ),
    #("gaps", json.array(["Need user approval."], json.string)),
    #("proposed_patches", json.array([], json.string)),
    #("raw_response", json.string("{}")),
  ])
}

fn delivered_state(event_id: String) -> json.Json {
  json.object([
    #("timestamp_ms", json.int(1100)),
    #("event_id", json.string(event_id)),
    #("status", json.string("delivered")),
    #("attention_action", json.string("ask_now")),
    #("target", json.string("default")),
    #("channel_id", json.string("aura-channel")),
    #("summary", json.string("Production rollback approval is needed.")),
    #("rationale", json.string("A human decision is required.")),
    #("authority_required", json.string("human_judgment")),
    #("citations", json.array(["evidence:e4"], json.string)),
    #("gaps", json.array(["Need user approval."], json.string)),
    #("error", json.string("")),
  ])
}

pub fn deliver_now_event_is_realistic_gmail_shape_test() {
  let e = cognitive_probe.deliver_now_event("test run", 1234)

  e.id |> should.equal("mail-mtest-run")
  e.source |> should.equal("gmail-melbournebaldove")
  e.type_ |> should.equal("email.received")
  e.subject
  |> should.equal("Approval needed within 90 minutes: production rollback")
  e.data |> string.contains("next 90 minutes") |> should.be_true
  e.data |> string.contains("human decision") |> should.be_true
}

pub fn parse_decision_line_extracts_delivery_target_test() {
  let event_id = cognitive_probe.deliver_now_event_id("parse")
  let line = fake_decision(event_id) |> json.to_string

  let decision = cognitive_probe.parse_decision_line(line) |> should.be_ok

  decision.event_id |> should.equal(event_id)
  decision.attention_action |> should.equal("ask_now")
  decision.delivery_target |> should.equal("default")
  decision.citation_count |> should.equal(2)
}

pub fn parse_delivery_line_extracts_terminal_status_test() {
  let event_id = cognitive_probe.deliver_now_event_id("delivery")
  let line = delivered_state(event_id) |> json.to_string

  let delivery = cognitive_probe.parse_delivery_line(line) |> should.be_ok

  delivery.event_id |> should.equal(event_id)
  delivery.status |> should.equal("delivered")
  delivery.target |> should.equal("default")
  delivery.channel_id |> should.equal("aura-channel")
}

pub fn run_deliver_now_injects_event_and_waits_for_delivery_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(ingest_started) = event_ingest.start(db_subject)
  let #(base, paths) = temp_paths("cognitive-probe")
  let run_id = "unit"
  let event_id = cognitive_probe.deliver_now_event_id(run_id)
  let ctx =
    cognitive_probe.Context(
      paths: paths,
      db_subject: db_subject,
      event_ingest_subject: ingest_started.data,
    )

  let _ =
    process.spawn(fn() {
      process.sleep(50)
      let _ = simplifile.create_directory_all(xdg.cognitive_dir(paths))
      let _ =
        memory.append_jsonl(xdg.decisions_path(paths), fake_decision(event_id))
      let _ =
        memory.append_jsonl(xdg.deliveries_path(paths), delivered_state(event_id))
      Nil
    })

  let report =
    cognitive_probe.run_deliver_now_with(ctx, run_id, 1000, 2000, 25)
    |> should.be_ok

  report |> string.contains("OK: cognitive-test deliver-now") |> should.be_true
  report |> string.contains("event_id=" <> event_id) |> should.be_true
  report |> string.contains("attention=ask_now") |> should.be_true
  report |> string.contains("delivery=delivered") |> should.be_true
  report |> string.contains("target=default") |> should.be_true

  let assert Ok(option.Some(persisted)) = db.get_event(db_subject, event_id)
  persisted.source |> should.equal("gmail-melbournebaldove")
  persisted.subject
  |> should.equal("Approval needed within 90 minutes: production rollback")

  stop_subject(ingest_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}
