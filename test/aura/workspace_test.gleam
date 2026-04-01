import aura/test_helpers
import aura/workspace
import aura/xdg
import gleeunit/should
import simplifile

fn temp_paths(suffix: String) -> xdg.Paths {
  let base = "/tmp/aura-test-" <> suffix
  xdg.Paths(
    config: base <> "/config",
    data: base <> "/data",
    state: base <> "/state",
  )
}

fn cleanup_paths(paths: xdg.Paths) -> Nil {
  // Delete the parent dir (all three share a common /tmp/aura-test-* prefix)
  // We clean each individually to be safe
  let _ = simplifile.delete_all([paths.config, paths.data, paths.state])
  Nil
}

pub fn scaffold_workspace_test() {
  let paths = temp_paths("workspace-" <> test_helpers.random_suffix())

  workspace.scaffold(paths)
  |> should.be_ok

  // Config files should exist
  simplifile.is_file(paths.config <> "/config.toml") |> should.be_ok
  simplifile.is_directory(paths.config <> "/domains") |> should.be_ok

  // Data directories should exist
  simplifile.is_directory(paths.data <> "/skills") |> should.be_ok
  simplifile.is_directory(paths.data <> "/acp/sessions") |> should.be_ok
  simplifile.is_directory(paths.data <> "/acp/completed") |> should.be_ok

  // Identity files should exist with content
  simplifile.read(paths.config <> "/SOUL.md")
  |> should.be_ok

  simplifile.read(paths.config <> "/META.md")
  |> should.be_ok

  // State files
  simplifile.read(paths.state <> "/MEMORY.md")
  |> should.be_ok

  // Data files
  simplifile.is_file(paths.data <> "/events.jsonl") |> should.be_ok

  // Cleanup
  cleanup_paths(paths)
}

pub fn scaffold_domain_test() {
  let paths = temp_paths("ws-" <> test_helpers.random_suffix())
  let _ = simplifile.create_directory_all(paths.config <> "/domains")
  let _ = simplifile.create_directory_all(paths.data <> "/domains")

  workspace.scaffold_domain(paths, "test-project", "A test domain", "test-project")
  |> should.be_ok

  simplifile.is_file(paths.config <> "/domains/test-project/config.toml") |> should.be_ok
  simplifile.is_directory(paths.data <> "/domains/test-project/logs") |> should.be_ok
  simplifile.is_directory(paths.data <> "/domains/test-project/summaries") |> should.be_ok

  // Cleanup
  cleanup_paths(paths)
}
