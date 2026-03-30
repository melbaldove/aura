import aura/test_helpers
import aura/tools
import aura/validator
import gleam/result
import gleam/string
import gleeunit/should
import simplifile

pub fn read_file_test() {
  let base = "/tmp/aura-tools-read-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base)
  let _ = simplifile.write(base <> "/test.md", "hello world")

  tools.read_file(base, "test.md") |> should.be_ok
  let content = tools.read_file(base, "test.md") |> result.unwrap("")
  content |> should.equal("hello world")

  tools.read_file(base, "nonexistent.md") |> should.be_error

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn write_file_tier1_test() {
  let base = "/tmp/aura-tools-write1-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base <> "/workstreams/cm2/logs")

  // Tier 1 path — should succeed without approval
  tools.write_file(
    base,
    "workstreams/cm2/logs/2026-03-30.jsonl",
    "{\"test\": true}\n",
    [],
    False,
  )
  |> should.be_ok

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn write_file_tier2_rejected_test() {
  let base = "/tmp/aura-tools-reject-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base)

  // Tier 2 path without approval — should be rejected
  tools.write_file(base, "config.toml", "name = \"test\"", [], False)
  |> should.be_error

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn write_file_tier2_approved_test() {
  let base = "/tmp/aura-tools-approved-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base)

  // Tier 2 path WITH approval — should succeed
  tools.write_file(base, "config.toml", "name = \"test\"", [], True)
  |> should.be_ok

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn write_file_validation_fail_test() {
  let base = "/tmp/aura-tools-valfail-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base)

  let rules = [
    validator.Rule(
      path: "MEMORY.md",
      rule_type: validator.MustContain("# MEMORY"),
      message: "header required",
    ),
  ]

  tools.write_file(base, "MEMORY.md", "no header here", rules, False)
  |> should.be_error

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn append_file_test() {
  let base = "/tmp/aura-tools-append-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base)
  let _ = simplifile.write(base <> "/events.jsonl", "")

  tools.append_file(base, "events.jsonl", "{\"event\": \"test\"}\n", [], False)
  |> should.be_ok

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn list_directory_test() {
  let base = "/tmp/aura-tools-list-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base <> "/sub")
  let _ = simplifile.write(base <> "/file.txt", "content")

  let result = tools.list_directory(base, ".") |> should.be_ok
  string.contains(result, "file.txt") |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn propose_placeholder_test() {
  tools.propose("create workstream", "details here")
  |> should.be_ok
  let result =
    tools.propose("create workstream", "details here") |> result.unwrap("")
  string.contains(result, "not yet implemented") |> should.be_true
}
