import aura/cognitive_replay
import aura/cognitive_worker
import aura/db
import aura/event
import aura/llm
import aura/memory
import aura/test_helpers
import aura/xdg
import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option}
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

fn fake_config() -> llm.LlmConfig {
  llm.LlmConfig(
    base_url: "http://example.invalid",
    api_key: "test",
    model: "test",
    codex_reasoning_effort: "medium",
  )
}

fn sample_event(id: String) -> event.AuraEvent {
  event.AuraEvent(
    id: id,
    source: "gmail",
    type_: "email.received",
    subject: "Approval needed within 90 minutes",
    time_ms: 1000,
    tags: dict.from_list([#("from", "ops@example.com")]),
    external_id: "msg-" <> id,
    data: "{\"from\":\"ops@example.com\",\"body_text\":\"Please approve or reject the rollback within 90 minutes.\"}",
  )
}

fn ask_now_decision(event_id: String) -> String {
  "{"
  <> "\"event_id\":\""
  <> event_id
  <> "\","
  <> "\"concern_refs\":[],"
  <> "\"summary\":\"Rollback approval is needed within 90 minutes.\","
  <> "\"citations\":[\"evidence:e1\",\"policy:attention.md\"],"
  <> "\"attention\":{\"action\":\"ask_now\",\"rationale\":\"The user must approve or reject under deadline.\",\"why_now\":\"The window is active.\",\"deferral_cost\":\"Payment state may remain wrong.\",\"why_not_digest\":\"Digest would be too late.\"},"
  <> "\"work\":{\"action\":\"prepare\",\"target\":\"rollback context\",\"proof_required\":\"context summarized\"},"
  <> "\"authority\":{\"required\":\"human_judgment\",\"reason\":\"Only the user can approve rollback risk.\"},"
  <> "\"delivery\":{\"target\":\"default\",\"rationale\":\"Default channel is configured for cross-cutting decisions.\"},"
  <> "\"gaps\":[\"No rollback preference concern exists.\"],"
  <> "\"proposed_patches\":[]"
  <> "}"
}

fn fake_ask_now_chat(
  _config: llm.LlmConfig,
  _messages: List(llm.Message),
  _temperature: Option(Float),
) -> Result(String, String) {
  Ok(ask_now_decision("ev-replay"))
}

fn label_json(event_id: String, attention_any: List(String)) -> json.Json {
  json.object([
    #("event_id", json.string(event_id)),
    #("label", json.string("missed_important")),
    #("note", json.string("rollback approval should ask now")),
    #("attention_any", json.array(attention_any, json.string)),
    #("work_any", json.array(["prepare"], json.string)),
    #("authority_any", json.array(["human_judgment"], json.string)),
    #("min_citations", json.int(2)),
    #("min_gaps", json.int(1)),
    #("require_gap_contains", json.string("rollback")),
  ])
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

pub fn parse_label_line_extracts_expectations_test() {
  let label =
    label_json("ev-replay", ["ask_now"])
    |> json.to_string
    |> cognitive_replay.parse_label_line
    |> should.be_ok

  label.event_id |> should.equal("ev-replay")
  label.label |> should.equal("missed_important")
  label.attention_any |> should.equal(["ask_now"])
  label.min_citations |> should.equal(2)
  label.require_gap_contains |> should.equal("rollback")
}

pub fn run_labels_with_missing_file_reports_empty_success_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-replay-empty")
  let assert Ok(worker_started) =
    cognitive_worker.start_with(
      db_subject,
      paths,
      fake_config(),
      fake_ask_now_chat,
      option.None,
    )

  let report =
    cognitive_replay.run_labels_with(
      cognitive_replay.Context(
        paths: paths,
        db_subject: db_subject,
        cognitive_subject: worker_started.data,
        delivery_subject: option.None,
      ),
      1000,
      25,
    )
    |> should.be_ok

  report
  |> should.equal(
    "OK: cognitive-replay labels passed=0 failed=0 skipped=0 total=0",
  )

  stop_subject(worker_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn run_labels_replays_event_and_passes_matching_label_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-replay-pass")
  let assert Ok(True) = db.insert_event(db_subject, sample_event("ev-replay"))
  let assert Ok(worker_started) =
    cognitive_worker.start_with(
      db_subject,
      paths,
      fake_config(),
      fake_ask_now_chat,
      option.None,
    )
  let _ = simplifile.create_directory_all(xdg.cognitive_dir(paths))
  let _ =
    memory.append_jsonl(
      xdg.labels_path(paths),
      label_json("ev-replay", [
        "ask_now",
      ]),
    )

  let report =
    cognitive_replay.run_labels_with(
      cognitive_replay.Context(
        paths: paths,
        db_subject: db_subject,
        cognitive_subject: worker_started.data,
        delivery_subject: option.None,
      ),
      2000,
      25,
    )
    |> should.be_ok

  report |> string.contains("OK: cognitive-replay labels") |> should.be_true
  report
  |> string.contains("PASS ev-replay attention=ask_now")
  |> should.be_true
  report
  |> string.contains("label=missed_important")
  |> should.be_true
  report
  |> string.contains("issue=policy:attention.md missed urgency")
  |> should.be_true

  stop_subject(worker_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn run_labels_fails_when_replay_differs_from_label_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-replay-fail")
  let assert Ok(True) = db.insert_event(db_subject, sample_event("ev-replay"))
  let assert Ok(worker_started) =
    cognitive_worker.start_with(
      db_subject,
      paths,
      fake_config(),
      fake_ask_now_chat,
      option.None,
    )
  let _ = simplifile.create_directory_all(xdg.cognitive_dir(paths))
  let _ =
    memory.append_jsonl(
      xdg.labels_path(paths),
      label_json("ev-replay", [
        "digest",
      ]),
    )

  let assert Error(report) =
    cognitive_replay.run_labels_with(
      cognitive_replay.Context(
        paths: paths,
        db_subject: db_subject,
        cognitive_subject: worker_started.data,
        delivery_subject: option.None,
      ),
      2000,
      25,
    )

  report |> string.contains("cognitive-replay labels failed") |> should.be_true
  report
  |> string.contains("attention.action=ask_now not in [digest]")
  |> should.be_true

  stop_subject(worker_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}
