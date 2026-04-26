import aura/cognitive_patch
import aura/db
import aura/event
import aura/memory
import aura/test_helpers
import aura/xdg
import gleam/dict
import gleam/erlang/process
import gleam/json
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

fn sample_event(id: String) -> event.AuraEvent {
  event.AuraEvent(
    id: id,
    source: "gmail",
    type_: "email.received",
    subject: "Daily newsletter summary",
    time_ms: 1000,
    tags: dict.from_list([#("from", "newsletter@example.com")]),
    external_id: "msg-" <> id,
    data: "{\"from\":\"newsletter@example.com\",\"body_text\":\"Here is today's newsletter.\"}",
  )
}

fn label_json(
  event_id: String,
  label: String,
  attention_any: List(String),
  note: String,
) -> json.Json {
  json.object([
    #("event_id", json.string(event_id)),
    #("label", json.string(label)),
    #("note", json.string(note)),
    #("attention_any", json.array(attention_any, json.string)),
    #("work_any", json.array([], json.string)),
    #("authority_any", json.array([], json.string)),
    #("min_citations", json.int(1)),
    #("min_gaps", json.int(0)),
    #("require_gap_contains", json.string("")),
  ])
}

pub fn propose_from_missing_labels_returns_noop_report_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-patch-empty")

  let result =
    cognitive_patch.propose_from_labels_at(paths, db_subject, 1234)
    |> should.be_ok

  result.proposal_count |> should.equal(0)
  result.label_count |> should.equal(0)
  result.path |> should.equal("")
  result.markdown
  |> should.equal(
    "OK: no cognitive labels found; no patch proposals generated.",
  )

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn propose_from_labels_groups_by_patch_target_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-patch-grouped")
  let assert Ok(True) = db.insert_event(db_subject, sample_event("ev-noisy"))
  let _ = simplifile.create_directory_all(xdg.cognitive_dir(paths))
  let _ =
    memory.append_jsonl(
      xdg.labels_path(paths),
      label_json(
        "ev-noisy",
        "false_interrupt",
        ["record", "digest"],
        "Too noisy.",
      ),
    )

  let result =
    cognitive_patch.propose_from_labels_at(paths, db_subject, 1234)
    |> should.be_ok

  result.proposal_count |> should.equal(1)
  result.label_count |> should.equal(1)
  result.path
  |> should.equal(xdg.cognitive_dir(paths) <> "/patch-proposals/1234.md")
  result.markdown
  |> string.contains("## `policies/attention.md`")
  |> should.be_true
  result.markdown |> string.contains("ev-noisy") |> should.be_true
  result.markdown
  |> string.contains("Daily newsletter summary")
  |> should.be_true
  result.markdown |> string.contains("Too noisy.") |> should.be_true
  result.markdown
  |> string.contains("Expected attention: record, digest")
  |> should.be_true

  let written = simplifile.read(result.path) |> should.be_ok
  written |> should.equal(result.markdown)

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}
