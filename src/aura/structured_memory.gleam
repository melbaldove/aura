import gleam/list
import gleam/result
import gleam/string
import simplifile

const delimiter = "\n---\n"

/// Read all entries from a memory file. Returns empty list if file doesn't exist.
pub fn read_entries(path: String) -> Result(List(String), String) {
  case simplifile.read(path) {
    Error(_) -> Ok([])
    Ok(content) -> {
      let trimmed = string.trim(content)
      case trimmed {
        "" -> Ok([])
        _ -> {
          let entries =
            string.split(trimmed, "---")
            |> list.map(string.trim)
            |> list.filter(fn(e) { e != "" })
          Ok(entries)
        }
      }
    }
  }
}

/// Add an entry to a memory file. Scans for security threats first.
pub fn add(path: String, content: String) -> Result(Nil, String) {
  use _ <- result.try(security_scan(content))
  use entries <- result.try(read_entries(path))
  let new_entries = list.append(entries, [content])
  write_entries(path, new_entries)
}

/// Remove an entry that contains the given substring.
pub fn remove(path: String, substring: String) -> Result(Nil, String) {
  use entries <- result.try(read_entries(path))
  let filtered = list.filter(entries, fn(e) { !string.contains(e, substring) })
  case list.length(filtered) == list.length(entries) {
    True -> Error("No entry found containing: " <> substring)
    False -> write_entries(path, filtered)
  }
}

/// Replace an entry containing old_text with new content.
pub fn replace(
  path: String,
  old_text: String,
  new_content: String,
) -> Result(Nil, String) {
  use _ <- result.try(security_scan(new_content))
  use entries <- result.try(read_entries(path))
  let updated =
    list.map(entries, fn(e) {
      case string.contains(e, old_text) {
        True -> new_content
        False -> e
      }
    })
  case updated == entries {
    True -> Error("No entry found containing: " <> old_text)
    False -> write_entries(path, updated)
  }
}

/// Format all entries for display.
pub fn format_for_display(path: String) -> Result(String, String) {
  use entries <- result.try(read_entries(path))
  case entries {
    [] -> Ok("(empty)")
    _ -> Ok(string.join(entries, "\n- "))
  }
}

fn write_entries(path: String, entries: List(String)) -> Result(Nil, String) {
  let content = string.join(entries, delimiter) <> "\n"
  simplifile.write(path, content)
  |> result.map_error(fn(e) {
    "Failed to write memory file: " <> string.inspect(e)
  })
}

/// Security scan — blocks prompt injection and exfiltration patterns.
fn security_scan(content: String) -> Result(Nil, String) {
  let lower = string.lowercase(content)
  let threats = [
    "ignore previous instructions",
    "ignore all instructions",
    "you are now",
    "do not tell",
    "disregard",
    "forget everything",
    "reveal your prompt",
    "system prompt",
  ]
  let exfil_patterns = [
    "curl ",
    "wget ",
    "$token",
    "$password",
    "$secret",
    "$api_key",
    ".env",
    ".ssh/",
    "authorized_keys",
  ]
  let all_patterns = list.append(threats, exfil_patterns)
  case list.find(all_patterns, fn(p) { string.contains(lower, p) }) {
    Ok(matched) ->
      Error("Security scan failed: blocked pattern '" <> matched <> "'")
    Error(_) -> Ok(Nil)
  }
}
