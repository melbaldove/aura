import aura/cmd
import aura/config
import aura/discord/rest
import aura/dotenv
import aura/env
import aura/skill
import aura/xdg
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import simplifile

pub fn run() -> Nil {
  io.println("Aura Doctor")
  io.println("===========")
  io.println("")

  let paths = xdg.resolve()

  // Load .env if it exists
  let _ = dotenv.load(xdg.env_path(paths))

  io.println("Dependencies:")
  let dep_checks = [
    #("  Erlang/OTP", fn() {
      case cmd.run("erl", ["-eval", "halt(0)"], 5000) {
        Ok(#(0, _, _)) -> Ok("installed")
        _ -> Error("not found")
      }
    }),
    #("  tmux", fn() {
      case cmd.run("tmux", ["-V"], 5000) {
        Ok(#(0, stdout, _)) -> Ok(string.trim(stdout))
        _ -> Error("not found")
      }
    }),
  ]
  let dep_results = list.map(dep_checks, fn(c) {
    let #(label, checker) = c
    check(label, checker)
  })

  io.println("")
  io.println("Workspace:")
  let workspace_checks = [
    #("  Config dir", fn() {
      case simplifile.is_directory(paths.config) {
        Ok(True) -> Ok(paths.config)
        _ -> Error("missing")
      }
    }),
    #("  Data dir", fn() {
      case simplifile.is_directory(paths.data) {
        Ok(True) -> Ok(paths.data)
        _ -> Error("missing")
      }
    }),
    #("  State dir", fn() {
      case simplifile.is_directory(paths.state) {
        Ok(True) -> Ok(paths.state)
        _ -> Error("missing")
      }
    }),
  ]
  let workspace_results = list.map(workspace_checks, fn(c) {
    let #(label, checker) = c
    check(label, checker)
  })

  io.println("")
  io.println("Credentials:")
  let cred_checks = [
    #("  .env file", fn() {
      case simplifile.is_file(xdg.env_path(paths)) {
        Ok(True) -> Ok("exists")
        _ -> Error("missing")
      }
    }),
    #("  Discord token", fn() {
      case env.get_env("AURA_DISCORD_TOKEN") {
        Ok(token) -> {
          case rest.validate_token(token) {
            Ok(name) -> Ok("@" <> name)
            Error(e) -> Error(e)
          }
        }
        Error(_) -> Error("AURA_DISCORD_TOKEN not set")
      }
    }),
  ]
  let cred_results = list.map(cred_checks, fn(c) {
    let #(label, checker) = c
    check(label, checker)
  })

  io.println("")
  io.println("Config:")
  let config_checks = [
    #("  config.toml", fn() {
      case simplifile.read(xdg.config_path(paths, "config.toml")) {
        Ok(content) -> {
          case config.parse_global(content) {
            Ok(_) -> Ok("valid")
            Error(e) -> Error(e)
          }
        }
        Error(_) -> Error("missing or unreadable")
      }
    }),
  ]
  let config_results = list.map(config_checks, fn(c) {
    let #(label, checker) = c
    check(label, checker)
  })

  io.println("")
  io.println("Identity:")
  let identity_checks = [
    #("  SOUL.md", fn() {
      case simplifile.is_file(xdg.soul_path(paths)) {
        Ok(True) -> Ok("exists")
        _ -> Error("missing")
      }
    }),
  ]
  let identity_results = list.map(identity_checks, fn(c) {
    let #(label, checker) = c
    check(label, checker)
  })

  io.println("")
  io.println("Skills:")
  let _ = check("  Skills directory", fn() {
    let dir = xdg.skills_dir(paths)
    case skill.discover(dir) {
      Ok(skills) -> Ok(int.to_string(list.length(skills)) <> " found")
      Error(_) -> Ok("0 found")
    }
  })

  io.println("")
  let results =
    list.flatten([
      dep_results,
      workspace_results,
      cred_results,
      config_results,
      identity_results,
    ])
  let all_pass = list.all(results, fn(p) { p })
  case all_pass {
    True -> io.println("All checks passed.")
    False -> io.println("Some checks failed. Run 'aura start' to set up.")
  }
}

fn check(label: String, checker: fn() -> Result(String, String)) -> Bool {
  case checker() {
    Ok(detail) -> {
      io.println(label <> " ... " <> detail <> " ✓")
      True
    }
    Error(detail) -> {
      io.println(label <> " ... " <> detail <> " ✗")
      False
    }
  }
}
