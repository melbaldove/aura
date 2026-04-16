import aura/db_schema
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/otp/actor
import gleam/result
import gleam/string
import sqlight

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A message row as loaded from the database.
/// `created_at` is milliseconds since epoch; `tool_calls` and `tool_call_id`
/// are JSON strings, empty string when absent.
pub type StoredMessage {
  StoredMessage(
    id: Int,
    conversation_id: String,
    role: String,
    content: String,
    author_id: String,
    author_name: String,
    tool_call_id: String,
    tool_calls: String,
    tool_name: String,
    created_at: Int,
  )
}

/// A single FTS5 search hit. `snippet` contains the matched excerpt with
/// `>>>` / `<<<` highlights; `content` is the full message body.
pub type SearchResult {
  SearchResult(
    conversation_id: String,
    role: String,
    snippet: String,
    content: String,
    author_name: String,
    created_at: Int,
    platform: String,
    platform_id: String,
  )
}

pub type StoredFlare {
  StoredFlare(
    id: String,
    label: String,
    status: String,
    domain: String,
    thread_id: String,
    original_prompt: String,
    execution: String,
    triggers: String,
    tools: String,
    workspace: String,
    session_id: String,
    created_at_ms: Int,
    updated_at_ms: Int,
  )
}

/// A memory entry row from the memory_entries table.
/// Represents a keyed piece of knowledge with optional supersession chain.
pub type MemoryEntry {
  MemoryEntry(
    id: Int,
    domain: String,
    target: String,
    key: String,
    content: String,
    created_at_ms: Int,
  )
}

/// Internal actor message type for the DB actor.
/// Callers should use the public convenience functions (`append_message`,
/// `load_messages`, etc.) rather than sending these variants directly.
pub type DbMessage {
  Shutdown
  ResolveConversation(
    reply_to: process.Subject(Result(String, String)),
    platform: String,
    platform_id: String,
    timestamp: Int,
  )
  AppendMessage(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    role: String,
    content: String,
    author_id: String,
    author_name: String,
    timestamp: Int,
  )
  LoadMessages(
    reply_to: process.Subject(Result(List(StoredMessage), String)),
    conversation_id: String,
    limit: Int,
  )
  Search(
    reply_to: process.Subject(Result(List(SearchResult), String)),
    query: String,
    limit: Int,
  )
  UpdateCompactionSummary(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    summary: String,
  )
  UpdateLastActive(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    timestamp: Int,
  )
  SetDomain(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    domain: String,
  )
  GetCompactionSummary(
    reply_to: process.Subject(Result(String, String)),
    conversation_id: String,
  )
  HasMessages(
    reply_to: process.Subject(Result(Bool, String)),
  )
  AppendMessageFull(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    role: String,
    content: String,
    author_id: String,
    author_name: String,
    tool_call_id: String,
    tool_calls: String,
    timestamp: Int,
  )
  UpsertFlare(
    reply_to: process.Subject(Result(Nil, String)),
    stored: StoredFlare,
  )
  LoadFlares(
    reply_to: process.Subject(Result(List(StoredFlare), String)),
    exclude_archived: Bool,
  )
  UpdateFlareStatus(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    status: String,
    updated_at_ms: Int,
  )
  UpdateFlareSessionId(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    session_id: String,
    updated_at_ms: Int,
  )
  UpdateFlareRekindle(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    session_id: String,
    status: String,
    updated_at_ms: Int,
  )
  InsertMemoryEntry(
    reply_to: process.Subject(Result(Int, String)),
    domain: String,
    target: String,
    key: String,
    content: String,
    created_at_ms: Int,
  )
  SupersedeMemoryEntry(
    reply_to: process.Subject(Result(Nil, String)),
    entry_id: Int,
    superseded_by: Int,
    superseded_at_ms: Int,
  )
  GetActiveMemoryEntries(
    reply_to: process.Subject(Result(List(MemoryEntry), String)),
    domain: String,
    target: String,
  )
  GetActiveEntryId(
    reply_to: process.Subject(Result(Int, String)),
    domain: String,
    target: String,
    key: String,
    exclude_id: Int,
  )
}

