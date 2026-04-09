import aura/test_helpers
import aura/tools
import aura/validator
import gleam/result
import gleam/string
import gleeunit/should
import simplifile

pub fn read_file_relative_test() {
  let base = "/tmp/aura-tools-read-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base)
  let _ = simplifile.write(base <> "/test.md", "hello world")

  tools.read_file("test.md", base) |> should.be_ok
  let content = tools.read_file("test.md", base) |> result.unwrap("")
  content |> should.equal("hello world")

  tools.read_file("nonexistent.md", base) |> should.be_error

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn read_file_absolute_test() {
  let base = "/tmp/aura-tools-readabs-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base)
  let _ = simplifile.write(base <> "/abs.md", "absolute content")

  // Absolute path should work regardless of base_dir
  tools.read_file(base <> "/abs.md", "/nonexistent") |> should.be_ok
  let content =
    tools.read_file(base <> "/abs.md", "/nonexistent") |> result.unwrap("")
  content |> should.equal("absolute content")

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn write_file_tier1_test() {
  // Use an absolute path that matches tier 1 (autonomous) patterns
  let base =
    "/tmp/aura-tools-write1-" <> test_helpers.random_suffix()
  let aura_data = base <> "/.local/share/aura"
  let _ =
    simplifile.create_directory_all(aura_data <> "/domains/cm2/logs")

  // Tier 1 path -- absolute path in data dir with logs/
  tools.write_file(
    aura_data <> "/domains/cm2/logs/2026-03-30.jsonl",
    base,
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

  // Tier 2 path (absolute, outside autonomous zones) without approval
  tools.write_file(
    base <> "/config.toml",
    base,
    "name = \"test\"",
    [],
    False,
  )
  |> should.be_error

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn write_file_tier2_approved_test() {
  let base = "/tmp/aura-tools-approved-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base)

  // Tier 2 path WITH approval -- should succeed
  tools.write_file(
    base <> "/config.toml",
    base,
    "name = \"test\"",
    [],
    True,
  )
  |> should.be_ok

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn write_file_validation_fail_test() {
  let base =
    "/tmp/aura-tools-valfail-" <> test_helpers.random_suffix()
  let aura_data = base <> "/.local/share/aura"
  let _ = simplifile.create_directory_all(aura_data)

  // Rule pattern must match the path passed to validate (which is the
  // original user-supplied path, not the resolved one)
  let abs_path = aura_data <> "/domains/test/MEMORY.md"
  let rules = [
    validator.Rule(
      path: abs_path,
      rule_type: validator.MustContain("# MEMORY"),
      message: "header required",
    ),
  ]

  // Use an autonomous path so tier check passes, validation should fail
  tools.write_file(abs_path, base, "no header here", rules, False)
  |> should.be_error

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn append_file_test() {
  let base =
    "/tmp/aura-tools-append-" <> test_helpers.random_suffix()
  let aura_data = base <> "/.local/share/aura"
  let _ = simplifile.create_directory_all(aura_data)
  let _ = simplifile.write(aura_data <> "/events.jsonl", "")

  // Autonomous path: events.jsonl in share/aura
  tools.append_file(
    aura_data <> "/events.jsonl",
    base,
    "{\"event\": \"test\"}\n",
    [],
    False,
  )
  |> should.be_ok

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn list_directory_test() {
  let base = "/tmp/aura-tools-list-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base <> "/sub")
  let _ = simplifile.write(base <> "/file.txt", "content")

  // Absolute path
  let result = tools.list_directory(base, "/nonexistent") |> should.be_ok
  string.contains(result, "file.txt") |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn resolve_path_absolute_test() {
  tools.resolve_path("/etc/hosts", "/base")
  |> should.equal("/etc/hosts")
}

pub fn resolve_path_relative_test() {
  tools.resolve_path("foo/bar.txt", "/base")
  |> should.equal("/base/foo/bar.txt")
}

pub fn resolve_path_home_test() {
  let resolved = tools.resolve_path("~/foo", "/base")
  // Should NOT start with /base — it's a home-relative path
  string.starts_with(resolved, "/base") |> should.be_false
  string.ends_with(resolved, "/foo") |> should.be_true
}

pub fn split_shell_args_simple_test() {
  tools.split_shell_args("tickets assigned")
  |> should.equal(["tickets", "assigned"])
}

pub fn split_shell_args_quoted_test() {
  tools.split_shell_args(
    "tickets search \"project = HY AND status = To Do\"",
  )
  |> should.equal(["tickets", "search", "project = HY AND status = To Do"])
}

pub fn split_shell_args_single_quotes_test() {
  tools.split_shell_args("tickets search 'status = To Do'")
  |> should.equal(["tickets", "search", "status = To Do"])
}

pub fn split_shell_args_mixed_test() {
  tools.split_shell_args(
    "--instance HY tickets search \"project = HY\"",
  )
  |> should.equal([
    "--instance",
    "HY",
    "tickets",
    "search",
    "project = HY",
  ])
}

pub fn split_shell_args_empty_test() {
  tools.split_shell_args("")
  |> should.equal([])
}
