import aura/memory
import aura/types
import aura/workspace
import gleam/int
import gleam/string
import gleeunit/should
import simplifile

pub fn append_event_test() {
  let base = "/tmp/aura-mem-test-" <> random_suffix()
  workspace.scaffold(base) |> should.be_ok

  let event =
    types.Event(
      ts: "2026-03-25T14:30:00+08:00",
      workstream: "cm2",
      event_type: "pr_merged",
      ref: "CICS-967",
      summary: "Fixed ACK receipt format",
    )

  memory.append_event(base, event) |> should.be_ok

  let content = simplifile.read(base <> "/events.jsonl") |> should.be_ok
  content
  |> string.contains("CICS-967")
  |> should.be_true

  // Cleanup
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn append_anchor_test() {
  let base = "/tmp/aura-anchor-test-" <> random_suffix()
  workspace.scaffold(base) |> should.be_ok
  workspace.scaffold_workstream(base, "cm2", "test", "cm2") |> should.be_ok

  let anchor =
    types.Anchor(
      ts: "2026-03-25T14:30:00+08:00",
      anchor_type: "decision",
      workstream: "cm2",
      content: "Test decision",
      context: "TEST-001",
    )

  memory.append_anchor(base, "cm2", anchor) |> should.be_ok

  let content =
    simplifile.read(base <> "/workstreams/cm2/anchors.jsonl")
    |> should.be_ok
  content
  |> string.contains("Test decision")
  |> should.be_true

  // Cleanup
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn read_identity_files_test() {
  let base = "/tmp/aura-identity-test-" <> random_suffix()
  workspace.scaffold(base) |> should.be_ok

  let soul = memory.read_file(base <> "/SOUL.md") |> should.be_ok
  soul
  |> string.contains("SOUL.md")
  |> should.be_true

  // Cleanup
  let _ = simplifile.delete_all([base])
  Nil
}

fn random_suffix() -> String {
  erlang_unique_integer()
  |> int.to_string
  |> string.replace("-", "")
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int
