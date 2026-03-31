import gleam/dynamic/decode
import gleam/result
import gleam/string
import sqlight

const current_version = 1

/// Create all tables, indexes, FTS5 virtual table, and triggers if they do not
/// already exist, then run any pending schema migrations.
pub fn initialize(conn: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(exec(conn, "PRAGMA journal_mode=WAL"))
  use _ <- result.try(exec(conn, "PRAGMA busy_timeout=1000"))

  use _ <- result.try(exec(conn, "
    CREATE TABLE IF NOT EXISTS schema_version (
      version INTEGER NOT NULL
    )
  "))

  use _ <- result.try(exec(conn, "
    CREATE TABLE IF NOT EXISTS conversations (
      id TEXT PRIMARY KEY,
      platform TEXT NOT NULL,
      platform_id TEXT NOT NULL,
      parent_id TEXT,
      workstream TEXT,
      title TEXT,
      last_active_at INTEGER NOT NULL,
      compaction_summary TEXT,
      metadata TEXT,
      UNIQUE(platform, platform_id)
    )
  "))

  use _ <- result.try(exec(conn, "
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id TEXT NOT NULL REFERENCES conversations(id),
      role TEXT NOT NULL,
      content TEXT,
      author_id TEXT,
      author_name TEXT,
      tool_call_id TEXT,
      tool_calls TEXT,
      tool_name TEXT,
      attachments TEXT,
      metadata TEXT,
      created_at INTEGER NOT NULL,
      seq INTEGER NOT NULL DEFAULT 0
    )
  "))

  use _ <- result.try(exec(conn, "
    CREATE INDEX IF NOT EXISTS idx_messages_convo
      ON messages(conversation_id, created_at, seq)
  "))
  use _ <- result.try(exec(conn, "
    CREATE INDEX IF NOT EXISTS idx_conversations_platform
      ON conversations(platform, platform_id)
  "))
  use _ <- result.try(exec(conn, "
    CREATE INDEX IF NOT EXISTS idx_conversations_workstream
      ON conversations(workstream)
  "))

  use _ <- result.try(exec(conn, "
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
      content,
      content=messages,
      content_rowid=id,
      tokenize='porter unicode61'
    )
  "))

  use _ <- result.try(exec(conn, "
    CREATE TRIGGER IF NOT EXISTS messages_fts_insert
      AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
    END
  "))
  use _ <- result.try(exec(conn, "
    CREATE TRIGGER IF NOT EXISTS messages_fts_delete
      AFTER DELETE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, content)
        VALUES('delete', old.id, old.content);
    END
  "))
  use _ <- result.try(exec(conn, "
    CREATE TRIGGER IF NOT EXISTS messages_fts_update
      AFTER UPDATE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, content)
        VALUES('delete', old.id, old.content);
      INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
    END
  "))

  // Set or migrate schema version
  migrate_version(conn)
}

/// Read the current schema version number. Returns `0` for a fresh database
/// that has not yet been versioned.
pub fn get_version(conn: sqlight.Connection) -> Result(Int, String) {
  case sqlight.query(
    "SELECT version FROM schema_version LIMIT 1",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  ) {
    Ok([v]) -> Ok(v)
    Ok([]) -> Ok(0)
    Ok(_) -> Ok(0)
    Error(e) -> Error("Failed to get schema version: " <> string.inspect(e))
  }
}

fn migrate_version(conn: sqlight.Connection) -> Result(Nil, String) {
  use version <- result.try(get_version(conn))
  case version {
    0 -> {
      // Fresh database — set initial version
      exec(conn, "INSERT INTO schema_version (version) VALUES (" <> string.inspect(current_version) <> ")")
    }
    v if v == current_version -> Ok(Nil)
    v if v < current_version -> {
      // Future: run migration steps from v to current_version
      // For now, just update the version number
      exec(conn, "UPDATE schema_version SET version = " <> string.inspect(current_version))
    }
    _ -> {
      // Database is newer than this code — don't downgrade
      Error("Database schema version " <> string.inspect(version) <> " is newer than supported version " <> string.inspect(current_version))
    }
  }
}

fn exec(conn: sqlight.Connection, sql: String) -> Result(Nil, String) {
  sqlight.exec(sql, conn)
  |> result.map_error(fn(e) { "SQL error: " <> string.inspect(e) })
}
