import aura/db
import aura/time
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import simplifile

/// A keyed entry in a memory file.
pub type Entry {
  Entry(key: String, content: String)
}

/// Structured result describing how a memory archive write affected lineage.
pub type ArchiveWriteResult {
  ArchiveNew(new_id: Int, content_chars: Int)
  ArchiveChanged(
    previous_id: Int,
    new_id: Int,
    previous_chars: Int,
    content_chars: Int,
  )
  ArchiveNoop(previous_id: Option(Int), content_chars: Int)
  ArchiveRemoved(previous_id: Int)
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

/// Upsert an entry in a list by key. Creates if new, replaces if exists.
/// Returns a tuple of (existed_already, updated_list).
fn upsert_entries(
  entries: List(Entry),
  key: String,
  content: String,
) -> #(Bool, List(Entry)) {
  let exists = list.any(entries, fn(e) { e.key == key })
  let updated = case exists {
    True ->
      list.map(entries, fn(e) {
        case e.key == key {
          True -> Entry(key: key, content: content)
          False -> e
        }
      })
    False -> list.append(entries, [Entry(key: key, content: content)])
  }
  #(exists, updated)
}

/// Upsert an entry by key. Creates if new, replaces if exists.
/// Scans for security threats before writing.
pub fn set(path: String, key: String, content: String) -> Result(Nil, String) {
  use _ <- result.try(security_scan(content))
  use entries <- result.try(read_entries(path))
  let #(_, updated) = upsert_entries(entries, key, content)
  write_entries(path, updated)
}

/// Upsert an entry by key with write-through to the SQLite archive.
/// Does everything `set` does, plus inserts the new entry into the archive
/// and supersedes the old one if it was an update. Archive writes are
/// best-effort — flat file is source of truth during normal operation.
pub fn set_with_archive(
  path: String,
  key: String,
  content: String,
  db_subject: process.Subject(db.DbMessage),
  domain: String,
  target: String,
) -> Result(Nil, String) {
  set_with_archive_checked(path, key, content, db_subject, domain, target)
  |> result.map(fn(_) { Nil })
}

/// Upsert an entry and return the exact archive effect that occurred.
pub fn set_with_archive_checked(
  path: String,
  key: String,
  content: String,
  db_subject: process.Subject(db.DbMessage),
  domain: String,
  target: String,
) -> Result(ArchiveWriteResult, String) {
  use _ <- result.try(security_scan(content))
  use entries <- result.try(read_entries(path))
  let previous_file_entry = find_entry(entries, key)
  let previous_db_entry =
    db.get_active_memory_entry_by_key(db_subject, domain, target, key)
  let previous_id = case previous_db_entry {
    Ok(Some(entry)) -> Some(entry.id)
    _ -> None
  }

  case previous_file_entry {
    Some(entry) if entry.content == content ->
      Ok(ArchiveNoop(previous_id, string.length(content)))
    _ ->
      write_changed_archive_entry(
        path,
        entries,
        key,
        content,
        db_subject,
        domain,
        target,
        previous_file_entry,
        previous_id,
      )
  }
}

fn write_changed_archive_entry(
  path: String,
  entries: List(Entry),
  key: String,
  content: String,
  db_subject: process.Subject(db.DbMessage),
  domain: String,
  target: String,
  previous_file_entry: Option(Entry),
  previous_id: Option(Int),
) -> Result(ArchiveWriteResult, String) {
  let #(exists, updated) = upsert_entries(entries, key, content)
  use _ <- result.try(write_entries(path, updated))

  // Write-through to SQLite archive (best-effort)
  let now = time.now_ms()
  case db.insert_memory_entry(db_subject, domain, target, key, content, now) {
    Ok(new_id) -> {
      // If the key already existed, supersede the old archive entry
      let archived_previous_id = case previous_id {
        Some(id) -> Some(id)
        None ->
          case exists {
            True ->
              case
                db.get_active_entry_id(db_subject, domain, target, key, new_id)
              {
                Ok(old_id) -> Some(old_id)
                Error(_) -> None
              }
            False -> None
          }
      }

      case archived_previous_id {
        Some(old_id) -> {
          case db.supersede_memory_entry(db_subject, old_id, new_id, now) {
            Ok(Nil) -> Nil
            Error(err) ->
              logging.log(
                logging.Error,
                "[memory] Archive supersede failed: " <> err,
              )
          }
          Ok(ArchiveChanged(
            previous_id: old_id,
            new_id: new_id,
            previous_chars: previous_chars(previous_file_entry),
            content_chars: string.length(content),
          ))
        }
        None ->
          Ok(ArchiveNew(new_id: new_id, content_chars: string.length(content)))
      }
    }
    Error(err) -> {
      logging.log(logging.Error, "[memory] Archive insert failed: " <> err)
      Ok(ArchiveNoop(previous_id, string.length(content)))
    }
  }
}

