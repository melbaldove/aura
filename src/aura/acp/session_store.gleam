import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import simplifile

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type StoredSession {
  StoredSession(
    session_name: String,
    domain: String,
    task_id: String,
    thread_id: String,
    started_at_ms: Int,
    state: String,
    prompt: String,
    cwd: String,
  )
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Load all sessions from disk. Returns empty list if file missing or corrupt.
pub fn load(path: String) -> List(StoredSession) {
  case simplifile.read(path) {
    Error(_) -> []
    Ok(content) -> {
      case string.trim(content) {
        "" -> []
        trimmed ->
          case json.parse(trimmed, decode.list(session_decoder())) {
            Ok(sessions) -> sessions
            Error(_) -> []
          }
      }
    }
  }
}

/// Save all sessions to disk.
pub fn save(
  path: String,
  sessions: List(StoredSession),
) -> Result(Nil, String) {
  let content =
    json.array(sessions, session_to_json)
    |> json.to_string
  case simplifile.write(path, content) {
    Ok(_) -> Ok(Nil)
    Error(e) -> Error("Failed to write session store: " <> string.inspect(e))
  }
}

/// Add or update a session by name. Read-modify-write pattern.
pub fn upsert(
  path: String,
  session: StoredSession,
) -> Result(Nil, String) {
  let existing = load(path)
  let filtered =
    list.filter(existing, fn(s) { s.session_name != session.session_name })
  let updated = [session, ..filtered]
  save(path, updated)
}

/// Remove a session by name from the store.
pub fn remove(
  path: String,
  session_name: String,
) -> Result(Nil, String) {
  let existing = load(path)
  let filtered =
    list.filter(existing, fn(s) { s.session_name != session_name })
  save(path, filtered)
}

// ---------------------------------------------------------------------------
// JSON encoding
// ---------------------------------------------------------------------------

pub fn session_to_json(session: StoredSession) -> json.Json {
  json.object([
    #("session_name", json.string(session.session_name)),
    #("domain", json.string(session.domain)),
    #("task_id", json.string(session.task_id)),
    #("thread_id", json.string(session.thread_id)),
    #("started_at_ms", json.int(session.started_at_ms)),
    #("state", json.string(session.state)),
    #("prompt", json.string(session.prompt)),
    #("cwd", json.string(session.cwd)),
  ])
}

// ---------------------------------------------------------------------------
// JSON decoding
// ---------------------------------------------------------------------------

pub fn session_decoder() -> decode.Decoder(StoredSession) {
  use session_name <- decode.field("session_name", decode.string)
  use domain <- decode.field("domain", decode.string)
  use task_id <- decode.field("task_id", decode.string)
  use thread_id <- decode.field("thread_id", decode.string)
  use started_at_ms <- decode.field("started_at_ms", decode.int)
  use state <- decode.field("state", decode.string)
  use prompt <- decode.field("prompt", decode.string)
  use cwd <- decode.field("cwd", decode.string)
  decode.success(StoredSession(
    session_name: session_name,
    domain: domain,
    task_id: task_id,
    thread_id: thread_id,
    started_at_ms: started_at_ms,
    state: state,
    prompt: prompt,
    cwd: cwd,
  ))
}

/// Check whether a state string represents a terminal state.
pub fn is_terminal(state: String) -> Bool {
  case state {
    "complete" -> True
    "timed_out" -> True
    _ -> string.starts_with(state, "failed")
  }
}
