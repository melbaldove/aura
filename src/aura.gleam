import aura/config
import aura/config_parser
import aura/doctor
import aura/dotenv
import aura/init
import aura/supervisor
import aura/xdg
import gleam/io
import gleam/result
import gleam/string
import simplifile

pub fn main() {
  let args = get_args()
  case args {
    ["doctor"] -> {
      doctor.run()
      halt(0)
    }
    _ -> run_start()
  }
}

fn run_start() {
  io.println("Aura v0.1.0")
  let paths = xdg.resolve()

  // First-run detection
  case xdg.workspace_exists(paths) {
    False -> {
      case init.run(paths) {
        Ok(Nil) -> Nil
        Error(e) -> {
          io.println("Setup failed: " <> e)
          halt(1)
        }
      }
    }
    True -> Nil
  }

  // Load .env
  case dotenv.load(xdg.env_path(paths)) {
    Ok(Nil) -> Nil
    Error(_) -> Nil
  }

  // Load config
  let cfg = case load_config(paths) {
    Ok(cfg) -> cfg
    Error(e) -> {
      io.println("ERROR: " <> e)
      halt(1)
      config.default_global()
    }
  }

  // Start
  case supervisor.start(cfg, paths) {
    Ok(_pid) -> {
      io.println("Aura running. Press Ctrl+C to stop.")
      sleep_forever()
    }
    Error(e) -> {
      io.println("ERROR: " <> e)
      halt(1)
    }
  }
}

fn load_config(paths: xdg.Paths) -> Result(config.GlobalConfig, String) {
  let path = xdg.config_path(paths, "config.toml")
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) {
      "Cannot read config.toml: " <> string.inspect(e)
    }),
  )
  use cfg <- result.try(config.parse_global(content))
  // Resolve env var references in the discord token
  use resolved_token <- result.try(
    config_parser.resolve_env_string(cfg.discord.token),
  )
  Ok(config.GlobalConfig(
    ..cfg,
    discord: config.DiscordConfig(..cfg.discord, token: resolved_token),
  ))
}

@external(erlang, "aura_runtime_ffi", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "aura_runtime_ffi", "sleep_forever")
fn sleep_forever() -> Nil

@external(erlang, "init", "get_plain_arguments")
fn get_args() -> List(String)