type DbState {
  DbState(conn: sqlight.Connection)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Open (or create) the SQLite database at `path`, initialize the schema,
/// and return a subject for sending `DbMessage` requests to the actor.
pub fn start(
  path: String,
) -> Result(process.Subject(DbMessage), String) {
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      case sqlight.open(path) {
        Ok(conn) -> {
          case db_schema.initialize(conn) {
            Ok(Nil) -> {
              let state = DbState(conn: conn)
              Ok(actor.initialised(state) |> actor.returning(subject))
            }
            Error(err) -> Error("Failed to initialize schema: " <> err)
          }
        }
        Error(err) ->
          Error("Failed to open database: " <> string.inspect(err))
      }
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(err) ->
      Error("Failed to start db actor: " <> string.inspect(err))
  }
}

/// Look up a conversation by `(platform, platform_id)`, creating one if it
/// does not yet exist. Returns the conversation's string ID.
pub fn resolve_conversation(
  subject: process.Subject(DbMessage),
  platform: String,
  platform_id: String,
  timestamp: Int,
) -> Result(String, String) {
  process.call(subject, 5000, fn(reply_to) {
    ResolveConversation(
      reply_to: reply_to,
      platform: platform,
      platform_id: platform_id,
      timestamp: timestamp,
    )
  })
}

/// Append a new message row to an existing conversation.
pub fn append_message(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  role: String,
  content: String,
  author_id: String,
  author_name: String,
  timestamp: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    AppendMessage(
      reply_to: reply_to,
      conversation_id: conversation_id,
      role: role,
      content: content,
      author_id: author_id,
      author_name: author_name,
      timestamp: timestamp,
    )
  })
}

/// Load the most recent `limit` messages for a conversation, ordered oldest first.
pub fn load_messages(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  limit: Int,
) -> Result(List(StoredMessage), String) {
  process.call(subject, 5000, fn(reply_to) {
    LoadMessages(
      reply_to: reply_to,
      conversation_id: conversation_id,
      limit: limit,
    )
  })
}

/// Full-text search across all messages using FTS5. Returns up to `limit`
/// results ranked by relevance, with highlighted snippets.
pub fn search(
  subject: process.Subject(DbMessage),
  query: String,
  limit: Int,
) -> Result(List(SearchResult), String) {
  process.call(subject, 5000, fn(reply_to) {
    Search(reply_to: reply_to, query: query, limit: limit)
  })
}

/// Store a compaction summary for a conversation, replacing any prior value.
pub fn update_compaction_summary(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  summary: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateCompactionSummary(
      reply_to: reply_to,
      conversation_id: conversation_id,
      summary: summary,
    )
  })
}

/// Get the compaction summary for a conversation.
pub fn get_compaction_summary(
  subject: process.Subject(DbMessage),
  conversation_id: String,
) -> Result(String, String) {
  process.call(subject, 5000, fn(reply_to) {
    GetCompactionSummary(
      reply_to: reply_to,
      conversation_id: conversation_id,
    )
  })
}

/// Update the `last_active_at` timestamp (ms since epoch) for a conversation.
pub fn update_last_active(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  timestamp: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateLastActive(
      reply_to: reply_to,
      conversation_id: conversation_id,
      timestamp: timestamp,
    )
  })
}

/// Assign a domain label to a conversation.
pub fn set_domain(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  domain: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    SetDomain(
      reply_to: reply_to,
      conversation_id: conversation_id,
      domain: domain,
    )
  })
}

/// Append a message with full tool call metadata (tool_call_id, tool_calls JSON).
/// Used when persisting the complete tool call chain.
pub fn append_message_full(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  role: String,
  content: String,
  author_id: String,
  author_name: String,
  tool_call_id: String,
  tool_calls: String,
  timestamp: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    AppendMessageFull(
      reply_to: reply_to,
      conversation_id: conversation_id,
      role: role,
      content: content,
      author_id: author_id,
      author_name: author_name,
      tool_call_id: tool_call_id,
      tool_calls: tool_calls,
      timestamp: timestamp,
    )
  })
}

/// Check if the database has any messages at all.
/// Used by migration to avoid double-importing JSONL files.
pub fn has_messages(
  subject: process.Subject(DbMessage),
) -> Result(Bool, String) {
  process.call(subject, 5000, fn(reply_to) {
    HasMessages(reply_to: reply_to)
  })
}

