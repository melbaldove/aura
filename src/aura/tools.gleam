import aura/skill
import aura/tier
import aura/validator
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// Read the file at `path` relative to `data_dir`. Returns the file contents
/// or an error string if the file is not found.
pub fn read_file(data_dir: String, path: String) -> Result(String, String) {
  let full_path = data_dir <> "/" <> path
  simplifile.read(full_path)
  |> result.map_error(fn(_) { "File not found: " <> path })
}

/// Write `content` to `path` (relative to `data_dir`), enforcing tier-based
/// write permissions and validator rules. `approved` bypasses tier restrictions
/// for paths that normally require explicit approval.
pub fn write_file(
  data_dir: String,
  path: String,
  content: String,
  rules: List(validator.Rule),
  approved: Bool,
) -> Result(Nil, String) {
  use _ <- result.try(check_tier(path, approved))
  use _ <- result.try(validator.validate(path, content, rules))
  let full_path = data_dir <> "/" <> path
  ensure_parent_dir(full_path)
  io.println("[tools] write_file: " <> path)
  simplifile.write(full_path, content)
  |> result.map_error(fn(e) { "Failed to write " <> path <> ": " <> string.inspect(e) })
}

/// Append `content` to `path` (relative to `data_dir`), subject to the same
/// tier and validation checks as `write_file`.
pub fn append_file(
  data_dir: String,
  path: String,
  content: String,
  rules: List(validator.Rule),
  approved: Bool,
) -> Result(Nil, String) {
  use _ <- result.try(check_tier(path, approved))
  use _ <- result.try(validator.validate(path, content, rules))
  let full_path = data_dir <> "/" <> path
  ensure_parent_dir(full_path)
  io.println("[tools] append_file: " <> path)
  simplifile.append(to: full_path, contents: content)
  |> result.map_error(fn(e) { "Failed to append to " <> path <> ": " <> string.inspect(e) })
}

/// List entries of a directory at `path` relative to `data_dir`.
/// Pass `"."` to list the data directory itself.
pub fn list_directory(data_dir: String, path: String) -> Result(String, String) {
  let full_path = case path {
    "." -> data_dir
    _ -> data_dir <> "/" <> path
  }
  case simplifile.read_directory(full_path) {
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
      let args = split_shell_args(args_str)
      io.println("[tools] run_skill: " <> name <> " " <> args_str)
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

/// Placeholder for the propose workflow (not yet implemented).
/// Currently returns a message directing the user to handle the action manually.
pub fn propose(description: String, _details: String) -> Result(String, String) {
  io.println("[tools] propose: " <> description)
  Ok(
    "Propose is not yet implemented. Description: "
    <> description
    <> ". Please handle this manually.",
  )
}

fn check_tier(path: String, approved: Bool) -> Result(Nil, String) {
  case tier.can_write_without_approval(path) || approved {
    True -> Ok(Nil)
    False ->
      Error(
        "This path requires approval. Use propose() first. Path: " <> path,
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
