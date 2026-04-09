import aura/env
import simplifile

pub type Paths {
  Paths(config: String, data: String, state: String)
}

pub fn resolve() -> Paths {
  let home = case env.get_env("HOME") {
    Ok(h) -> h
    Error(_) -> "/root"
  }

  let config = case env.get_env("XDG_CONFIG_HOME") {
    Ok(v) -> v <> "/aura"
    Error(_) -> home <> "/.config/aura"
  }

  let data = case env.get_env("XDG_DATA_HOME") {
    Ok(v) -> v <> "/aura"
    Error(_) -> home <> "/.local/share/aura"
  }

  let state = case env.get_env("XDG_STATE_HOME") {
    Ok(v) -> v <> "/aura"
    Error(_) -> home <> "/.local/state/aura"
  }

  Paths(config: config, data: data, state: state)
}

pub fn resolve_with_home(home: String) -> Paths {
  Paths(
    config: home <> "/.config/aura",
    data: home <> "/.local/share/aura",
    state: home <> "/.local/state/aura",
  )
}

pub fn config_path(paths: Paths, subpath: String) -> String {
  paths.config <> "/" <> subpath
}

pub fn data_path(paths: Paths, subpath: String) -> String {
  paths.data <> "/" <> subpath
}

pub fn state_path(paths: Paths, subpath: String) -> String {
  paths.state <> "/" <> subpath
}

pub fn env_path(paths: Paths) -> String {
  paths.config <> "/.env"
}

pub fn soul_path(paths: Paths) -> String {
  paths.config <> "/SOUL.md"
}

pub fn user_path(paths: Paths) -> String {
  paths.config <> "/USER.md"
}

pub fn meta_path(paths: Paths) -> String {
  paths.config <> "/META.md"
}

pub fn memory_path(paths: Paths) -> String {
  paths.state <> "/MEMORY.md"
}

pub fn events_path(paths: Paths) -> String {
  paths.data <> "/events.jsonl"
}

pub fn db_path(paths: Paths) -> String {
  paths.data <> "/aura.db"
}

pub fn skills_dir(paths: Paths) -> String {
  paths.data <> "/skills"
}

pub fn domain_config_path(paths: Paths, name: String) -> String {
  paths.config <> "/domains/" <> name <> "/config.toml"
}

pub fn domain_config_dir(paths: Paths, name: String) -> String {
  paths.config <> "/domains/" <> name
}

pub fn domain_data_dir(paths: Paths, name: String) -> String {
  paths.data <> "/domains/" <> name
}

pub fn domain_state_dir(paths: Paths, name: String) -> String {
  paths.state <> "/domains/" <> name
}

/// Resolve the STATE.md path for a domain (or global if "aura").
pub fn domain_state_path(paths: Paths, domain_name: String) -> String {
  case domain_name {
    "aura" -> state_path(paths, "STATE.md")
    name -> domain_state_dir(paths, name) <> "/STATE.md"
  }
}

/// Resolve the MEMORY.md path for a domain (or global if "aura").
pub fn domain_memory_path(paths: Paths, domain_name: String) -> String {
  case domain_name {
    "aura" -> memory_path(paths)
    name -> domain_data_dir(paths, name) <> "/MEMORY.md"
  }
}

/// Resolve the log directory for a domain (or global data dir if "aura").
pub fn domain_log_dir(paths: Paths, domain_name: String) -> String {
  case domain_name {
    "aura" -> paths.data
    name -> domain_data_dir(paths, name)
  }
}

pub fn is_initialized(paths: Paths) -> Bool {
  let config_toml = paths.config <> "/config.toml"
  simplifile.is_file(config_toml) == Ok(True)
}
