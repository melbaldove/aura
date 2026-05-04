import aura/cognitive_improve
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
    #("label", json.string("false_interrupt")),
    #("note", json.string("This should have waited for digest.")),
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

pub fn propose_with_no_labels_returns_noop_report_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-improve-empty")
  let assert Ok(worker_started) =
    cognitive_worker.start_with(
      db_subject,
      paths,
      fake_config(),
      fake_ask_now_chat,
      option.None,
    )

  let result =
    cognitive_improve.propose_at(
      cognitive_replay.Context(
        paths: paths,
        db_subject: db_subject,
        cognitive_subject: worker_started.data,
        delivery_subject: option.None,
      ),
      1234,
      1000,
      25,
    )
    |> should.be_ok

  result.label_count |> should.equal(0)
  result.path |> should.equal("")
  result.markdown
  |> should.equal(
    "OK: no cognitive labels found; no improvement proposal generated.",
  )

  stop_subject(worker_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn propose_runs_replay_and_writes_evidence_report_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-improve-report")
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
      label_json("ev-replay", ["digest"]),
    )

  let result =
    cognitive_improve.propose_at(
      cognitive_replay.Context(
        paths: paths,
        db_subject: db_subject,
        cognitive_subject: worker_started.data,
        delivery_subject: option.None,
      ),
      1234,
      2000,
      25,
    )
    |> should.be_ok

  result.label_count |> should.equal(1)
  result.failed_count |> should.equal(1)
  result.proposal_count |> should.equal(1)
  result.path
  |> should.equal(xdg.cognitive_dir(paths) <> "/improvement-proposals/1234.md")
  result.markdown
  |> string.contains("# Cognitive Improvement Proposal")
  |> should.be_true
  result.markdown
  |> string.contains("Replay: passed=0 failed=1 skipped=0 total=1")
  |> should.be_true
  result.markdown
  |> string.contains("## `policies/attention.md`")
  |> should.be_true
  result.markdown
  |> string.contains("FAIL `ev-replay`")
  |> should.be_true
  result.markdown
  |> string.contains("Actual: attention=ask_now")
  |> should.be_true
  result.markdown
  |> string.contains("Errors: attention.action=ask_now not in [digest]")
  |> should.be_true
  result.markdown
  |> string.contains("This should have waited for digest.")
  |> should.be_true

  let written = simplifile.read(result.path) |> should.be_ok
  written |> should.equal(result.markdown)

  stop_subject(worker_started.data)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}
