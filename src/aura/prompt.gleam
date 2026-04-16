import gleam/bool
import gleam/int
import logging
import gleam/list
import gleam/result
import gleam/string

/// Prompt user for text input
pub fn ask(prompt: String) -> Result(String, String) {
  get_line(prompt <> ": ")
}

/// Prompt user for secret input (masked/hidden)
pub fn ask_secret(prompt: String) -> Result(String, String) {
  get_password(prompt <> ": ")
}

/// Prompt user to choose from numbered options. Returns 1-based index.
pub fn choose(prompt: String, options: List(String)) -> Result(Int, String) {
  logging.log(logging.Info, prompt)
  list.index_map(options, fn(opt, i) {
    logging.log(logging.Info, "  " <> int.to_string(i + 1) <> ". " <> opt)
  })

  use input <- result.try(get_line("> "))
  let trimmed = string.trim(input)
  case int.parse(trimmed) {
    Ok(n) -> {
      case bool.and(n >= 1, n <= list.length(options)) {
        True -> Ok(n)
        False -> Error("Invalid choice: " <> trimmed)
      }
    }
    Error(_) -> Error("Not a number: " <> trimmed)
  }
}

/// Set file permissions (used for .env 600)
pub fn set_file_permissions(path: String, mode: Int) -> Nil {
  set_permissions(path, mode)
}

@external(erlang, "aura_io_ffi", "get_line")
fn get_line(prompt: String) -> Result(String, String)

@external(erlang, "aura_io_ffi", "get_password")
fn get_password(prompt: String) -> Result(String, String)

@external(erlang, "aura_io_ffi", "set_permissions")
fn set_permissions(path: String, mode: Int) -> Nil