/// Insert or replace a flare record.
pub fn upsert_flare(
  subject: process.Subject(DbMessage),
  stored: StoredFlare,
) -> Result(Nil, String) {
  process.call(subject, 10_000, fn(reply_to) {
    UpsertFlare(reply_to:, stored:)
  })
}

/// Load all flares, optionally excluding archived ones.
pub fn load_flares(
  subject: process.Subject(DbMessage),
  exclude_archived: Bool,
) -> Result(List(StoredFlare), String) {
  process.call(subject, 10_000, fn(reply_to) {
    LoadFlares(reply_to:, exclude_archived:)
  })
}

/// Update the status of a flare.
pub fn update_flare_status(
  subject: process.Subject(DbMessage),
  id: String,
  status: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateFlareStatus(reply_to:, id:, status:, updated_at_ms:)
  })
}

/// Update the session_id of a flare.
pub fn update_flare_session_id(
  subject: process.Subject(DbMessage),
  id: String,
  session_id: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateFlareSessionId(reply_to:, id:, session_id:, updated_at_ms:)
  })
}

/// Atomically update a flare's session_id and status (used by rekindle).
pub fn update_flare_rekindle(
  subject: process.Subject(DbMessage),
  id: String,
  session_id: String,
  status: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateFlareRekindle(reply_to:, id:, session_id:, status:, updated_at_ms:)
  })
}

/// Insert a new memory entry and return its auto-generated id.
pub fn insert_memory_entry(
  subject: process.Subject(DbMessage),
  domain: String,
  target: String,
  key: String,
  content: String,
  created_at_ms: Int,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    InsertMemoryEntry(reply_to:, domain:, target:, key:, content:, created_at_ms:)
  })
}

/// Mark a memory entry as superseded by another entry.
/// Only updates if the entry has not already been superseded (idempotent).
pub fn supersede_memory_entry(
  subject: process.Subject(DbMessage),
  entry_id: Int,
  superseded_by: Int,
  superseded_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    SupersedeMemoryEntry(reply_to:, entry_id:, superseded_by:, superseded_at_ms:)
  })
}

/// Return all active (non-superseded) memory entries for a domain and target.
pub fn get_active_memory_entries(
  subject: process.Subject(DbMessage),
  domain: String,
  target: String,
) -> Result(List(MemoryEntry), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetActiveMemoryEntries(reply_to:, domain:, target:)
  })
}