/// Remove an entry by key with write-through to the SQLite archive.
/// Does everything `remove` does, plus supersedes the active archive entry.
/// Archive writes are best-effort — flat file is source of truth.
pub fn remove_with_archive(
  path: String,
  key: String,
  db_subject: process.Subject(db.DbMessage),
  domain: String,
  target: String,
) -> Result(Nil, String) {
  remove_with_archive_checked(path, key, db_subject, domain, target)
  |> result.map(fn(_) { Nil })
}

/// Remove an entry and return the exact archive effect that occurred.
pub fn remove_with_archive_checked(
  path: String,
  key: String,
  db_subject: process.Subject(db.DbMessage),
  domain: String,
  target: String,
) -> Result(ArchiveWriteResult, String) {
  use entries <- result.try(read_entries(path))
  let filtered = list.filter(entries, fn(e) { e.key != key })
  case list.length(filtered) == list.length(entries) {
    True -> {
      let keys = list.map(entries, fn(e) { e.key })
      Error(
        "No entry with key '"
        <> key
        <> "'. Existing keys: "
        <> string.join(keys, ", "),
      )
    }
    False -> {
      use _ <- result.try(write_entries(path, filtered))

      // Supersede the archive entry (best-effort)
      // Use superseded_by = 0 to indicate explicit removal (no replacement)
      let now = time.now_ms()
      case db.get_active_entry_id(db_subject, domain, target, key, 0) {
        Ok(old_id) -> {
          case db.supersede_memory_entry(db_subject, old_id, 0, now) {
            Ok(Nil) -> Nil
            Error(err) ->
              logging.log(
                logging.Error,
                "[memory] Archive supersede on remove failed: " <> err,
              )
          }
          Ok(ArchiveRemoved(previous_id: old_id))
        }
        Error(_) -> Ok(ArchiveRemoved(previous_id: 0))
      }
    }
  }
}

fn find_entry(entries: List(Entry), key: String) -> Option(Entry) {
  case list.find(entries, fn(entry) { entry.key == key }) {
    Ok(entry) -> Some(entry)
    Error(_) -> None
  }
}

fn previous_chars(entry: Option(Entry)) -> Int {
  case entry {
    Some(value) -> string.length(value.content)
    None -> 0
  }
}

/// Remove an entry by key.
pub fn remove(path: String, key: String) -> Result(Nil, String) {
  use entries <- result.try(read_entries(path))
  let filtered = list.filter(entries, fn(e) { e.key != key })
  case list.length(filtered) == list.length(entries) {
    True -> {
      let keys = list.map(entries, fn(e) { e.key })
      Error(
        "No entry with key '"
        <> key
        <> "'. Existing keys: "
        <> string.join(keys, ", "),
      )
    }
    False -> write_entries(path, filtered)
  }
}

/// Format all entries for display (used in system prompt).
pub fn format_for_display(path: String) -> Result(String, String) {
  use entries <- result.try(read_entries(path))
  case entries {
    [] -> Ok("(empty)")
    _ ->
      Ok(string.join(
        list.map(entries, fn(e) { "**" <> e.key <> ":** " <> e.content }),
        "\n",
      ))
  }
}

/// Format entries as a dict for structured access.
pub fn read_as_dict(path: String) -> Result(Dict(String, String), String) {
  use entries <- result.try(read_entries(path))
  Ok(dict.from_list(list.map(entries, fn(e) { #(e.key, e.content) })))
}

fn write_entries(path: String, entries: List(Entry)) -> Result(Nil, String) {
  let content =
    string.join(
      list.map(entries, fn(e) { "§ " <> e.key <> "\n" <> e.content }),
      "\n\n",
    )
    <> "\n"
  simplifile.write(path, content)
  |> result.map_error(fn(e) {
    "Failed to write memory file: " <> string.inspect(e)
  })
}

/// Security scan — blocks prompt injection and exfiltration patterns.
/// Public so that other modules (e.g., brain) can scan untrusted content
/// before persisting it where it may later flow into LLM prompts.
pub fn security_scan(content: String) -> Result(Nil, String) {
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
