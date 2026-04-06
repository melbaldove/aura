import aura/memory
import aura/test_helpers
import aura/types
import aura/workspace
import aura/xdg
import gleam/json
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

fn temp_paths(suffix: String) -> xdg.Paths {
  let base = "/tmp/aura-mem-io-" <> suffix
  xdg.Paths(
    config: base <> "/config",
    data: base <> "/data",
    state: base <> "/state",
    domains: base <> "/domains",
  )
}

fn cleanup_paths(paths: xdg.Paths) -> Nil {
  let _ = simplifile.delete_all([paths.config, paths.data, paths.state])
  Nil
}

pub fn append_and_read_anchors_test() {
  let paths = temp_paths("anchors-" <> test_helpers.random_suffix())
  workspace.scaffold(paths) |> should.be_ok
  workspace.scaffold_domain(paths, "test-ws", "Test domain", "test-ws")
  |> should.be_ok

  let anchor1 =
    types.Anchor(
      ts: "2026-03-30T10:00:00+08:00",
      anchor_type: "decision",
      domain: "test-ws",
      content: "Chose SQLite over JSONL",
      context: "AURA-001",
    )
  memory.append_anchor(paths.data <> "/domains/test-ws", anchor1) |> should.be_ok

  let anchor2 =
    types.Anchor(
      ts: "2026-03-30T11:00:00+08:00",
      anchor_type: "decision",
      domain: "test-ws",
      content: "Added FTS5 search",
      context: "AURA-002",
    )
  memory.append_anchor(paths.data <> "/domains/test-ws", anchor2) |> should.be_ok

  // Read anchors with limit — should return all 2
  let anchors =
    memory.read_anchors(paths.data <> "/domains/test-ws", 10) |> should.be_ok
  list.length(anchors) |> should.equal(2)

  // Read with limit=1 should return last 1
  let limited =
    memory.read_anchors(paths.data <> "/domains/test-ws", 1) |> should.be_ok
  list.length(limited) |> should.equal(1)

  // The limited result should contain the last anchor's content
  let last_line = case list.last(limited) {
    Ok(l) -> l
    Error(_) -> ""
  }
  last_line
  |> string.contains("FTS5")
  |> should.be_true

  cleanup_paths(paths)
}

pub fn read_anchors_missing_file_test() {
  // When the anchors file doesn't exist, read_anchors returns an Error
  let result = memory.read_anchors("/tmp/nonexistent-dir-aura", 10)
  result |> should.be_error
}

pub fn append_and_read_daily_log_test() {
  let paths = temp_paths("log-" <> test_helpers.random_suffix())
  workspace.scaffold(paths) |> should.be_ok
  workspace.scaffold_domain(paths, "test-ws", "Test", "test-ws")
  |> should.be_ok

  let entry =
    json.object([
      #("ts", json.string("2026-03-30")),
      #("user", json.string("melbs")),
      #("content", json.string("test message")),
    ])
  memory.append_log(paths.data <> "/domains/test-ws", "2026-03-30", entry)
  |> should.be_ok

  let log =
    memory.read_daily_log(paths.data <> "/domains/test-ws", "2026-03-30")
    |> should.be_ok
  log
  |> string.contains("test message")
  |> should.be_true

  cleanup_paths(paths)
}

pub fn append_log_creates_directory_test() {
  let paths = temp_paths("logdir-" <> test_helpers.random_suffix())
  workspace.scaffold(paths) |> should.be_ok
  workspace.scaffold_domain(paths, "test-ws", "Test", "test-ws")
  |> should.be_ok

  // Append to a date that has no log file yet — directory creation is implicit
  let entry = json.object([#("action", json.string("init"))])
  memory.append_log(paths.data <> "/domains/test-ws", "2026-01-15", entry)
  |> should.be_ok

  let log =
    memory.read_daily_log(paths.data <> "/domains/test-ws", "2026-01-15")
    |> should.be_ok
  log
  |> string.contains("init")
  |> should.be_true

  cleanup_paths(paths)
}

pub fn read_daily_log_missing_test() {
  // Missing daily log returns Ok("") rather than an error
  let log =
    memory.read_daily_log("/tmp/nonexistent-aura-log", "2026-01-01")
    |> should.be_ok
  log |> should.equal("")
}

pub fn read_anchors_limit_exceeds_count_test() {
  let paths = temp_paths("anchors-lim-" <> test_helpers.random_suffix())
  workspace.scaffold(paths) |> should.be_ok
  workspace.scaffold_domain(paths, "test-ws", "Test", "test-ws")
  |> should.be_ok

  let anchor =
    types.Anchor(
      ts: "2026-03-30T09:00:00+08:00",
      anchor_type: "goal",
      domain: "test-ws",
      content: "Build a great product",
      context: "AURA-000",
    )
  memory.append_anchor(paths.data <> "/domains/test-ws", anchor) |> should.be_ok

  // limit larger than total count — should return all available
  let anchors =
    memory.read_anchors(paths.data <> "/domains/test-ws", 100) |> should.be_ok
  list.length(anchors) |> should.equal(1)

  cleanup_paths(paths)
}

pub fn append_multiple_log_entries_test() {
  let paths = temp_paths("multilog-" <> test_helpers.random_suffix())
  workspace.scaffold(paths) |> should.be_ok
  workspace.scaffold_domain(paths, "ws1", "WS One", "ws1")
  |> should.be_ok

  let e1 = json.object([#("msg", json.string("first entry"))])
  let e2 = json.object([#("msg", json.string("second entry"))])
  memory.append_log(paths.data <> "/domains/ws1", "2026-03-30", e1) |> should.be_ok
  memory.append_log(paths.data <> "/domains/ws1", "2026-03-30", e2) |> should.be_ok

  let log =
    memory.read_daily_log(paths.data <> "/domains/ws1", "2026-03-30") |> should.be_ok
  log |> string.contains("first entry") |> should.be_true
  log |> string.contains("second entry") |> should.be_true

  cleanup_paths(paths)
}
