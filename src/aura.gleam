import aura/config
import aura/discord
import aura/supervisor
import aura/workspace
import gleam/io
import gleam/result
import gleam/string
import simplifile

pub fn main() {
  io.println("Aura v0.1.0 starting...")

  // Determine workspace path (default ~/.aura)
  let workspace_base = get_workspace_base()
  io.println("Workspace: " <> workspace_base)

  // Scaffold workspace if needed
  case workspace.scaffold(workspace_base) {
    Ok(Nil) -> io.println("Workspace ready.")
    Error(e) -> {
      io.println("ERROR: Failed to scaffold workspace: " <> e)
      halt(1)
    }
  }

  // Load and validate config
  let cfg = case load_config(workspace_base) {
    Ok(cfg) -> {
      io.println("Config loaded.")
      io.println("  Brain model: " <> cfg.models.brain)
      io.println("  Workstream model: " <> cfg.models.workstream)
      io.println("  ACP model: " <> cfg.models.acp)
      cfg
    }
    Error(e) -> {
      io.println("ERROR: Invalid config: " <> e)
      halt(1)
      config.default_global()
    }
  }

  // List discovered workstreams
  case workspace.list_workstreams(workspace_base) {
    Ok(workstreams) -> {
      case workstreams {
        [] -> io.println("Workstreams: none")
        _ -> io.println("Workstreams: " <> string.join(workstreams, ", "))
      }
    }
    Error(_) -> io.println("Workstreams: none")
  }

  let on_message = fn(msg: discord.IncomingMessage) {
    io.println(
      "[aura] "
      <> msg.author_name
      <> " in #"
      <> msg.channel_name
      <> ": "
      <> msg.content,
    )
  }

  // Start supervisor
  case supervisor.start(cfg, on_message) {
    Ok(_pid) -> {
      io.println("Aura running. Press Ctrl+C to stop.")
      sleep_forever()
    }
    Error(e) -> {
      io.println("ERROR: Failed to start: " <> e)
      halt(1)
    }
  }
}

fn get_workspace_base() -> String {
  case get_env("AURA_WORKSPACE") {
    Ok(path) -> path
    Error(_) -> {
      case get_env("HOME") {
        Ok(home) -> home <> "/.aura"
        Error(_) -> ".aura"
      }
    }
  }
}

fn load_config(base: String) -> Result(config.GlobalConfig, String) {
  let config_path = base <> "/config.toml"
  use content <- result.try(
    simplifile.read(config_path)
    |> result.map_error(fn(e) { "Cannot read config.toml: " <> string.inspect(e) }),
  )
  config.parse_global(content)
}

@external(erlang, "aura_env_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "aura_runtime_ffi", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "aura_runtime_ffi", "sleep_forever")
fn sleep_forever() -> Nil