/// Find the active entry matching domain/target/key, excluding a specific id.
/// Used during write-through to find the old entry to supersede after inserting
/// a new one. Returns Error if no matching entry is found.
pub fn get_active_entry_id(
  subject: process.Subject(DbMessage),
  domain: String,
  target: String,
  key: String,
  exclude_id: Int,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    GetActiveEntryId(reply_to:, domain:, target:, key:, exclude_id:)
  })
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: DbState,
  message: DbMessage,
) -> actor.Next(DbState, DbMessage) {
  case message {
    Shutdown -> {
      let _ = sqlight.close(state.conn)
      actor.stop()
    }

    ResolveConversation(reply_to:, platform:, platform_id:, timestamp:) -> {
      let result = do_resolve_conversation(state.conn, platform, platform_id, timestamp)
      process.send(reply_to, result)
      actor.continue(state)
    }

    AppendMessage(reply_to:, conversation_id:, role:, content:, author_id:, author_name:, timestamp:) -> {
      let result = do_append_message(state.conn, conversation_id, role, content, author_id, author_name, timestamp)
      process.send(reply_to, result)
      actor.continue(state)
    }

    LoadMessages(reply_to:, conversation_id:, limit:) -> {
      let result = do_load_messages(state.conn, conversation_id, limit)
      process.send(reply_to, result)
      actor.continue(state)
    }

    Search(reply_to:, query:, limit:) -> {
      let result = do_search(state.conn, query, limit)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateCompactionSummary(reply_to:, conversation_id:, summary:) -> {
      let result = do_update_compaction_summary(state.conn, conversation_id, summary)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetCompactionSummary(reply_to:, conversation_id:) -> {
      let result = do_get_compaction_summary(state.conn, conversation_id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateLastActive(reply_to:, conversation_id:, timestamp:) -> {
      let result = do_update_last_active(state.conn, conversation_id, timestamp)
      process.send(reply_to, result)
      actor.continue(state)
    }

    SetDomain(reply_to:, conversation_id:, domain:) -> {
      let result = do_set_domain(state.conn, conversation_id, domain)
      process.send(reply_to, result)
      actor.continue(state)
    }

    HasMessages(reply_to:) -> {
      let result = do_has_messages(state.conn)
      process.send(reply_to, result)
      actor.continue(state)
    }

    AppendMessageFull(reply_to:, conversation_id:, role:, content:, author_id:, author_name:, tool_call_id:, tool_calls:, timestamp:) -> {
      let result = do_append_message_full(state.conn, conversation_id, role, content, author_id, author_name, tool_call_id, tool_calls, timestamp)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpsertFlare(reply_to:, stored:) -> {
      let result = do_upsert_flare(state.conn, stored)
      process.send(reply_to, result)
      actor.continue(state)
    }

    LoadFlares(reply_to:, exclude_archived:) -> {
      let result = do_load_flares(state.conn, exclude_archived)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateFlareStatus(reply_to:, id:, status:, updated_at_ms:) -> {
      let result = do_update_flare_status(state.conn, id, status, updated_at_ms)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateFlareSessionId(reply_to:, id:, session_id:, updated_at_ms:) -> {
      let result = do_update_flare_session_id(state.conn, id, session_id, updated_at_ms)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateFlareRekindle(reply_to:, id:, session_id:, status:, updated_at_ms:) -> {
      let result = do_update_flare_rekindle(state.conn, id, session_id, status, updated_at_ms)
      process.send(reply_to, result)
      actor.continue(state)
    }

    InsertMemoryEntry(reply_to:, domain:, target:, key:, content:, created_at_ms:) -> {
      let result = do_insert_memory_entry(state.conn, domain, target, key, content, created_at_ms)
      process.send(reply_to, result)
      actor.continue(state)
    }

    SupersedeMemoryEntry(reply_to:, entry_id:, superseded_by:, superseded_at_ms:) -> {
      let result = do_supersede_memory_entry(state.conn, entry_id, superseded_by, superseded_at_ms)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetActiveMemoryEntries(reply_to:, domain:, target:) -> {
      let result = do_get_active_memory_entries(state.conn, domain, target)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetActiveEntryId(reply_to:, domain:, target:, key:, exclude_id:) -> {
      let result = do_get_active_entry_id(state.conn, domain, target, key, exclude_id)
      process.send(reply_to, result)
      actor.continue(state)
    }
  }
}

// ---------------------------------------------------------------------------
// Database operations
// ---------------------------------------------------------------------------

fn do_resolve_conversation(
  conn: sqlight.Connection,
  platform: String,
  platform_id: String,
  timestamp: Int,
) -> Result(String, String) {
  let id = platform <> ":" <> platform_id

  // Try to find existing conversation
  let select_result =
    sqlight.query(
      "SELECT id FROM conversations WHERE platform = ? AND platform_id = ?",
      on: conn,
      with: [sqlight.text(platform), sqlight.text(platform_id)],
      expecting: decode.at([0], decode.string),
    )

  case select_result {
    Ok([existing_id]) -> Ok(existing_id)
    Ok([]) -> {
      // Insert new conversation
      case
        sqlight.query(
          "INSERT INTO conversations (id, platform, platform_id, last_active_at) VALUES (?, ?, ?, ?)",
          on: conn,
          with: [
            sqlight.text(id),
            sqlight.text(platform),
            sqlight.text(platform_id),
            sqlight.int(timestamp),
          ],
          expecting: decode.success(Nil),
        )
      {
        Ok(_) -> Ok(id)
        Error(err) ->
          Error("Failed to insert conversation: " <> string.inspect(err))
      }
    }
    Ok(_) -> Ok(id)
    Error(err) ->
      Error("Failed to query conversation: " <> string.inspect(err))
  }
}

fn do_append_message(
  conn: sqlight.Connection,
  conversation_id: String,
  role: String,
  content: String,
  author_id: String,
  author_name: String,
  timestamp: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO messages (conversation_id, role, content, author_id, author_name, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(conversation_id),
      sqlight.text(role),
      sqlight.text(content),
      sqlight.text(author_id),
      sqlight.text(author_name),
      sqlight.int(timestamp),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to insert message: " <> string.inspect(err)
  })
}

fn do_append_message_full(
  conn: sqlight.Connection,
  conversation_id: String,
  role: String,
  content: String,
  author_id: String,
  author_name: String,
  tool_call_id: String,
  tool_calls: String,
  timestamp: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO messages (conversation_id, role, content, author_id, author_name, tool_call_id, tool_calls, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(conversation_id),
      sqlight.text(role),
      sqlight.text(content),
      sqlight.text(author_id),
      sqlight.text(author_name),
      sqlight.text(tool_call_id),
      sqlight.text(tool_calls),
      sqlight.int(timestamp),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to insert message: " <> string.inspect(err)
  })
}

fn do_load_messages(
  conn: sqlight.Connection,
  conversation_id: String,
  limit: Int,
) -> Result(List(StoredMessage), String) {
  sqlight.query(
    "SELECT id, conversation_id, role, COALESCE(content,''), COALESCE(author_id,''), COALESCE(author_name,''), COALESCE(tool_call_id,''), COALESCE(tool_calls,''), COALESCE(tool_name,''), created_at FROM (SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at DESC, seq DESC, id DESC LIMIT ?) ORDER BY created_at ASC, seq ASC, id ASC",
    on: conn,
    with: [sqlight.text(conversation_id), sqlight.int(limit)],
    expecting: stored_message_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to load messages: " <> string.inspect(err)
  })
}

fn do_search(
  conn: sqlight.Connection,
  query: String,
  limit: Int,
) -> Result(List(SearchResult), String) {
  // Sanitize FTS5 query: strip special chars, reject empty
  let cleaned = query
    |> string.replace("\"", "")
    |> string.replace("*", "")
    |> string.trim
  case cleaned {
    "" -> Ok([])
    _ -> {
  let safe_query = "\"" <> cleaned <> "\""

  sqlight.query(
    "SELECT m.conversation_id, m.role, snippet(messages_fts, 0, '>>>', '<<<', '...', 32) AS snippet, m.content, m.author_name, m.created_at, c.platform, c.platform_id FROM messages_fts AS fts JOIN messages AS m ON fts.rowid = m.id JOIN conversations AS c ON m.conversation_id = c.id WHERE messages_fts MATCH ? ORDER BY fts.rank LIMIT ?",
    on: conn,
    with: [sqlight.text(safe_query), sqlight.int(limit)],
    expecting: search_result_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to search messages: " <> string.inspect(err)
  })
    }
  }
}

fn do_update_compaction_summary(
  conn: sqlight.Connection,
  conversation_id: String,
  summary: String,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE conversations SET compaction_summary = ? WHERE id = ?",
    on: conn,
    with: [sqlight.text(summary), sqlight.text(conversation_id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update compaction summary: " <> string.inspect(err)
  })
}

fn do_get_compaction_summary(
  conn: sqlight.Connection,
  conversation_id: String,
) -> Result(String, String) {
  let result =
    sqlight.query(
      "SELECT COALESCE(compaction_summary, '') FROM conversations WHERE id = ?",
      on: conn,
      with: [sqlight.text(conversation_id)],
      expecting: decode.at([0], decode.string),
    )
  case result {
    Ok([summary]) -> Ok(summary)
    Ok([]) -> Ok("")
    Ok(_) -> Ok("")
    Error(e) ->
      Error(
        "Failed to get compaction summary: " <> string.inspect(e),
      )
  }
}

fn do_update_last_active(
  conn: sqlight.Connection,
  conversation_id: String,
  timestamp: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE conversations SET last_active_at = ? WHERE id = ?",
    on: conn,
    with: [sqlight.int(timestamp), sqlight.text(conversation_id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update last_active_at: " <> string.inspect(err)
  })
}

fn do_set_domain(
  conn: sqlight.Connection,
  conversation_id: String,
  domain: String,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE conversations SET domain = ? WHERE id = ?",
    on: conn,
    with: [sqlight.text(domain), sqlight.text(conversation_id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to set domain: " <> string.inspect(err)
  })
}

fn do_has_messages(conn: sqlight.Connection) -> Result(Bool, String) {
  case sqlight.query(
    "SELECT 1 FROM messages LIMIT 1",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  ) {
    Ok([]) -> Ok(False)
    Ok(_) -> Ok(True)
    Error(e) -> Error("Failed to check messages: " <> string.inspect(e))
  }
}

fn do_upsert_flare(
  conn: sqlight.Connection,
  stored: StoredFlare,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT OR REPLACE INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(stored.id),
      sqlight.text(stored.label),
      sqlight.text(stored.status),
      sqlight.text(stored.domain),
      sqlight.text(stored.thread_id),
      sqlight.text(stored.original_prompt),
      sqlight.text(stored.execution),
      sqlight.text(stored.triggers),
      sqlight.text(stored.tools),
      sqlight.text(stored.workspace),
      sqlight.text(stored.session_id),
      sqlight.int(stored.created_at_ms),
      sqlight.int(stored.updated_at_ms),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to upsert flare: " <> string.inspect(err)
  })
}

fn do_load_flares(
  conn: sqlight.Connection,
  exclude_archived: Bool,
) -> Result(List(StoredFlare), String) {
  let sql = case exclude_archived {
    True ->
      "SELECT id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms FROM flares WHERE status != 'archived' ORDER BY created_at_ms ASC"
    False ->
      "SELECT id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms FROM flares ORDER BY created_at_ms ASC"
  }
  sqlight.query(
    sql,
    on: conn,
    with: [],
    expecting: flare_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to load flares: " <> string.inspect(err)
  })
}

fn do_update_flare_status(
  conn: sqlight.Connection,
  id: String,
  status: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE flares SET status = ?, updated_at_ms = ? WHERE id = ?",
    on: conn,
    with: [sqlight.text(status), sqlight.int(updated_at_ms), sqlight.text(id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update flare status: " <> string.inspect(err)
  })
}

fn do_update_flare_session_id(
  conn: sqlight.Connection,
  id: String,
  session_id: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE flares SET session_id = ?, updated_at_ms = ? WHERE id = ?",
    on: conn,
    with: [sqlight.text(session_id), sqlight.int(updated_at_ms), sqlight.text(id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update flare session_id: " <> string.inspect(err)
  })
}

fn do_update_flare_rekindle(
  conn: sqlight.Connection,
  id: String,
  session_id: String,
  status: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE flares SET session_id = ?1, status = ?2, updated_at_ms = ?3 WHERE id = ?4",
    on: conn,
    with: [sqlight.text(session_id), sqlight.text(status), sqlight.int(updated_at_ms), sqlight.text(id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update flare rekindle: " <> string.inspect(err)
  })
}

fn do_insert_memory_entry(
  conn: sqlight.Connection,
  domain: String,
  target: String,
  key: String,
  content: String,
  created_at_ms: Int,
) -> Result(Int, String) {
  sqlight.query(
    "INSERT INTO memory_entries (domain, target, key, content, created_at_ms) VALUES (?, ?, ?, ?, ?) RETURNING id",
    on: conn,
    with: [
      sqlight.text(domain),
      sqlight.text(target),
      sqlight.text(key),
      sqlight.text(content),
      sqlight.int(created_at_ms),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(err) {
    "Failed to insert memory entry: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    case rows {
      [id] -> Ok(id)
      _ -> Error("Expected one row from INSERT RETURNING, got " <> string.inspect(rows))
    }
  })
}

fn do_supersede_memory_entry(
  conn: sqlight.Connection,
  entry_id: Int,
  superseded_by: Int,
  superseded_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE memory_entries SET superseded_at_ms = ?, superseded_by = ? WHERE id = ? AND superseded_at_ms IS NULL",
    on: conn,
    with: [
      sqlight.int(superseded_at_ms),
      sqlight.int(superseded_by),
      sqlight.int(entry_id),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to supersede memory entry: " <> string.inspect(err)
  })
}

fn do_get_active_memory_entries(
  conn: sqlight.Connection,
  domain: String,
  target: String,
) -> Result(List(MemoryEntry), String) {
  sqlight.query(
    "SELECT id, domain, target, key, content, created_at_ms FROM memory_entries WHERE domain = ? AND target = ? AND superseded_at_ms IS NULL ORDER BY created_at_ms ASC",
    on: conn,
    with: [sqlight.text(domain), sqlight.text(target)],
    expecting: memory_entry_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to get active memory entries: " <> string.inspect(err)
  })
}

fn do_get_active_entry_id(
  conn: sqlight.Connection,
  domain: String,
  target: String,
  key: String,
  exclude_id: Int,
) -> Result(Int, String) {
  sqlight.query(
    "SELECT id FROM memory_entries WHERE domain = ? AND target = ? AND key = ? AND id != ? AND superseded_at_ms IS NULL LIMIT 1",
    on: conn,
    with: [
      sqlight.text(domain),
      sqlight.text(target),
      sqlight.text(key),
      sqlight.int(exclude_id),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(err) {
    "Failed to get active entry id: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    case rows {
      [id] -> Ok(id)
      _ -> Error("No active entry found for key")
    }
  })
}

// ---------------------------------------------------------------------------
// Decoders
// ---------------------------------------------------------------------------

fn stored_message_decoder() -> decode.Decoder(StoredMessage) {
  use id <- decode.field(0, decode.int)
  use conversation_id <- decode.field(1, decode.string)
  use role <- decode.field(2, decode.string)
  use content <- decode.field(3, nullable_string_decoder())
  use author_id <- decode.field(4, nullable_string_decoder())
  use author_name <- decode.field(5, nullable_string_decoder())
  use tool_call_id <- decode.field(6, nullable_string_decoder())
  use tool_calls <- decode.field(7, nullable_string_decoder())
  use tool_name <- decode.field(8, nullable_string_decoder())
  use created_at <- decode.field(9, decode.int)
  decode.success(StoredMessage(
    id: id,
    conversation_id: conversation_id,
    role: role,
    content: content,
    author_id: author_id,
    author_name: author_name,
    tool_call_id: tool_call_id,
    tool_calls: tool_calls,
    tool_name: tool_name,
    created_at: created_at,
  ))
}

fn search_result_decoder() -> decode.Decoder(SearchResult) {
  use conversation_id <- decode.field(0, decode.string)
  use role <- decode.field(1, decode.string)
  use snippet <- decode.field(2, nullable_string_decoder())
  use content <- decode.field(3, nullable_string_decoder())
  use author_name <- decode.field(4, nullable_string_decoder())
  use created_at <- decode.field(5, decode.int)
  use platform <- decode.field(6, decode.string)
  use platform_id <- decode.field(7, decode.string)
  decode.success(SearchResult(
    conversation_id: conversation_id,
    role: role,
    snippet: snippet,
    content: content,
    author_name: author_name,
    created_at: created_at,
    platform: platform,
    platform_id: platform_id,
  ))
}

fn nullable_string_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.string, [
    decode.success(""),
  ])
}

