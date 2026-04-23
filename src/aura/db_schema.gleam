import gleam/dynamic/decode
import gleam/result
import gleam/string
import sqlight

const current_version = 6

/// Create all tables, indexes, FTS5 virtual table, and triggers if they do not
/// already exist, then run any pending schema migrations.
pub fn initialize(conn: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(exec(conn, "PRAGMA journal_mode=WAL"))
  use _ <- result.try(exec(conn, "PRAGMA busy_timeout=1000"))

  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS schema_version (
      version INTEGER NOT NULL
    )
  ",
  ))

  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS conversations (
      id TEXT PRIMARY KEY,
      platform TEXT NOT NULL,
      platform_id TEXT NOT NULL,
      parent_id TEXT,
      domain TEXT,
      title TEXT,
      last_active_at INTEGER NOT NULL,
      compaction_summary TEXT,
      metadata TEXT,
      UNIQUE(platform, platform_id)
    )
  ",
  ))

  use _ <- result.try(exec(
    conn,
    "
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
  ",
  ))

  use _ <- result.try(exec(
    conn,
    "
    CREATE INDEX IF NOT EXISTS idx_messages_convo
      ON messages(conversation_id, created_at, seq)
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE INDEX IF NOT EXISTS idx_conversations_platform
      ON conversations(platform, platform_id)
  ",
  ))
  // idx_conversations_domain is created by migration v2 (renames workstream → domain)
  // For fresh DBs, the column is already named `domain` and the migration creates the index

  use _ <- result.try(exec(
    conn,
    "
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
      content,
      content=messages,
      content_rowid=id,
      tokenize='porter unicode61'
    )
  ",
  ))

  use _ <- result.try(exec(
    conn,
    "
    CREATE TRIGGER IF NOT EXISTS messages_fts_insert
      AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
    END
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TRIGGER IF NOT EXISTS messages_fts_delete
      AFTER DELETE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, content)
        VALUES('delete', old.id, old.content);
    END
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TRIGGER IF NOT EXISTS messages_fts_update
      AFTER UPDATE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, content)
        VALUES('delete', old.id, old.content);
      INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
    END
  ",
  ))

  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS flares (
      id TEXT PRIMARY KEY,
      label TEXT NOT NULL,
      status TEXT NOT NULL,
      domain TEXT NOT NULL,
      thread_id TEXT NOT NULL,
      original_prompt TEXT NOT NULL,
      execution TEXT NOT NULL,
      triggers TEXT NOT NULL,
      tools TEXT NOT NULL,
      workspace TEXT,
      session_id TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      result_text TEXT
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_flares_status ON flares(status)",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_flares_domain ON flares(domain)",
  ))

  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS memory_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      domain TEXT NOT NULL,
      target TEXT NOT NULL,
      key TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      superseded_at_ms INTEGER,
      superseded_by INTEGER REFERENCES memory_entries(id)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_memory_entries_domain_target ON memory_entries(domain, target)",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_memory_entries_superseded ON memory_entries(superseded_at_ms)",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_memory_entries_active_key ON memory_entries(domain, target, key, superseded_at_ms)",
  ))

  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS dream_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      domain TEXT NOT NULL,
      completed_at_ms INTEGER NOT NULL,
      phase_reached TEXT NOT NULL,
      entries_consolidated INTEGER,
      entries_promoted INTEGER,
      reflections_generated INTEGER,
      duration_ms INTEGER
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_dream_runs_domain ON dream_runs(domain)",
  ))

  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS events (
      id TEXT PRIMARY KEY,
      source TEXT NOT NULL,
      type TEXT NOT NULL,
      subject TEXT NOT NULL,
      time_ms INTEGER NOT NULL,
      tags_json TEXT NOT NULL DEFAULT '{}',
      external_id TEXT NOT NULL,
      data_json TEXT NOT NULL DEFAULT '{}',
      UNIQUE (source, external_id)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_events_source_time ON events(source, time_ms DESC)",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_events_subject ON events(subject)",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_events_time_ms ON events(time_ms DESC)",
  ))

  use _ <- result.try(exec(
    conn,
    "
    CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
      id UNINDEXED,
      source,
      type,
      subject,
      tags_json,
      data_json,
      content='events',
      content_rowid='rowid'
    )
  ",
  ))

  use _ <- result.try(exec(
    conn,
    "
    CREATE TRIGGER IF NOT EXISTS events_fts_insert
      AFTER INSERT ON events BEGIN
      INSERT INTO events_fts(rowid, id, source, type, subject, tags_json, data_json)
        VALUES (new.rowid, new.id, new.source, new.type, new.subject, new.tags_json, new.data_json);
    END
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TRIGGER IF NOT EXISTS events_fts_delete
      AFTER DELETE ON events BEGIN
      INSERT INTO events_fts(events_fts, rowid, id, source, type, subject, tags_json, data_json)
        VALUES('delete', old.rowid, old.id, old.source, old.type, old.subject, old.tags_json, old.data_json);
    END
  ",
  ))

  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS integration_checkpoints (
      name TEXT PRIMARY KEY,
      uidvalidity INTEGER NOT NULL,
      last_seen_uid INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )
  ",
  ))

  // Set or migrate schema version
  migrate_version(conn)
}

