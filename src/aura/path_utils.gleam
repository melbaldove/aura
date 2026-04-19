//// Small path helpers used by multiple modules.

import gleam/list
import gleam/string

/// Return the last segment of a `/`-separated path. If the last segment is
/// empty (trailing slash) or the path is empty, return `fallback`.
pub fn basename_or(path: String, fallback: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok("") -> fallback
    Ok(name) -> name
    Error(_) -> fallback
  }
}
