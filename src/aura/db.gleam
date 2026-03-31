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
  SetWorkstream(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    workstream: String,
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

/// Assign a workstream label to a conversation.
pub fn set_workstream(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  workstream: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    SetWorkstream(
      reply_to: reply_to,
      conversation_id: conversation_id,
      workstream: workstream,
    )
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

    UpdateLastActive(reply_to:, conversation_id:, timestamp:) -> {
      let result = do_update_last_active(state.conn, conversation_id, timestamp)
      process.send(reply_to, result)
      actor.continue(state)
    }

    SetWorkstream(reply_to:, conversation_id:, workstream:) -> {
      let result = do_set_workstream(state.conn, conversation_id, workstream)
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

fn do_load_messages(
  conn: sqlight.Connection,
  conversation_id: String,
  limit: Int,
) -> Result(List(StoredMessage), String) {
  sqlight.query(
    "SELECT id, conversation_id, role, content, author_id, author_name, tool_call_id, tool_calls, tool_name, created_at FROM messages WHERE conversation_id = ? ORDER BY created_at ASC, seq ASC, id ASC LIMIT ?",
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
  // Sanitize FTS5 query by wrapping in double quotes
  let safe_query = "\"" <> string.replace(query, "\"", "") <> "\""

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

fn do_set_workstream(
  conn: sqlight.Connection,
  conversation_id: String,
  workstream: String,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE conversations SET workstream = ? WHERE id = ?",
    on: conn,
    with: [sqlight.text(workstream), sqlight.text(conversation_id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to set workstream: " <> string.inspect(err)
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
