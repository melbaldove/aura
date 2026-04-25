import aura/config
import aura/config_parser
import aura/ctl
import aura/doctor
import aura/dotenv
import aura/init
import aura/oauth_cli
import aura/supervisor
import aura/xdg
import gleam/io
import gleam/result
import gleam/string
import logging
import simplifile

pub type CliCommand {
  CliStart
  CliDoctor
  CliCtl(command: String)
  CliOauthGmail(email: String)
}

pub fn main() {
  case parse_args(get_args()) {
    CliDoctor -> {
      doctor.run()
      halt(0)
    }
    CliCtl(command) -> {
      run_ctl(command)
      halt(0)
    }
    CliOauthGmail(email) -> {
      logging.configure()
      case oauth_cli.run_gmail(email) {
        Ok(path) -> {
          io.println("Tokens saved to " <> path)
          halt(0)
        }
        Error(msg) -> {
          io.println("oauth gmail failed: " <> msg)
          halt(1)
        }
      }
    }
    CliStart -> run_start()
  }
}

fn parse_args(args: List(String)) -> CliCommand {
  case drop_leading_dash_dash(args) {
    [] -> CliStart
    ["start"] -> CliStart
    ["doctor"] -> CliDoctor
    ["dream"] -> CliCtl("dream")
    ["status"] -> CliCtl("status")
    ["ping"] -> CliCtl("ping")
    ["cognitive-smoke", "gmail-rel42"] -> CliCtl("cognitive-smoke gmail-rel42")
    ["cognitive-eval", "fixtures"] -> CliCtl("cognitive-eval fixtures")
    ["oauth", "gmail", email] -> CliOauthGmail(email)
    _ -> CliStart
  }
}

fn drop_leading_dash_dash(args: List(String)) -> List(String) {
  case args {
    ["--", ..rest] -> rest
    _ -> args
  }
}

pub fn parse_args_for_test(args: List(String)) -> CliCommand {
  parse_args(args)
}

fn run_start() {
  logging.configure()
  io.println("Aura v0.1.0")
  let paths = xdg.resolve()

  // First-run detection
  case xdg.is_initialized(paths) {
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

fn run_ctl(command: String) {
  let paths = xdg.resolve()
  case ctl.send(paths, command) {
    Ok(response) -> {
      io.println(response)
      case string.starts_with(response, "ERROR:") {
        True -> halt(1)
        False -> Nil
      }
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
  use resolved_token <- result.try(config_parser.resolve_env_string(
    cfg.discord.token,
  ))
  Ok(
    config.GlobalConfig(
      ..cfg,
      discord: config.DiscordConfig(..cfg.discord, token: resolved_token),
    ),
  )
}

@external(erlang, "aura_runtime_ffi", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "aura_runtime_ffi", "sleep_forever")
fn sleep_forever() -> Nil

@external(erlang, "aura_runtime_ffi", "get_plain_arguments")
fn get_args() -> List(String)
