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
  let p1 = check("  Erlang/OTP", fn() {
    case cmd.run("erl", ["-eval", "halt(0)"], 5000) {
      Ok(#(0, _, _)) -> Ok("installed")
      _ -> Error("not found")
    }
  })

  let p2 = check("  tmux", fn() {
    case cmd.run("tmux", ["-V"], 5000) {
      Ok(#(0, stdout, _)) -> Ok(string.trim(stdout))
      _ -> Error("not found")
    }
  })

  io.println("")
  io.println("Workspace:")
  let p3 = check("  Config dir", fn() {
    case simplifile.is_directory(paths.config) {
      Ok(True) -> Ok(paths.config)
      _ -> Error("missing")
    }
  })

  let p4 = check("  Data dir", fn() {
    case simplifile.is_directory(paths.data) {
      Ok(True) -> Ok(paths.data)
      _ -> Error("missing")
    }
  })

  let p5 = check("  State dir", fn() {
    case simplifile.is_directory(paths.state) {
      Ok(True) -> Ok(paths.state)
      _ -> Error("missing")
    }
  })

  io.println("")
  io.println("Credentials:")
  let p6 = check("  .env file", fn() {
    case simplifile.is_file(xdg.env_path(paths)) {
      Ok(True) -> Ok("exists")
      _ -> Error("missing")
    }
  })

  let p7 = check("  Discord token", fn() {
    case env.get_env("AURA_DISCORD_TOKEN") {
      Ok(token) -> {
        case rest.validate_token(token) {
          Ok(name) -> Ok("@" <> name)
          Error(e) -> Error(e)
        }
      }
      Error(_) -> Error("AURA_DISCORD_TOKEN not set")
    }
  })

  io.println("")
  io.println("Config:")
  let p8 = check("  config.toml", fn() {
    case simplifile.read(xdg.config_path(paths, "config.toml")) {
      Ok(content) -> {
        case config.parse_global(content) {
          Ok(_) -> Ok("valid")
          Error(e) -> Error(e)
        }
      }
      Error(_) -> Error("missing or unreadable")
    }
  })

  io.println("")
  io.println("Identity:")
  let p9 = check("  SOUL.md", fn() {
    case simplifile.is_file(xdg.soul_path(paths)) {
      Ok(True) -> Ok("exists")
      _ -> Error("missing")
    }
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
  let all_pass = list.all([p1, p2, p3, p4, p5, p6, p7, p8, p9], fn(p) { p })
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
