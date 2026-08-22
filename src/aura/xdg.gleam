import aura/env
import gleam/int
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

/// Resolve the directory where compact dream cycle reports are written.
pub fn dream_reports_dir(paths: Paths) -> String {
  data_path(paths, "dream_reports")
}

/// Resolve the path for a dream cycle report, keyed by cycle start time.
pub fn dream_report_path(paths: Paths, started_at_ms: Int) -> String {
  dream_reports_dir(paths) <> "/" <> int.to_string(started_at_ms) <> ".md"
}

pub fn state_path(paths: Paths, subpath: String) -> String {
  paths.state <> "/" <> subpath
}

pub fn env_path(paths: Paths) -> String {
  paths.config <> "/.env"
}

/// Resolve the private directory for connector credential files.
pub fn connector_credentials_dir(paths: Paths) -> String {
  paths.config <> "/credentials/connectors"
}

/// Resolve the private directory for installed Google OAuth client records.
pub fn google_oauth_clients_dir(paths: Paths) -> String {
  paths.config <> "/credentials/google/oauth-clients"
}

/// Resolve the private directory for immutable Google OAuth client sets.
pub fn google_oauth_client_sets_dir(paths: Paths) -> String {
  paths.config <> "/credentials/google/client-sets"
}

/// Resolve the private directory for Codex monitor capability files.
pub fn monitor_capabilities_dir(paths: Paths) -> String {
  paths.config <> "/credentials/monitors"
}

/// Resolve one capability file from its persisted SHA-256 digest.
pub fn monitor_capability_path(paths: Paths, digest: String) -> String {
  monitor_capabilities_dir(paths) <> "/" <> digest <> ".capability"
}

/// Resolve the private configuration for the local Codex monitor runtime.
pub fn codex_monitor_runtime_config_path(paths: Paths) -> String {
  paths.config <> "/monitors/personal-life-codex.json"
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

pub fn policy_dir(paths: Paths) -> String {
  paths.config <> "/policies"
}

pub fn cognitive_dir(paths: Paths) -> String {
  paths.data <> "/cognitive"
}

pub fn decisions_path(paths: Paths) -> String {
  cognitive_dir(paths) <> "/decisions.jsonl"
}

pub fn deliveries_path(paths: Paths) -> String {
  cognitive_dir(paths) <> "/deliveries.jsonl"
}

pub fn labels_path(paths: Paths) -> String {
  cognitive_dir(paths) <> "/labels.jsonl"
}

pub fn attention_memory_path(paths: Paths) -> String {
  cognitive_dir(paths) <> "/ATTENTION.md"
}

pub fn concerns_dir(paths: Paths) -> String {
  paths.state <> "/concerns"
}

/// Resolve the directory for concerns owned by one operational domain.
pub fn domain_concerns_dir(paths: Paths, domain_slug: String) -> String {
  domain_state_dir(paths, domain_slug) <> "/concerns"
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

/// Resolve the transport-independent operational manifest for one domain.
pub fn domain_manifest_path(paths: Paths, domain_slug: String) -> String {
  domain_data_dir(paths, domain_slug) <> "/domain.json"
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
