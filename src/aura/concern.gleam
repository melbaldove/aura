import aura/structured_memory
import aura/time
import aura/xdg
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// A request to track a durable object of care, work, watch, or risk.
pub type TrackRequest {
  TrackRequest(
    action: String,
    slug: String,
    title: String,
    summary: String,
    why: String,
    current_state: String,
    watch_signals: String,
    evidence: String,
    authority: String,
    gaps: String,
    note: String,
  )
}

/// Result of applying a track request to the concern text store.
pub type TrackResult {
  TrackResult(
    path: String,
    source_ref: String,
    status: String,
    action: String,
    title: String,
  )
}

/// Apply a track request by writing an ordinary markdown concern file.
pub fn apply(
  paths: xdg.Paths,
  request: TrackRequest,
) -> Result(TrackResult, String) {
  let action = string.lowercase(string.trim(request.action))
  let slug = string.lowercase(string.trim(request.slug))
  use _ <- result.try(validate_action(action))
  use _ <- result.try(validate_slug(slug))

  let dir = xdg.concerns_dir(paths)
  let path = dir <> "/" <> slug <> ".md"
  let now = time.now_ms()
  let status = status_for_action(action)
  let title = title_for(request, slug)

  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(e) {
      "Failed to create concerns directory " <> dir <> ": " <> string.inspect(e)
    }),
  )

  let existing = simplifile.is_file(path) == Ok(True)
  let content_result = case action {
    "start" -> {
      case existing {
        True -> {
          use content <- result.try(read_existing(path, slug))
          Ok(update_existing(content, status, now, action, request))
        }
        False -> Ok(initial_content(request, slug, title, status, now))
      }
    }
    _ -> {
      use content <- result.try(read_existing(path, slug))
      Ok(update_existing(content, status, now, action, request))
    }
  }

  use content <- result.try(content_result)
  use _ <- result.try(structured_memory.security_scan(content))
  use _ <- result.try(
    simplifile.write(path, content)
    |> result.map_error(fn(e) {
      "Failed to write concern file " <> path <> ": " <> string.inspect(e)
    }),
  )

  Ok(TrackResult(
    path: path,
    source_ref: "concerns/" <> slug <> ".md",
    status: status,
    action: action,
    title: title,
  ))
}

fn validate_action(action: String) -> Result(Nil, String) {
  case action {
    "start" | "update" | "pause" | "close" -> Ok(Nil)
    _ ->
      Error(
        "Error: invalid track action '"
        <> action
        <> "'. Use start, update, pause, or close.",
      )
  }
}

fn validate_slug(slug: String) -> Result(Nil, String) {
  let chars = string.to_graphemes(slug)
  let valid_chars = list.all(chars, allowed_slug_char)

  case slug == "" || string.length(slug) > 80 || !valid_chars {
    True ->
      Error(
        "Error: invalid slug '"
        <> slug
        <> "'. Use 1-80 lowercase letters, digits, and hyphens only.",
      )
    False -> {
      case
        string.starts_with(slug, "-")
        || string.ends_with(slug, "-")
        || string.contains(slug, "--")
      {
        True ->
          Error(
            "Error: invalid slug '"
            <> slug
            <> "'. Do not start, end, or repeat hyphens.",
          )
        False -> Ok(Nil)
      }
    }
  }
}

fn allowed_slug_char(char: String) -> Bool {
  list.contains(
    [
      "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
      "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "0", "1", "2", "3",
      "4", "5", "6", "7", "8", "9", "-",
    ],
    char,
  )
}

fn status_for_action(action: String) -> String {
  case action {
    "pause" -> "paused"
    "close" -> "closed"
    _ -> "active"
  }
}

fn title_for(request: TrackRequest, slug: String) -> String {
  first_present([request.title, request.summary, slug])
}

fn initial_content(
  request: TrackRequest,
  slug: String,
  title: String,
  status: String,
  now: Int,
) -> String {
  "# "
  <> title
  <> "\n\nStatus: "
  <> status
  <> "\nSlug: "
  <> slug
  <> "\nUpdated: "
  <> int.to_string(now)
  <> "\n\n## Summary\n"
  <> section_text(request.summary, "Not specified.")
  <> "\n\n## Why This Matters\n"
  <> section_text(request.why, "Not specified.")
  <> "\n\n## Current State\n"
  <> section_text(request.current_state, "Not specified.")
  <> "\n\n## Watch Signals\n"
  <> section_text(request.watch_signals, "None specified.")
  <> "\n\n## Links And Evidence\n"
  <> section_text(request.evidence, "None specified.")
  <> "\n\n## Authority And Preferences\n"
  <> section_text(request.authority, "None specified.")
  <> "\n\n## Open Gaps\n"
  <> section_text(request.gaps, "None specified.")
  <> "\n\n## Recent Notes\n"
  <> note_line(now, "start", note_text(request, "start"))
  <> "\n"
}

fn update_existing(
  content: String,
  status: String,
  now: Int,
  action: String,
  request: TrackRequest,
) -> String {
  content
  |> set_line("Status: ", "Status: " <> status)
  |> set_line("Updated: ", "Updated: " <> int.to_string(now))
  |> append_note(now, action, note_text(request, action))
}

fn set_line(content: String, prefix: String, replacement: String) -> String {
  let lines = string.split(content, "\n")
  let found = list.any(lines, fn(line) { string.starts_with(line, prefix) })
  let updated =
    lines
    |> list.map(fn(line) {
      case string.starts_with(line, prefix) {
        True -> replacement
        False -> line
      }
    })

  case found {
    True -> string.join(updated, "\n")
    False -> replacement <> "\n" <> content
  }
}

fn append_note(
  content: String,
  now: Int,
  action: String,
  note: String,
) -> String {
  let line = note_line(now, action, note)
  case string.contains(content, "## Recent Notes") {
    True -> string.trim_end(content) <> "\n" <> line <> "\n"
    False -> string.trim_end(content) <> "\n\n## Recent Notes\n" <> line <> "\n"
  }
}

fn note_line(now: Int, action: String, note: String) -> String {
  "- " <> int.to_string(now) <> " [" <> action <> "] " <> one_line(note)
}

fn note_text(request: TrackRequest, action: String) -> String {
  first_present([
    request.note,
    request.current_state,
    request.summary,
    "Tracking " <> action <> ".",
  ])
}

fn first_present(values: List(String)) -> String {
  case values {
    [] -> ""
    [value, ..rest] -> {
      case string.trim(value) {
        "" -> first_present(rest)
        trimmed -> trimmed
      }
    }
  }
}

fn section_text(value: String, fallback: String) -> String {
  case string.trim(value) {
    "" -> fallback
    trimmed -> trimmed
  }
}

fn one_line(value: String) -> String {
  value
  |> string.trim
  |> string.replace(each: "\n", with: " ")
  |> string.replace(each: "\r", with: " ")
}

fn read_existing(path: String, slug: String) -> Result(String, String) {
  case simplifile.read(path) {
    Ok(content) -> Ok(content)
    Error(simplifile.Enoent) ->
      Error(
        "Error: tracking target not found for slug '"
        <> slug
        <> "'. Use action=start first.",
      )
    Error(e) ->
      Error("Failed to read concern file " <> path <> ": " <> string.inspect(e))
  }
}
