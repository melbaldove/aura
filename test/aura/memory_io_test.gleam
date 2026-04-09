import aura/memory
import aura/test_helpers
import aura/scaffold
import aura/xdg
import gleam/json
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
  )
}

fn cleanup_paths(paths: xdg.Paths) -> Nil {
  let _ = simplifile.delete_all([paths.config, paths.data, paths.state])
  Nil
}

pub fn append_domain_log_test() {
  let paths = temp_paths("domlog-" <> test_helpers.random_suffix())
  scaffold.scaffold(paths) |> should.be_ok
  scaffold.scaffold_domain(paths, "test-ws", "Test domain", "test-ws")
  |> should.be_ok

  let domain_dir = paths.data <> "/domains/test-ws"
  memory.append_domain_log(domain_dir, "Chose SQLite over JSONL")
  |> should.be_ok
  memory.append_domain_log(domain_dir, "Added FTS5 search")
  |> should.be_ok

  let content =
    simplifile.read(domain_dir <> "/log.jsonl") |> should.be_ok
  content |> string.contains("Chose SQLite") |> should.be_true
  content |> string.contains("FTS5") |> should.be_true
  content |> string.contains("timestamp") |> should.be_true

  cleanup_paths(paths)
}

pub fn append_and_read_daily_log_test() {
  let paths = temp_paths("log-" <> test_helpers.random_suffix())
  scaffold.scaffold(paths) |> should.be_ok
  scaffold.scaffold_domain(paths, "test-ws", "Test", "test-ws")
  |> should.be_ok

  let entry =
    json.object([
      #("ts", json.string("2026-03-30")),
      #("user", json.string("testuser")),
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
  scaffold.scaffold(paths) |> should.be_ok
  scaffold.scaffold_domain(paths, "test-ws", "Test", "test-ws")
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

pub fn append_multiple_log_entries_test() {
  let paths = temp_paths("multilog-" <> test_helpers.random_suffix())
  scaffold.scaffold(paths) |> should.be_ok
  scaffold.scaffold_domain(paths, "ws1", "WS One", "ws1")
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
