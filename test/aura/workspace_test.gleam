import aura/workspace
import gleam/int
import gleam/string
import gleeunit/should
import simplifile

pub fn scaffold_workspace_test() {
  let base = "/tmp/aura-test-workspace-" <> random_suffix()

  workspace.scaffold(base)
  |> should.be_ok

  // Core files should exist
  simplifile.is_file(base <> "/config.toml") |> should.be_ok
  simplifile.is_directory(base <> "/workstreams") |> should.be_ok
  simplifile.is_directory(base <> "/skills") |> should.be_ok
  simplifile.is_directory(base <> "/acp/sessions") |> should.be_ok
  simplifile.is_directory(base <> "/acp/completed") |> should.be_ok

  // Identity files should exist with content
  simplifile.read(base <> "/SOUL.md")
  |> should.be_ok

  simplifile.read(base <> "/META.md")
  |> should.be_ok

  // Cleanup
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn scaffold_workstream_test() {
  let base = "/tmp/aura-test-ws-" <> random_suffix()
  let _ = simplifile.create_directory_all(base <> "/workstreams")

  workspace.scaffold_workstream(base, "test-project", "A test workstream", "test-project")
  |> should.be_ok

  simplifile.is_file(base <> "/workstreams/test-project/config.toml") |> should.be_ok
  simplifile.is_directory(base <> "/workstreams/test-project/logs") |> should.be_ok
  simplifile.is_directory(base <> "/workstreams/test-project/summaries") |> should.be_ok

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
