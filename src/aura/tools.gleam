import aura/env
import aura/skill
import aura/tier
import aura/validator
import gleam/dynamic/decode
import gleam/int
import logging
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Resolve a file path to an absolute path.
/// - Absolute paths (/...) -> used as-is
/// - Home-relative (~/ or bare ~) -> expand ~ to $HOME
/// - Relative -> resolve against base_dir
pub fn resolve_path(path: String, base_dir: String) -> String {
  case path {
    "/" <> _ -> path
    "~/" <> rest -> {
      let home = case env.get_env("HOME") {
        Ok(h) -> h
        Error(_) -> "/root"
      }
      home <> "/" <> rest
    }
    "~" -> {
      case env.get_env("HOME") {
        Ok(h) -> h
        Error(_) -> "/root"
      }
    }
    _ -> base_dir <> "/" <> path
  }
}

/// Read a file at `path`, resolved against `base_dir`. Returns the file
/// contents or an error string if the file is not found.
pub fn read_file(path: String, base_dir: String) -> Result(String, String) {
  let resolved = resolve_path(path, base_dir)
  simplifile.read(resolved)
  |> result.map_error(fn(_) { "File not found: " <> path })
}

/// Write `content` to `path` (resolved against `base_dir`), enforcing
/// tier-based write permissions and validator rules on the resolved absolute
/// path. `approved` bypasses tier restrictions for paths that have already
/// been approved via the propose flow.
pub fn write_file(
  path: String,
  base_dir: String,
  content: String,
  rules: List(validator.Rule),
  approved: Bool,
) -> Result(Nil, String) {
  let resolved = resolve_path(path, base_dir)
  use _ <- result.try(check_tier(resolved, approved))
  use _ <- result.try(validator.validate(path, content, rules))
  ensure_parent_dir(resolved)
  logging.log(logging.Info, "[tools] write_file: " <> resolved)
  simplifile.write(resolved, content)
  |> result.map_error(fn(e) {
    "Failed to write " <> path <> ": " <> string.inspect(e)
  })
}

/// Append `content` to `path` (resolved against `base_dir`), subject to the
/// same tier and validation checks as `write_file`.
pub fn append_file(
  path: String,
  base_dir: String,
  content: String,
  rules: List(validator.Rule),
  approved: Bool,
) -> Result(Nil, String) {
  let resolved = resolve_path(path, base_dir)
  use _ <- result.try(check_tier(resolved, approved))
  use _ <- result.try(validator.validate(path, content, rules))
  ensure_parent_dir(resolved)
  logging.log(logging.Info, "[tools] append_file: " <> resolved)
  simplifile.append(to: resolved, contents: content)
  |> result.map_error(fn(e) {
    "Failed to append to " <> path <> ": " <> string.inspect(e)
  })
}

/// List entries of a directory at `path`, resolved against `base_dir`.
pub fn list_directory(path: String, base_dir: String) -> Result(String, String) {
  let resolved = resolve_path(path, base_dir)
  case simplifile.read_directory(resolved) {
    Ok(entries) -> Ok(string.join(entries, "\n"))
    Error(_) -> Error("Directory not found: " <> path)
  }
}

/// Invoke a skill by `name` with space-separated `args_str`, with a 30 s
/// timeout. Returns stdout on exit code 0, or an error describing the failure.
pub fn run_skill(
  skills: List(skill.SkillInfo),
  name: String,
  args_str: String,
) -> Result(String, String) {
  case list.find(skills, fn(s) { s.name == name }) {
    Ok(skill_info) -> {
      // Parse args as JSON array first (structured), fall back to shell splitting (legacy)
      let args = case json.parse(args_str, decode.list(decode.string)) {
        Ok(parsed) -> parsed
        Error(_) -> split_shell_args(args_str)
      }
      logging.log(logging.Info, "[tools] run_skill: " <> name <> " " <> string.inspect(args))
      case skill.invoke(skill_info, args, 30_000) {
        Ok(r) ->
          case r.exit_code {
            0 -> Ok(r.stdout)
            code ->
              Error(
                "Skill "
                <> name
                <> " exited with code "
                <> int.to_string(code)
                <> ": "
                <> r.stdout,
              )
          }
        Error(e) -> Error("Skill " <> name <> " failed: " <> e)
      }
    }
    Error(_) -> Error("Skill not found: " <> name)
  }
}

fn check_tier(path: String, approved: Bool) -> Result(Nil, String) {
  case tier.can_write_without_approval(path) || approved {
    True -> Ok(Nil)
    False ->
      Error(
        "This path requires approval. Call propose(path, content, description) to request it. Path: "
        <> path,
      )
  }
}

/// Split a string into args respecting quoted substrings.
/// `tickets search "project = HY"` → ["tickets", "search", "project = HY"]
/// Handles both double and single quotes. Strips the quotes from the result.
pub fn split_shell_args(input: String) -> List(String) {
  split_shell_args_loop(string.to_graphemes(input), "", [], False, "")
}

fn split_shell_args_loop(
  chars: List(String),
  current: String,
  acc: List(String),
  in_quote: Bool,
  quote_char: String,
) -> List(String) {
  case chars {
    [] -> {
      case current {
        "" -> list.reverse(acc)
        _ -> list.reverse([current, ..acc])
      }
    }
    [c, ..rest] -> {
      case in_quote {
        True -> {
          case c == quote_char {
            True -> split_shell_args_loop(rest, current, acc, False, "")
            False -> split_shell_args_loop(rest, current <> c, acc, True, quote_char)
          }
        }
        False -> {
          case c {
            "\"" | "'" -> split_shell_args_loop(rest, current, acc, True, c)
            " " -> {
              case current {
                "" -> split_shell_args_loop(rest, "", acc, False, "")
                _ -> split_shell_args_loop(rest, "", [current, ..acc], False, "")
              }
            }
            _ -> split_shell_args_loop(rest, current <> c, acc, False, "")
          }
        }
      }
    }
  }
}

fn ensure_parent_dir(path: String) -> Nil {
  let parts = string.split(path, "/")
  case list.length(parts) > 1 {
    True -> {
      let parent =
        list.take(parts, list.length(parts) - 1) |> string.join("/")
      let _ = simplifile.create_directory_all(parent)
      Nil
    }
    False -> Nil
  }
}