fn memory_entry_decoder() -> decode.Decoder(MemoryEntry) {
  use id <- decode.field(0, decode.int)
  use domain <- decode.field(1, decode.string)
  use target <- decode.field(2, decode.string)
  use key <- decode.field(3, decode.string)
  use content <- decode.field(4, decode.string)
  use created_at_ms <- decode.field(5, decode.int)
  decode.success(MemoryEntry(
    id: id,
    domain: domain,
    target: target,
    key: key,
    content: content,
    created_at_ms: created_at_ms,
  ))
}

fn flare_decoder() -> decode.Decoder(StoredFlare) {
  use id <- decode.field(0, decode.string)
  use label <- decode.field(1, decode.string)
  use status <- decode.field(2, decode.string)
  use domain <- decode.field(3, decode.string)
  use thread_id <- decode.field(4, decode.string)
  use original_prompt <- decode.field(5, decode.string)
  use execution <- decode.field(6, decode.string)
  use triggers <- decode.field(7, decode.string)
  use tools <- decode.field(8, decode.string)
  use workspace <- decode.field(9, nullable_string_decoder())
  use session_id <- decode.field(10, nullable_string_decoder())
  use created_at_ms <- decode.field(11, decode.int)
  use updated_at_ms <- decode.field(12, decode.int)
  decode.success(StoredFlare(
    id: id,
    label: label,
    status: status,
    domain: domain,
    thread_id: thread_id,
    original_prompt: original_prompt,
    execution: execution,
    triggers: triggers,
    tools: tools,
    workspace: workspace,
    session_id: session_id,
    created_at_ms: created_at_ms,
    updated_at_ms: updated_at_ms,
  ))
}
