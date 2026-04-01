import aura/memory
import aura/test_helpers
import aura/types
import aura/workspace
import aura/xdg
import gleam/string
import gleeunit/should
import simplifile

fn temp_paths(suffix: String) -> xdg.Paths {
  let base = "/tmp/aura-mem-" <> suffix
  xdg.Paths(
    config: base <> "/config",
    data: base <> "/data",
    state: base <> "/state",
  )
}

fn cleanup_paths(paths: xdg.Paths) -> Nil {
  let _ = simplifile.delete_all([paths.config, paths.data, paths.state])
  Nil
}

pub fn append_event_test() {
  let paths = temp_paths("event-" <> test_helpers.random_suffix())
  workspace.scaffold(paths) |> should.be_ok

  let event =
    types.Event(
      ts: "2026-03-25T14:30:00+08:00",
      domain: "cm2",
      event_type: "pr_merged",
      ref: "CICS-967",
      summary: "Fixed ACK receipt format",
    )

  memory.append_event(paths.data, event) |> should.be_ok

  let content = simplifile.read(paths.data <> "/events.jsonl") |> should.be_ok
  content
  |> string.contains("CICS-967")
  |> should.be_true

  // Cleanup
  cleanup_paths(paths)
}

pub fn append_anchor_test() {
  let paths = temp_paths("anchor-" <> test_helpers.random_suffix())
  workspace.scaffold(paths) |> should.be_ok
  workspace.scaffold_domain(paths, "cm2", "test", "cm2") |> should.be_ok

  let anchor =
    types.Anchor(
      ts: "2026-03-25T14:30:00+08:00",
      anchor_type: "decision",
      domain: "cm2",
      content: "Test decision",
      context: "TEST-001",
    )

  memory.append_anchor(paths.data, "cm2", anchor) |> should.be_ok

  let content =
    simplifile.read(paths.data <> "/domains/cm2/anchors.jsonl")
    |> should.be_ok
  content
  |> string.contains("Test decision")
  |> should.be_true

  // Cleanup
  cleanup_paths(paths)
}

pub fn read_identity_files_test() {
  let paths = temp_paths("identity-" <> test_helpers.random_suffix())
  workspace.scaffold(paths) |> should.be_ok

  let soul = memory.read_file(paths.config <> "/SOUL.md") |> should.be_ok
  soul
  |> string.contains("SOUL.md")
  |> should.be_true

  // Cleanup
  cleanup_paths(paths)
}
