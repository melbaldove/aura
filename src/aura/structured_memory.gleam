import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

const memory_char_limit = 2200

const user_char_limit = 1375

/// A keyed entry in a memory file.
pub type Entry {
  Entry(key: String, content: String)
}

/// Parse a keyed memory file into a list of entries.
/// Format: `§ key\ncontent\n` blocks. Content before the first `§` is ignored.
pub fn read_entries(path: String) -> Result(List(Entry), String) {
  case simplifile.read(path) {
    Error(_) -> Ok([])
    Ok(raw) -> Ok(parse_entries(raw))
  }
}

fn parse_entries(raw: String) -> List(Entry) {
  let lines = string.split(raw, "\n")
  parse_lines(lines, None, [], [])
}

fn parse_lines(
  lines: List(String),
  current_key: Option(String),
  current_lines: List(String),
  acc: List(Entry),
) -> List(Entry) {
  case lines {
    [] -> list.reverse(finalize_entry(current_key, current_lines, acc))
    [line, ..rest] -> {
      case string.starts_with(line, "§ ") {
        True -> {
          let new_key = string.trim(string.drop_start(line, 2))
          let new_acc = finalize_entry(current_key, current_lines, acc)
          parse_lines(rest, Some(new_key), [], new_acc)
        }
        // Prepend (O(1)) instead of append (O(n)), reverse in finalize
        False -> parse_lines(rest, current_key, [line, ..current_lines], acc)
      }
    }
  }
}

fn finalize_entry(
  key: Option(String),
  lines: List(String),
  acc: List(Entry),
) -> List(Entry) {
  case key {
    None -> acc
    Some(k) -> {
      let content = string.trim(string.join(list.reverse(lines), "\n"))
      case content {
        "" -> acc
        // Prepend to acc (reversed at the end of parse_lines)
        _ -> [Entry(key: k, content: content), ..acc]
      }
    }
  }
}

/// Upsert an entry by key. Creates if new, replaces if exists.
/// Scans for security threats and enforces char limits.
pub fn set(path: String, key: String, content: String) -> Result(Nil, String) {
  use _ <- result.try(security_scan(content))
  use entries <- result.try(read_entries(path))
  let exists = list.any(entries, fn(e) { e.key == key })
  let updated = case exists {
    True -> list.map(entries, fn(e) {
      case e.key == key {
        True -> Entry(key: key, content: content)
        False -> e
      }
    })
    False -> list.append(entries, [Entry(key: key, content: content)])
  }
  let limit = char_limit_for_path(path)
  use _ <- result.try(check_char_limit(updated, limit))
  write_entries(path, updated)
}

/// Remove an entry by key.
pub fn remove(path: String, key: String) -> Result(Nil, String) {
  use entries <- result.try(read_entries(path))
  let filtered = list.filter(entries, fn(e) { e.key != key })
  case list.length(filtered) == list.length(entries) {
    True -> {
      let keys = list.map(entries, fn(e) { e.key })
      Error("No entry with key '" <> key <> "'. Existing keys: " <> string.join(keys, ", "))
    }
    False -> write_entries(path, filtered)
  }
}

/// Format all entries for display (used in system prompt).
pub fn format_for_display(path: String) -> Result(String, String) {
  use entries <- result.try(read_entries(path))
  case entries {
    [] -> Ok("(empty)")
    _ -> Ok(string.join(list.map(entries, fn(e) {
      "**" <> e.key <> ":** " <> e.content
    }), "\n"))
  }
}

/// Format entries as a dict for structured access.
pub fn read_as_dict(path: String) -> Result(Dict(String, String), String) {
  use entries <- result.try(read_entries(path))
  Ok(dict.from_list(list.map(entries, fn(e) { #(e.key, e.content) })))
}

fn write_entries(path: String, entries: List(Entry)) -> Result(Nil, String) {
  let content = string.join(list.map(entries, fn(e) {
    "§ " <> e.key <> "\n" <> e.content
  }), "\n\n") <> "\n"
  simplifile.write(path, content)
  |> result.map_error(fn(e) {
    "Failed to write memory file: " <> string.inspect(e)
  })
}

fn char_limit_for_path(path: String) -> Int {
  case string.contains(path, "USER") {
    True -> user_char_limit
    False -> memory_char_limit
  }
}

fn check_char_limit(
  entries: List(Entry),
  limit: Int,
) -> Result(Nil, String) {
  let total =
    list.fold(entries, 0, fn(acc, e) { acc + string.length(e.key) + string.length(e.content) })
  case total > limit {
    True ->
      Error(
        "Memory limit exceeded ("
        <> string.inspect(total)
        <> "/"
        <> string.inspect(limit)
        <> " chars). Remove old entries first.",
      )
    False -> Ok(Nil)
  }
}

/// Security scan — blocks prompt injection and exfiltration patterns.
fn security_scan(content: String) -> Result(Nil, String) {
  let lower = string.lowercase(content)
  let threats = [
    "ignore previous instructions",
    "ignore all instructions",
    "ignore above instructions",
    "ignore prior instructions",
    "you are now ",
    "do not tell the user",
    "system prompt override",
    "disregard your instructions",
    "disregard your rules",
    "disregard your guidelines",
    "disregard all instructions",
    "disregard any rules",
    "act as if you have no restrictions",
    "act as though you have no limits",
    "act as if you don't have rules",
  ]
  let exfil_patterns = [
    "curl ",
    "wget ",
    "$key",
    "$token",
    "$secret",
    "$password",
    "$credential",
    "$api",
    ".env",
    ".netrc",
    ".pgpass",
    ".npmrc",
    ".pypirc",
    ".ssh/",
    "authorized_keys",
    "credentials",
  ]
  let all_patterns = list.append(threats, exfil_patterns)
  case list.find(all_patterns, fn(p) { string.contains(lower, p) }) {
    Ok(matched) ->
      Error("Security scan failed: blocked pattern '" <> matched <> "'")
    Error(_) -> Ok(Nil)
  }
}
