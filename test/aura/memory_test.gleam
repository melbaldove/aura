import aura/memory
import aura/scaffold
import aura/test_helpers
import aura/types
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
  scaffold.scaffold(paths) |> should.be_ok

  let event =
    types.Event(
      ts: "2026-03-25T14:30:00+08:00",
      domain: "backend",
      event_type: "pr_merged",
      ref: "TASK-456",
      summary: "Fixed ACK receipt format",
    )

  memory.append_event(paths.data, event) |> should.be_ok

  let content = simplifile.read(paths.data <> "/events.jsonl") |> should.be_ok
  content
  |> string.contains("TASK-456")
  |> should.be_true

  // Cleanup
  cleanup_paths(paths)
}

pub fn append_domain_log_test() {
  let paths = temp_paths("domlog-" <> test_helpers.random_suffix())
  scaffold.scaffold(paths) |> should.be_ok
  scaffold.scaffold_domain(paths, "backend", "test", "backend") |> should.be_ok

  let domain_dir = paths.data <> "/domains/backend"
  memory.append_domain_log(domain_dir, "Test decision")
  |> should.be_ok

  let content =
    simplifile.read(domain_dir <> "/log.jsonl")
    |> should.be_ok
  content
  |> string.contains("Test decision")
  |> should.be_true

  // Cleanup
  cleanup_paths(paths)
}

pub fn read_identity_files_test() {
  let paths = temp_paths("identity-" <> test_helpers.random_suffix())
  scaffold.scaffold(paths) |> should.be_ok

  let soul = memory.read_file(paths.config <> "/SOUL.md") |> should.be_ok
  soul
  |> string.contains("SOUL.md")
  |> should.be_true

  // Cleanup
  cleanup_paths(paths)
}
