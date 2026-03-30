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

/// Scan the given skills directory for directories containing SKILL.md.
/// For each, extract the first non-heading non-empty line as description.
pub fn discover(skills_dir: String) -> Result(List(SkillInfo), String) {
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

/// Validate a skill name: lowercase, numbers, hyphens, underscores only. No path traversal.
fn validate_name(name: String) -> Result(Nil, String) {
  case
    string.contains(name, "..")
    || string.contains(name, "/")
    || string.contains(name, " ")
  {
    True ->
      Error(
        "Invalid skill name: "
        <> name
        <> " (no spaces, path separators, or '..' allowed)",
      )
    False -> {
      let valid_chars =
        string.to_graphemes(name)
        |> list.all(fn(c) {
          let cp =
            string.to_utf_codepoints(c)
            |> list.first
          case cp {
            Ok(p) -> {
              let code = string.utf_codepoint_to_int(p)
              // a-z: 97-122, 0-9: 48-57, hyphen: 45, underscore: 95
              { code >= 97 && code <= 122 }
              || { code >= 48 && code <= 57 }
              || code == 45
              || code == 95
            }
            Error(_) -> False
          }
        })
      case valid_chars && !string.is_empty(name) {
        True -> Ok(Nil)
        False ->
          Error(
            "Invalid skill name: "
            <> name
            <> " (use lowercase, numbers, hyphens, underscores)",
          )
      }
    }
  }
}

/// Create a new skill. Writes SKILL.md to skills_dir/name/SKILL.md.
/// Fails if skill already exists or name is invalid.
pub fn create(
  skills_dir: String,
  name: String,
  content: String,
) -> Result(Nil, String) {
  use _ <- result.try(validate_name(name))

  let skill_path = skills_dir <> "/" <> name
  case simplifile.is_directory(skill_path) {
    Ok(True) -> Error("Skill already exists: " <> name)
    _ -> {
      use _ <- result.try(
        simplifile.create_directory_all(skill_path)
        |> result.map_error(fn(e) {
          "Failed to create skill directory: " <> string.inspect(e)
        }),
      )
      simplifile.write(skill_path <> "/SKILL.md", content)
      |> result.map_error(fn(e) { "Failed to write SKILL.md: " <> string.inspect(e) })
    }
  }
}

/// Update an existing skill's SKILL.md content.
pub fn update(
  skills_dir: String,
  name: String,
  content: String,
) -> Result(Nil, String) {
  use _ <- result.try(validate_name(name))

  let skill_path = skills_dir <> "/" <> name
  case simplifile.is_directory(skill_path) {
    Ok(True) -> {
      simplifile.write(skill_path <> "/SKILL.md", content)
      |> result.map_error(fn(e) { "Failed to write SKILL.md: " <> string.inspect(e) })
    }
    _ -> Error("Skill not found: " <> name)
  }
}

/// List all skills with name and description, formatted for LLM consumption.
pub fn list_with_details(skills_dir: String) -> Result(String, String) {
  case discover(skills_dir) {
    Ok(skills) -> {
      case skills {
        [] -> Ok("No skills installed.")
        _ -> {
          let lines =
            list.map(skills, fn(s) {
              "- **" <> s.name <> "**: " <> s.description
            })
          Ok(string.join(lines, "\n"))
        }
      }
    }
    Error(e) -> Error(e)
  }
}
