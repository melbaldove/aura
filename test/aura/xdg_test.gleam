import aura/xdg
import gleeunit/should

pub fn config_dir_default_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  paths.config |> should.equal("/home/testuser/.config/aura")
}

pub fn data_dir_default_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  paths.data |> should.equal("/home/testuser/.local/share/aura")
}

pub fn state_dir_default_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  paths.state |> should.equal("/home/testuser/.local/state/aura")
}

pub fn config_subpath_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  xdg.config_path(paths, "config.toml")
  |> should.equal("/home/testuser/.config/aura/config.toml")
}

pub fn data_subpath_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  xdg.data_path(paths, "events.jsonl")
  |> should.equal("/home/testuser/.local/share/aura/events.jsonl")
}

pub fn domain_config_path_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  xdg.domain_config_path(paths, "cm2")
  |> should.equal("/home/testuser/.config/aura/domains/cm2/config.toml")
}

pub fn domain_data_dir_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  xdg.domain_data_dir(paths, "cm2")
  |> should.equal("/home/testuser/.local/share/aura/domains/cm2")
}

pub fn domain_state_dir_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  xdg.domain_state_dir(paths, "cm2")
  |> should.equal("/home/testuser/.local/state/aura/domains/cm2")
}

pub fn env_path_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  xdg.env_path(paths) |> should.equal("/home/testuser/.config/aura/.env")
}

pub fn soul_path_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  xdg.soul_path(paths) |> should.equal("/home/testuser/.config/aura/SOUL.md")
}

pub fn memory_path_test() {
  let paths = xdg.resolve_with_home("/home/testuser")
  xdg.memory_path(paths)
  |> should.equal("/home/testuser/.local/state/aura/MEMORY.md")
}

pub fn is_initialized_false_test() {
  let paths = xdg.resolve_with_home("/nonexistent/path")
  xdg.is_initialized(paths) |> should.equal(False)
}
