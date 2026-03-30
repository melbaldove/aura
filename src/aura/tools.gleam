import aura/skill
import aura/tier
import aura/validator
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub fn read_file(data_dir: String, path: String) -> Result(String, String) {
  let full_path = data_dir <> "/" <> path
  simplifile.read(full_path)
  |> result.map_error(fn(_) { "File not found: " <> path })
}

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

pub fn run_skill(
  skills: List(skill.SkillInfo),
  name: String,
  args_str: String,
) -> Result(String, String) {
  case list.find(skills, fn(s) { s.name == name }) {
    Ok(skill_info) -> {
      let args = string.split(args_str, " ") |> list.filter(fn(a) { a != "" })
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