/// Read the current schema version number. Returns `0` for a fresh database
/// that has not yet been versioned.
pub fn get_version(conn: sqlight.Connection) -> Result(Int, String) {
  case
    sqlight.query(
      "SELECT version FROM schema_version LIMIT 1",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  {
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
      // Fresh database — create domain index and set version
      use _ <- result.try(exec(
        conn,
        "CREATE INDEX IF NOT EXISTS idx_conversations_domain ON conversations(domain)",
      ))
      exec(
        conn,
        "INSERT INTO schema_version (version) VALUES ("
          <> string.inspect(current_version)
          <> ")",
      )
    }
    v if v == current_version -> Ok(Nil)
    v if v < current_version -> {
      // Run migrations step by step
      use _ <- result.try(case v < 2 {
        True -> {
          // v1 → v2: rename workstream column to domain
          use _ <- result.try(exec(
            conn,
            "ALTER TABLE conversations RENAME COLUMN workstream TO domain",
          ))
          use _ <- result.try(exec(
            conn,
            "DROP INDEX IF EXISTS idx_conversations_workstream",
          ))
          exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_conversations_domain ON conversations(domain)",
          )
        }
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 3 {
        True -> {
          use _ <- result.try(exec(
            conn,
            "
            CREATE TABLE IF NOT EXISTS flares (
              id TEXT PRIMARY KEY,
              label TEXT NOT NULL,
              status TEXT NOT NULL,
              domain TEXT NOT NULL,
              thread_id TEXT NOT NULL,
              original_prompt TEXT NOT NULL,
              execution TEXT NOT NULL,
              triggers TEXT NOT NULL,
              tools TEXT NOT NULL,
              workspace TEXT,
              session_id TEXT,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ",
          ))
          use _ <- result.try(exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_flares_status ON flares(status)",
          ))
          exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_flares_domain ON flares(domain)",
          )
        }
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 4 {
        True -> {
          use _ <- result.try(exec(
            conn,
            "
            CREATE TABLE IF NOT EXISTS memory_entries (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              domain TEXT NOT NULL,
              target TEXT NOT NULL,
              key TEXT NOT NULL,
              content TEXT NOT NULL,
              created_at_ms INTEGER NOT NULL,
              superseded_at_ms INTEGER,
              superseded_by INTEGER REFERENCES memory_entries(id)
            )
          ",
          ))
          use _ <- result.try(exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_memory_entries_domain_target ON memory_entries(domain, target)",
          ))
          use _ <- result.try(exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_memory_entries_superseded ON memory_entries(superseded_at_ms)",
          ))
          use _ <- result.try(exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_memory_entries_active_key ON memory_entries(domain, target, key, superseded_at_ms)",
          ))
          use _ <- result.try(exec(
            conn,
            "
            CREATE TABLE IF NOT EXISTS dream_runs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              domain TEXT NOT NULL,
              completed_at_ms INTEGER NOT NULL,
              phase_reached TEXT NOT NULL,
              entries_consolidated INTEGER,
              entries_promoted INTEGER,
              reflections_generated INTEGER,
              duration_ms INTEGER
            )
          ",
          ))
          use _ <- result.try(exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_dream_runs_domain ON dream_runs(domain)",
          ))
          // Check if result_text column already exists before ALTER (idempotent)
          case
            sqlight.query(
              "SELECT COUNT(*) FROM pragma_table_info('flares') WHERE name = 'result_text'",
              on: conn,
              with: [],
              expecting: decode.at([0], decode.int),
            )
          {
            Ok([0]) ->
              exec(conn, "ALTER TABLE flares ADD COLUMN result_text TEXT")
            Ok(_) -> Ok(Nil)
            // Column already exists
            Error(_) ->
              exec(conn, "ALTER TABLE flares ADD COLUMN result_text TEXT")
            // Fallback: try anyway
          }
        }
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 5 {
        True -> {
          use _ <- result.try(exec(
            conn,
            "
            CREATE TABLE IF NOT EXISTS events (
              id TEXT PRIMARY KEY,
              source TEXT NOT NULL,
              type TEXT NOT NULL,
              subject TEXT NOT NULL,
              time_ms INTEGER NOT NULL,
              tags_json TEXT NOT NULL DEFAULT '{}',
              external_id TEXT NOT NULL,
              data_json TEXT NOT NULL DEFAULT '{}',
              UNIQUE (source, external_id)
            )
          ",
          ))
          use _ <- result.try(exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_events_source_time ON events(source, time_ms DESC)",
          ))
          use _ <- result.try(exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_events_subject ON events(subject)",
          ))
          use _ <- result.try(exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_events_time_ms ON events(time_ms DESC)",
          ))
          use _ <- result.try(exec(
            conn,
            "
            CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
              id UNINDEXED,
              source,
              type,
              subject,
              tags_json,
              data_json,
              content='events',
              content_rowid='rowid'
            )
          ",
          ))
          use _ <- result.try(exec(
            conn,
            "
            CREATE TRIGGER IF NOT EXISTS events_fts_insert
              AFTER INSERT ON events BEGIN
              INSERT INTO events_fts(rowid, id, source, type, subject, tags_json, data_json)
                VALUES (new.rowid, new.id, new.source, new.type, new.subject, new.tags_json, new.data_json);
            END
          ",
          ))
          exec(
            conn,
            "
            CREATE TRIGGER IF NOT EXISTS events_fts_delete
              AFTER DELETE ON events BEGIN
              INSERT INTO events_fts(events_fts, rowid, id, source, type, subject, tags_json, data_json)
                VALUES('delete', old.rowid, old.id, old.source, old.type, old.subject, old.tags_json, old.data_json);
            END
          ",
          )
        }
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 6 {
        True ->
          exec(
            conn,
            "
            CREATE TABLE IF NOT EXISTS integration_checkpoints (
              name TEXT PRIMARY KEY,
              uidvalidity INTEGER NOT NULL,
              last_seen_uid INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ",
          )
        False -> Ok(Nil)
      })
      exec(
        conn,
        "UPDATE schema_version SET version = "
          <> string.inspect(current_version),
      )
    }
    _ -> {
      // Database is newer than this code — don't downgrade
      Error(
        "Database schema version "
        <> string.inspect(version)
        <> " is newer than supported version "
        <> string.inspect(current_version),
      )
    }
  }
}

fn exec(conn: sqlight.Connection, sql: String) -> Result(Nil, String) {
  sqlight.exec(sql, conn)
  |> result.map_error(fn(e) { "SQL error: " <> string.inspect(e) })
}
