import aura/cmd
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type SkillInfo {
  SkillInfo(name: String, description: String, path: String)
}

pub type SkillResult {
  SkillResult(exit_code: Int, stdout: String, stderr: String)
}

/// Scan {base}/skills/ for directories containing SKILL.md.
/// For each, extract the first non-heading non-empty line as description.
pub fn discover(workspace_base: String) -> Result(List(SkillInfo), String) {
  let skills_dir = workspace_base <> "/skills"
  use entries <- result.try(
    simplifile.read_directory(skills_dir)
    |> result.map_error(fn(e) {
      "Failed to read skills directory: " <> string.inspect(e)
    }),
  )
  let skills =
    list.filter_map(entries, fn(entry) {
      let skill_path = skills_dir <> "/" <> entry
      let skill_md_path = skill_path <> "/SKILL.md"
      case simplifile.is_directory(skill_path) {
        Ok(True) ->
          case simplifile.read(skill_md_path) {
            Ok(content) -> {
              let description = extract_description(content)
              Ok(SkillInfo(name: entry, description: description, path: skill_path))
            }
            Error(_) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  Ok(skills)
}

/// Filter skills to only those whose name is in the allowed list.
pub fn filter_allowed(
  skills: List(SkillInfo),
  allowed: List(String),
) -> List(SkillInfo) {
  list.filter(skills, fn(s) { list.contains(allowed, s.name) })
}

/// Build a prompt-friendly description string.
pub fn descriptions_for_prompt(skills: List(SkillInfo)) -> String {
  case skills {
    [] -> "No tools available."
    _ -> {
      let lines =
        list.map(skills, fn(s) { "- " <> s.name <> ": " <> s.description })
      "Available tools:\n" <> string.join(lines, "\n")
    }
  }
}

/// Find the entrypoint script and run it as an OS subprocess via FFI.
pub fn invoke(
  skill_info: SkillInfo,
  args: List(String),
  timeout_ms: Int,
) -> Result(SkillResult, String) {
  use entrypoint <- result.try(find_entrypoint(skill_info.path))
  use result <- result.try(cmd.run(entrypoint, args, timeout_ms))
  let #(exit_code, stdout, stderr) = result
  Ok(SkillResult(exit_code: exit_code, stdout: stdout, stderr: stderr))
}

fn find_entrypoint(skill_path: String) -> Result(String, String) {
  use entries <- result.try(
    simplifile.read_directory(skill_path)
    |> result.map_error(fn(e) {
      "Failed to read skill directory: " <> string.inspect(e)
    }),
  )
  let candidates =
    list.filter(entries, fn(entry) {
      entry != "SKILL.md" && !string.ends_with(entry, ".md")
    })
  case candidates {
    [first, ..] -> Ok(skill_path <> "/" <> first)
    [] -> Error("No entrypoint found in " <> skill_path)
  }
}

fn extract_description(content: String) -> String {
  let lines = string.split(content, "\n")
  let non_heading_non_empty =
    list.filter(lines, fn(line) {
      let trimmed = string.trim(line)
      trimmed != "" && !string.starts_with(trimmed, "#")
    })
  case non_heading_non_empty {
    [first, ..] -> string.trim(first)
    [] -> ""
  }
}
