import aura/acp/session_store
import gleam/list
import simplifile
import gleeunit/should

fn test_path() -> String {
  "/tmp/aura-session-store-test-" <> "sessions.json"
}

fn cleanup() -> Nil {
  let _ = simplifile.delete(test_path())
  Nil
}

fn sample_session(name: String) -> session_store.StoredSession {
  session_store.StoredSession(
    session_name: name,
    domain: "test-domain",
    task_id: "t123",
    thread_id: "thread-456",
    started_at_ms: 1_000_000,
    state: "running",
    prompt: "fix the bug",
    cwd: "/home/user/repos/test",
  )
}

pub fn load_missing_file_returns_empty_test() {
  cleanup()
  session_store.load("/tmp/aura-nonexistent-file.json")
  |> should.equal([])
}

pub fn save_and_load_roundtrip_test() {
  cleanup()
  let path = test_path()
  let s1 = sample_session("acp-test-t1")
  let s2 = sample_session("acp-test-t2")

  session_store.save(path, [s1, s2])
  |> should.be_ok

  let loaded = session_store.load(path)
  list.length(loaded) |> should.equal(2)

  let first = case list.first(loaded) {
    Ok(s) -> s
    Error(_) -> panic as "expected session"
  }
  first.session_name |> should.equal("acp-test-t1")
  first.domain |> should.equal("test-domain")
  first.prompt |> should.equal("fix the bug")
  first.cwd |> should.equal("/home/user/repos/test")

  cleanup()
}

pub fn upsert_adds_new_session_test() {
  cleanup()
  let path = test_path()
  let s1 = sample_session("acp-test-t1")

  session_store.upsert(path, s1) |> should.be_ok

  let loaded = session_store.load(path)
  list.length(loaded) |> should.equal(1)

  cleanup()
}

pub fn upsert_updates_existing_session_test() {
  cleanup()
  let path = test_path()
  let s1 = sample_session("acp-test-t1")

  session_store.upsert(path, s1) |> should.be_ok

  let updated =
    session_store.StoredSession(..s1, state: "complete")
  session_store.upsert(path, updated) |> should.be_ok

  let loaded = session_store.load(path)
  list.length(loaded) |> should.equal(1)
  case list.first(loaded) {
    Ok(s) -> s.state |> should.equal("complete")
    Error(_) -> panic as "expected session"
  }

  cleanup()
}

pub fn remove_session_test() {
  cleanup()
  let path = test_path()
  let s1 = sample_session("acp-test-t1")
  let s2 = sample_session("acp-test-t2")

  session_store.save(path, [s1, s2]) |> should.be_ok
  session_store.remove(path, "acp-test-t1") |> should.be_ok

  let loaded = session_store.load(path)
  list.length(loaded) |> should.equal(1)
  case list.first(loaded) {
    Ok(s) -> s.session_name |> should.equal("acp-test-t2")
    Error(_) -> panic as "expected session"
  }

  cleanup()
}

pub fn is_terminal_test() {
  session_store.is_terminal("complete") |> should.be_true
  session_store.is_terminal("timed_out") |> should.be_true
  session_store.is_terminal("failed(timeout)") |> should.be_true
  session_store.is_terminal("failed(restart-dead)") |> should.be_true
  session_store.is_terminal("running") |> should.be_false
  session_store.is_terminal("starting") |> should.be_false
}

pub fn load_empty_file_returns_empty_test() {
  cleanup()
  let path = test_path()
  let _ = simplifile.write(path, "")
  session_store.load(path) |> should.equal([])
  cleanup()
}

pub fn load_corrupt_file_returns_empty_test() {
  cleanup()
  let path = test_path()
  let _ = simplifile.write(path, "not valid json{{{")
  session_store.load(path) |> should.equal([])
  cleanup()
}
