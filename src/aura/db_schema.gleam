import gleam/dynamic/decode
import gleam/result
import gleam/string
import sqlight

const current_version = 17

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
      result_text TEXT,
      dispatch_id TEXT,
      executor_kind TEXT NOT NULL DEFAULT 'acp',
      capability_manifest TEXT NOT NULL DEFAULT '{}',
      context_manifest TEXT NOT NULL DEFAULT '{}',
      authority_boundary TEXT NOT NULL DEFAULT '{}',
      final_result TEXT,
      final_proof TEXT,
      archived INTEGER NOT NULL DEFAULT 0
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
      duration_ms INTEGER,
      entries_rendered INTEGER NOT NULL DEFAULT 0,
      entries_noop INTEGER NOT NULL DEFAULT 0,
      action_candidates_count INTEGER NOT NULL DEFAULT 0
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_dream_runs_domain ON dream_runs(domain)",
  ))
  use _ <- result.try(create_dream_observability_tables(conn))

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
  use _ <- result.try(create_integration_health_table(conn))

  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS shell_approvals (
      id TEXT PRIMARY KEY,
      channel_id TEXT NOT NULL,
      message_id TEXT NOT NULL,
      command TEXT NOT NULL,
      reason TEXT NOT NULL,
      status TEXT NOT NULL,
      requested_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_shell_approvals_channel_status ON shell_approvals(channel_id, status)",
  ))

  use _ <- result.try(create_external_asks_table(conn))
  use _ <- result.try(create_flare_attempts_and_events_tables(conn))
  use _ <- result.try(create_operational_tables(conn))
  use _ <- result.try(create_evidence_tables(conn))

  // Versioned Google execution tables reference the canary tables. Fresh
  // databases need those parents before version 17 is set. Copied databases
  // must first run older queue migrations that the canary indexes require.
  use version <- result.try(get_version(conn))
  use _ <- result.try(case version {
    0 -> create_canary_authorization_tables(conn)
    _ -> Ok(Nil)
  })
  use _ <- result.try(migrate_version(conn))
  use _ <- result.try(create_canary_authorization_tables(conn))
  create_google_execution_tables(conn)
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
      use _ <- result.try(create_google_execution_tables(conn))
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
      use _ <- result.try(case v < 7 {
        True -> {
          use _ <- result.try(exec(
            conn,
            "
            CREATE TABLE IF NOT EXISTS shell_approvals (
              id TEXT PRIMARY KEY,
              channel_id TEXT NOT NULL,
              message_id TEXT NOT NULL,
              command TEXT NOT NULL,
              reason TEXT NOT NULL,
              status TEXT NOT NULL,
              requested_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            )
          ",
          ))
          exec(
            conn,
            "CREATE INDEX IF NOT EXISTS idx_shell_approvals_channel_status ON shell_approvals(channel_id, status)",
          )
        }
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 8 {
        True -> {
          use _ <- result.try(add_column_if_missing(
            conn,
            "dream_runs",
            "entries_rendered",
            "ALTER TABLE dream_runs ADD COLUMN entries_rendered INTEGER NOT NULL DEFAULT 0",
          ))
          use _ <- result.try(add_column_if_missing(
            conn,
            "dream_runs",
            "entries_noop",
            "ALTER TABLE dream_runs ADD COLUMN entries_noop INTEGER NOT NULL DEFAULT 0",
          ))
          use _ <- result.try(add_column_if_missing(
            conn,
            "dream_runs",
            "action_candidates_count",
            "ALTER TABLE dream_runs ADD COLUMN action_candidates_count INTEGER NOT NULL DEFAULT 0",
          ))
          create_dream_observability_tables(conn)
        }
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 9 {
        True -> create_integration_health_table(conn)
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 10 {
        True -> create_external_asks_table(conn)
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 11 {
        True -> migrate_flares_to_v11(conn)
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 12 {
        True -> create_operational_tables(conn)
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 13 {
        True -> create_evidence_tables(conn)
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 14 {
        True -> migrate_attention_queue_to_v14(conn)
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 15 {
        True -> create_monitor_outcomes_table(conn)
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 16 {
        True -> create_canary_authorization_tables(conn)
        False -> Ok(Nil)
      })
      use _ <- result.try(case v < 17 {
        True -> create_google_execution_tables(conn)
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

fn create_google_execution_tables(
  conn: sqlight.Connection,
) -> Result(Nil, String) {
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS connector_oauth_client_sets (
      client_set_ref TEXT PRIMARY KEY,
      client_set_hash TEXT NOT NULL UNIQUE,
      gmail_client_ref TEXT NOT NULL UNIQUE,
      gmail_client_hash TEXT NOT NULL,
      calendar_client_ref TEXT NOT NULL UNIQUE,
      calendar_client_hash TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      CHECK (gmail_client_ref != calendar_client_ref)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS connector_oauth_sessions (
      session_ref TEXT PRIMARY KEY,
      connector_id TEXT NOT NULL CHECK (connector_id IN ('gmail', 'calendar')),
      preparation_authorization_id TEXT NOT NULL,
      configuration_ref TEXT NOT NULL,
      configuration_hash TEXT NOT NULL,
      oauth_client_ref TEXT NOT NULL,
      oauth_client_hash TEXT NOT NULL,
      client_set_ref TEXT NOT NULL,
      client_set_hash TEXT NOT NULL,
      state_hash TEXT NOT NULL,
      pkce_challenge TEXT NOT NULL,
      redirect_uri TEXT NOT NULL,
      phase TEXT NOT NULL CHECK (phase IN ('waiting', 'callback_claimed', 'succeeded', 'failed_before_effect', 'effect_unknown', 'expired')),
      expires_at_ms INTEGER NOT NULL,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      CHECK (expires_at_ms > created_at_ms)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS connector_external_effects (
      effect_id TEXT PRIMARY KEY,
      preparation_authorization_id TEXT NOT NULL,
      authorization_id TEXT,
      activation_id TEXT,
      configuration_ref TEXT NOT NULL,
      configuration_hash TEXT NOT NULL,
      connector_id TEXT NOT NULL CHECK (connector_id IN ('gmail', 'calendar')),
      oauth_client_ref TEXT NOT NULL,
      oauth_client_hash TEXT NOT NULL,
      client_set_ref TEXT NOT NULL,
      client_set_hash TEXT NOT NULL,
      effect_kind TEXT NOT NULL CHECK (effect_kind IN ('oauth_exchange', 'oauth_refresh', 'identity_read')),
      logical_effect_key TEXT NOT NULL,
      attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
      request_hash TEXT NOT NULL,
      phase TEXT NOT NULL CHECK (phase IN ('intent', 'succeeded', 'failed_before_effect', 'effect_unknown')),
      proof_ref TEXT UNIQUE,
      oauth_scope TEXT NOT NULL,
      account_fingerprint TEXT,
      result_hash TEXT,
      error_class TEXT,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      UNIQUE (logical_effect_key, attempt_number)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_connector_external_effects_one_success ON connector_external_effects(logical_effect_key) WHERE phase = 'succeeded'",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS connector_checkpoints (
      configuration_ref TEXT NOT NULL,
      connector_id TEXT NOT NULL CHECK (connector_id IN ('gmail', 'calendar')),
      preparation_authorization_id TEXT NOT NULL,
      authorization_id TEXT NOT NULL,
      activation_id TEXT NOT NULL,
      configuration_hash TEXT NOT NULL,
      account_fingerprint TEXT NOT NULL,
      cursor_kind TEXT NOT NULL CHECK (cursor_kind IN ('gmail_history', 'calendar_poll')),
      cursor_value TEXT,
      last_success_at_ms INTEGER,
      next_due_at_ms INTEGER NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
      gap_code TEXT,
      version INTEGER NOT NULL CHECK (version > 0),
      updated_at_ms INTEGER NOT NULL,
      PRIMARY KEY (configuration_ref, activation_id)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_connector_checkpoints_due ON connector_checkpoints(next_due_at_ms, connector_id, activation_id)",
  ))
  use _ <- result.try(create_google_reference_triggers(conn))
  use _ <- result.try(create_google_no_delete_triggers(conn))
  use _ <- result.try(add_column_if_missing(
    conn,
    "connector_read_attempts",
    "hard_expires_at_ms",
    "ALTER TABLE connector_read_attempts ADD COLUMN hard_expires_at_ms INTEGER NOT NULL DEFAULT 0",
  ))
  use _ <- result.try(exec(
    conn,
    "UPDATE connector_read_attempts SET hard_expires_at_ms = lease_expires_at_ms WHERE hard_expires_at_ms = 0",
  ))
  Ok(Nil)
}

fn create_google_reference_triggers(
  conn: sqlight.Connection,
) -> Result(Nil, String) {
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_oauth_sessions_preparation_exists BEFORE INSERT ON connector_oauth_sessions WHEN NOT EXISTS (SELECT 1 FROM canary_preparation_authorizations WHERE authorization_id = NEW.preparation_authorization_id) BEGIN SELECT RAISE(ABORT, 'preparation_authorization_missing'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_oauth_sessions_client_binding_exists BEFORE INSERT ON connector_oauth_sessions WHEN NOT EXISTS (SELECT 1 FROM connector_oauth_client_sets s WHERE s.client_set_ref = NEW.client_set_ref AND s.client_set_hash = NEW.client_set_hash AND ((NEW.connector_id = 'gmail' AND s.gmail_client_ref = NEW.oauth_client_ref AND s.gmail_client_hash = NEW.oauth_client_hash) OR (NEW.connector_id = 'calendar' AND s.calendar_client_ref = NEW.oauth_client_ref AND s.calendar_client_hash = NEW.oauth_client_hash))) BEGIN SELECT RAISE(ABORT, 'oauth_client_binding_missing'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_oauth_sessions_preparation_stays_valid BEFORE UPDATE OF preparation_authorization_id ON connector_oauth_sessions WHEN NOT EXISTS (SELECT 1 FROM canary_preparation_authorizations WHERE authorization_id = NEW.preparation_authorization_id) BEGIN SELECT RAISE(ABORT, 'preparation_authorization_missing'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_external_effects_preparation_exists BEFORE INSERT ON connector_external_effects WHEN NOT EXISTS (SELECT 1 FROM canary_preparation_authorizations WHERE authorization_id = NEW.preparation_authorization_id) BEGIN SELECT RAISE(ABORT, 'preparation_authorization_missing'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_external_effects_client_binding_exists BEFORE INSERT ON connector_external_effects WHEN NOT EXISTS (SELECT 1 FROM connector_oauth_client_sets s WHERE s.client_set_ref = NEW.client_set_ref AND s.client_set_hash = NEW.client_set_hash AND ((NEW.connector_id = 'gmail' AND s.gmail_client_ref = NEW.oauth_client_ref AND s.gmail_client_hash = NEW.oauth_client_hash) OR (NEW.connector_id = 'calendar' AND s.calendar_client_ref = NEW.oauth_client_ref AND s.calendar_client_hash = NEW.oauth_client_hash))) BEGIN SELECT RAISE(ABORT, 'oauth_client_binding_missing'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_external_effects_authorization_exists BEFORE INSERT ON connector_external_effects WHEN NEW.authorization_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM canary_authorizations WHERE authorization_id = NEW.authorization_id) BEGIN SELECT RAISE(ABORT, 'canary_authorization_missing'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_external_effects_activation_exists BEFORE INSERT ON connector_external_effects WHEN NEW.activation_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM connector_activations WHERE activation_id = NEW.activation_id) BEGIN SELECT RAISE(ABORT, 'connector_activation_missing'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_external_effects_references_stay_valid BEFORE UPDATE OF preparation_authorization_id, authorization_id, activation_id ON connector_external_effects WHEN NOT EXISTS (SELECT 1 FROM canary_preparation_authorizations WHERE authorization_id = NEW.preparation_authorization_id) OR (NEW.authorization_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM canary_authorizations WHERE authorization_id = NEW.authorization_id)) OR (NEW.activation_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM connector_activations WHERE activation_id = NEW.activation_id)) BEGIN SELECT RAISE(ABORT, 'connector_external_effect_reference_missing'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_checkpoints_references_exist BEFORE INSERT ON connector_checkpoints WHEN NOT EXISTS (SELECT 1 FROM canary_preparation_authorizations WHERE authorization_id = NEW.preparation_authorization_id) OR NOT EXISTS (SELECT 1 FROM canary_authorizations WHERE authorization_id = NEW.authorization_id) OR NOT EXISTS (SELECT 1 FROM connector_activations WHERE activation_id = NEW.activation_id) BEGIN SELECT RAISE(ABORT, 'connector_checkpoint_reference_missing'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_checkpoints_references_stay_valid BEFORE UPDATE OF preparation_authorization_id, authorization_id, activation_id ON connector_checkpoints WHEN NOT EXISTS (SELECT 1 FROM canary_preparation_authorizations WHERE authorization_id = NEW.preparation_authorization_id) OR NOT EXISTS (SELECT 1 FROM canary_authorizations WHERE authorization_id = NEW.authorization_id) OR NOT EXISTS (SELECT 1 FROM connector_activations WHERE activation_id = NEW.activation_id) BEGIN SELECT RAISE(ABORT, 'connector_checkpoint_reference_missing'); END",
  ))
  Ok(Nil)
}

fn create_google_no_delete_triggers(
  conn: sqlight.Connection,
) -> Result(Nil, String) {
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_oauth_client_sets_no_update BEFORE UPDATE ON connector_oauth_client_sets BEGIN SELECT RAISE(ABORT, 'connector_oauth_client_set_immutable'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_oauth_client_sets_no_delete BEFORE DELETE ON connector_oauth_client_sets BEGIN SELECT RAISE(ABORT, 'connector_oauth_client_set_immutable'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_oauth_sessions_no_delete BEFORE DELETE ON connector_oauth_sessions BEGIN SELECT RAISE(ABORT, 'connector_oauth_session_immutable_history'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_external_effects_no_delete BEFORE DELETE ON connector_external_effects BEGIN SELECT RAISE(ABORT, 'connector_external_effect_immutable_history'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_oauth_sessions_terminal_immutable BEFORE UPDATE ON connector_oauth_sessions WHEN OLD.phase IN ('succeeded', 'failed_before_effect', 'effect_unknown', 'expired') BEGIN SELECT RAISE(ABORT, 'connector_oauth_session_terminal'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_external_effects_terminal_immutable BEFORE UPDATE ON connector_external_effects WHEN OLD.phase IN ('succeeded', 'failed_before_effect', 'effect_unknown') BEGIN SELECT RAISE(ABORT, 'connector_external_effect_terminal'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_oauth_sessions_binding_immutable BEFORE UPDATE OF connector_id, preparation_authorization_id, configuration_ref, configuration_hash, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, state_hash, pkce_challenge, redirect_uri, expires_at_ms ON connector_oauth_sessions BEGIN SELECT RAISE(ABORT, 'connector_oauth_session_binding_immutable'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_external_effects_binding_immutable BEFORE UPDATE OF preparation_authorization_id, authorization_id, activation_id, configuration_ref, configuration_hash, connector_id, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, effect_kind, logical_effect_key, attempt_number, request_hash, oauth_scope ON connector_external_effects BEGIN SELECT RAISE(ABORT, 'connector_external_effect_binding_immutable'); END",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_checkpoints_binding_immutable BEFORE UPDATE OF configuration_ref, connector_id, preparation_authorization_id, authorization_id, activation_id, configuration_hash, account_fingerprint, cursor_kind ON connector_checkpoints BEGIN SELECT RAISE(ABORT, 'connector_checkpoint_binding_immutable'); END",
  ))
  exec(
    conn,
    "CREATE TRIGGER IF NOT EXISTS connector_checkpoints_no_delete BEFORE DELETE ON connector_checkpoints BEGIN SELECT RAISE(ABORT, 'connector_checkpoint_immutable_history'); END",
  )
}

fn migrate_attention_queue_to_v14(
  conn: sqlight.Connection,
) -> Result(Nil, String) {
  use _ <- result.try(add_column_if_missing(
    conn,
    "attention_queue",
    "delivery_target",
    "ALTER TABLE attention_queue ADD COLUMN delivery_target TEXT NOT NULL DEFAULT ''",
  ))
  use _ <- result.try(add_column_if_missing(
    conn,
    "attention_queue",
    "payload_hash",
    "ALTER TABLE attention_queue ADD COLUMN payload_hash TEXT NOT NULL DEFAULT ''",
  ))
  use _ <- result.try(exec(
    conn,
    "
    INSERT OR IGNORE INTO operational_audit (
      audit_id, schema_version, record_type, actor, source, action,
      target_type, target_id, before_version, after_version,
      idempotency_key, evidence_refs_json, proof_refs_json, result,
      error_code, occurred_at_ms
    )
    SELECT
      'attention-v14-quarantine:' || queue_id, 1, 'state_transition',
      'aura', 'schema_migration', 'attention.migration_quarantined',
      'attention_queue', queue_id, version, version + 1,
      queue_id, event_refs_json, '[]', 'succeeded',
      'legacy_untrusted_delivery_target', updated_at_ms
    FROM attention_queue
    WHERE payload_hash = ''
      AND state IN ('pending', 'deferred', 'leased')
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    UPDATE attention_queue
    SET state = 'dead_letter', delivery_target = '', lease_owner = NULL,
        lease_expires_at_ms = NULL, version = version + 1
    WHERE payload_hash = ''
      AND state IN ('pending', 'deferred', 'leased')
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS attention_delivery_attempts (
      attempt_id INTEGER PRIMARY KEY AUTOINCREMENT,
      queue_id TEXT NOT NULL REFERENCES attention_queue(queue_id),
      attempt_number INTEGER NOT NULL,
      lease_owner TEXT NOT NULL,
      lease_token TEXT NOT NULL UNIQUE,
      lease_expires_at_ms INTEGER NOT NULL,
      phase TEXT NOT NULL CHECK(phase IN ('claimed', 'intent', 'succeeded', 'failed', 'effect_unknown')),
      external_receipts_json TEXT NOT NULL DEFAULT '[]',
      error TEXT NOT NULL DEFAULT '',
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      UNIQUE(queue_id, attempt_number)
    )
  ",
  ))
  exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_attention_attempts_queue_phase ON attention_delivery_attempts(queue_id, phase, lease_expires_at_ms)",
  )
}

fn create_evidence_tables(conn: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS evidence_records (
      event_id TEXT PRIMARY KEY REFERENCES events(id),
      schema_version INTEGER NOT NULL,
      source_kind TEXT NOT NULL,
      resource_kind TEXT NOT NULL,
      resource_id TEXT NOT NULL,
      envelope_json TEXT NOT NULL,
      raw_ref TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      verification_status TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_evidence_resource ON evidence_records(resource_kind, resource_id)",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS evidence_concern_links (
      event_id TEXT NOT NULL REFERENCES evidence_records(event_id),
      concern_id TEXT NOT NULL,
      confidence REAL NOT NULL CHECK(confidence >= 0.0 AND confidence <= 1.0),
      provenance TEXT NOT NULL,
      confirmed INTEGER NOT NULL CHECK(confirmed IN (0, 1)),
      created_at_ms INTEGER NOT NULL,
      PRIMARY KEY(event_id, concern_id)
    )
  ",
  ))
  exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_evidence_concern ON evidence_concern_links(concern_id, event_id)",
  )
}

fn create_external_asks_table(conn: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS external_asks (
      id TEXT PRIMARY KEY,
      source TEXT NOT NULL,
      channel_id TEXT NOT NULL,
      message_id TEXT NOT NULL,
      text TEXT NOT NULL,
      buttons_json TEXT NOT NULL,
      status TEXT NOT NULL,
      decision TEXT NOT NULL,
      requested_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )
  ",
  ))
  exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_external_asks_status ON external_asks(status)",
  )
}

fn create_operational_tables(conn: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS mutation_receipts (
      idempotency_key TEXT PRIMARY KEY,
      schema_version INTEGER NOT NULL,
      payload_hash TEXT NOT NULL,
      operation_type TEXT NOT NULL,
      result_target_type TEXT NOT NULL,
      result_target_id TEXT NOT NULL,
      result_version INTEGER NOT NULL,
      result_json TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_mutation_receipts_operation ON mutation_receipts(operation_type, created_at_ms)",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS concern_links (
      concern_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      linked_id TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      UNIQUE(concern_id, kind, linked_id)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_concern_links_concern ON concern_links(concern_id, kind)",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS attention_queue (
      queue_id TEXT PRIMARY KEY,
      schema_version INTEGER NOT NULL,
      decision_id TEXT NOT NULL,
      domain_id TEXT NOT NULL,
      concern_id TEXT,
      event_refs_json TEXT NOT NULL DEFAULT '[]',
      action TEXT NOT NULL CHECK(action IN ('digest', 'surface_now', 'ask_now')),
      summary TEXT NOT NULL,
      rationale TEXT NOT NULL,
      why_now TEXT,
      deferral_cost TEXT,
      why_not_digest TEXT,
      authority_request TEXT,
      citations_json TEXT NOT NULL DEFAULT '[]',
      state TEXT NOT NULL CHECK(state IN ('pending', 'leased', 'delivered', 'acknowledged', 'deferred', 'expired', 'dead_letter')),
      delivery_owner TEXT NOT NULL CHECK(delivery_owner IN ('codex', 'discord_compat')),
      delivery_target TEXT NOT NULL DEFAULT 'default',
      delivery_key TEXT NOT NULL,
      payload_hash TEXT NOT NULL DEFAULT '',
      route_authorization_id TEXT REFERENCES canary_authorizations(authorization_id),
      route_activation_ids_json TEXT NOT NULL DEFAULT '[]',
      lease_owner TEXT,
      lease_expires_at_ms INTEGER,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      available_at_ms INTEGER NOT NULL,
      expires_at_ms INTEGER,
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      version INTEGER NOT NULL,
      UNIQUE(delivery_owner, delivery_key)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_attention_queue_owner_state_available ON attention_queue(delivery_owner, state, available_at_ms)",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_attention_queue_concern ON attention_queue(concern_id, created_at_ms)",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS attention_delivery_attempts (
      attempt_id INTEGER PRIMARY KEY AUTOINCREMENT,
      queue_id TEXT NOT NULL REFERENCES attention_queue(queue_id),
      attempt_number INTEGER NOT NULL,
      lease_owner TEXT NOT NULL,
      lease_token TEXT NOT NULL UNIQUE,
      lease_expires_at_ms INTEGER NOT NULL,
      phase TEXT NOT NULL CHECK(phase IN ('claimed', 'intent', 'succeeded', 'failed', 'effect_unknown')),
      external_receipts_json TEXT NOT NULL DEFAULT '[]',
      error TEXT NOT NULL DEFAULT '',
      created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      UNIQUE(queue_id, attempt_number)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_attention_attempts_queue_phase ON attention_delivery_attempts(queue_id, phase, lease_expires_at_ms)",
  ))
  use _ <- result.try(create_monitor_outcomes_table(conn))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS verification_records (
      verification_id TEXT PRIMARY KEY,
      schema_version INTEGER NOT NULL,
      target_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      requirement TEXT NOT NULL,
      method TEXT NOT NULL,
      result TEXT NOT NULL CHECK(result IN ('pass', 'fail', 'unknown')),
      evidence_refs_json TEXT NOT NULL DEFAULT '[]',
      verifier TEXT NOT NULL,
      verified_at_ms INTEGER NOT NULL
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_verification_target ON verification_records(target_type, target_id, verified_at_ms)",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS operational_audit (
      audit_id TEXT PRIMARY KEY,
      schema_version INTEGER NOT NULL,
      record_type TEXT NOT NULL,
      actor TEXT NOT NULL,
      source TEXT NOT NULL,
      action TEXT NOT NULL,
      target_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      before_version INTEGER,
      after_version INTEGER,
      idempotency_key TEXT,
      evidence_refs_json TEXT NOT NULL DEFAULT '[]',
      proof_refs_json TEXT NOT NULL DEFAULT '[]',
      authority_ref TEXT,
      result TEXT NOT NULL,
      error_code TEXT,
      occurred_at_ms INTEGER NOT NULL
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_operational_audit_target_time ON operational_audit(target_type, target_id, occurred_at_ms)",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_operational_audit_action_time ON operational_audit(action, occurred_at_ms)",
  ))
  add_column_if_missing(
    conn,
    "flare_events",
    "audit_id",
    "ALTER TABLE flare_events ADD COLUMN audit_id TEXT",
  )
}

fn create_monitor_outcomes_table(
  conn: sqlight.Connection,
) -> Result(Nil, String) {
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS attention_monitor_outcomes (
      outcome_id TEXT PRIMARY KEY,
      payload_hash TEXT NOT NULL,
      queue_id TEXT NOT NULL REFERENCES attention_queue(queue_id),
      lease_token TEXT NOT NULL,
      monitor_id TEXT NOT NULL,
      disposition TEXT NOT NULL CHECK(disposition IN ('acknowledge', 'defer')),
      defer_until_ms INTEGER,
      codex_task_ref TEXT,
      codex_conversation_ref TEXT,
      codex_turn_ref TEXT,
      authority_grants_json TEXT NOT NULL,
      result_json TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL
    )
  ",
  ))
  exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_attention_monitor_outcomes_queue ON attention_monitor_outcomes(queue_id, created_at_ms)",
  )
}

fn create_canary_authorization_tables(
  conn: sqlight.Connection,
) -> Result(Nil, String) {
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS canary_preparation_authorizations (
      authorization_id TEXT PRIMARY KEY,
      schema_version INTEGER NOT NULL,
      canary_id TEXT NOT NULL,
      canonical_json TEXT NOT NULL,
      payload_hash TEXT NOT NULL,
      expires_at_ms INTEGER NOT NULL,
      created_at_ms INTEGER NOT NULL,
      CHECK (schema_version = 1),
      CHECK (expires_at_ms > created_at_ms),
      UNIQUE (canary_id, payload_hash)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TRIGGER IF NOT EXISTS canary_preparation_authorizations_no_update
    BEFORE UPDATE ON canary_preparation_authorizations
    BEGIN SELECT RAISE(ABORT, 'canary_preparation_authorization_immutable'); END
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TRIGGER IF NOT EXISTS canary_preparation_authorizations_no_delete
    BEFORE DELETE ON canary_preparation_authorizations
    BEGIN SELECT RAISE(ABORT, 'canary_preparation_authorization_immutable'); END
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS canary_authorizations (
      authorization_id TEXT PRIMARY KEY,
      preparation_authorization_id TEXT NOT NULL
        REFERENCES canary_preparation_authorizations(authorization_id),
      schema_version INTEGER NOT NULL,
      canary_id TEXT NOT NULL,
      canonical_json TEXT NOT NULL,
      payload_hash TEXT NOT NULL,
      monitor_capability_hash TEXT NOT NULL,
      starts_at_ms INTEGER NOT NULL,
      ends_at_ms INTEGER NOT NULL,
      created_at_ms INTEGER NOT NULL,
      CHECK (schema_version = 1),
      CHECK (ends_at_ms > starts_at_ms),
      UNIQUE (canary_id, payload_hash)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TRIGGER IF NOT EXISTS canary_authorizations_no_update
    BEFORE UPDATE ON canary_authorizations
    BEGIN SELECT RAISE(ABORT, 'canary_authorization_immutable'); END
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TRIGGER IF NOT EXISTS canary_authorizations_no_delete
    BEFORE DELETE ON canary_authorizations
    BEGIN SELECT RAISE(ABORT, 'canary_authorization_immutable'); END
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS connector_activations (
      activation_id TEXT PRIMARY KEY,
      authorization_id TEXT NOT NULL
        REFERENCES canary_authorizations(authorization_id),
      connector_id TEXT NOT NULL,
      domain_id TEXT NOT NULL,
      concern_id TEXT NOT NULL,
      configuration_ref TEXT NOT NULL,
      oauth_scope TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('disabled', 'enabling', 'enabled', 'disabling')),
      version INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL,
      UNIQUE (authorization_id, connector_id, configuration_ref)
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_connector_activations_effective ON connector_activations(state, authorization_id, connector_id)",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_connector_activations_one_effective ON connector_activations(connector_id, domain_id, configuration_ref) WHERE state IN ('enabling', 'enabled', 'disabling')",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS connector_read_attempts (
      attempt_id TEXT PRIMARY KEY,
      activation_id TEXT NOT NULL REFERENCES connector_activations(activation_id),
      activation_version INTEGER NOT NULL,
      attempt_version INTEGER NOT NULL,
      worker_id TEXT NOT NULL,
      phase TEXT NOT NULL CHECK (phase IN ('reserved', 'request_started', 'completed', 'discarded', 'failed', 'interrupted')),
      reserved_at_ms INTEGER NOT NULL,
      lease_expires_at_ms INTEGER NOT NULL,
      hard_expires_at_ms INTEGER NOT NULL,
      request_started_at_ms INTEGER,
      finished_at_ms INTEGER,
      error_code TEXT NOT NULL DEFAULT ''
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_connector_read_attempts_active ON connector_read_attempts(activation_id, phase)",
  ))
  use _ <- result.try(add_column_if_missing(
    conn,
    "attention_queue",
    "route_authorization_id",
    "ALTER TABLE attention_queue ADD COLUMN route_authorization_id TEXT REFERENCES canary_authorizations(authorization_id)",
  ))
  use _ <- result.try(add_column_if_missing(
    conn,
    "attention_queue",
    "route_activation_ids_json",
    "ALTER TABLE attention_queue ADD COLUMN route_activation_ids_json TEXT NOT NULL DEFAULT '[]'",
  ))
  exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_attention_queue_authorized_route ON attention_queue(route_authorization_id, delivery_owner, delivery_target, state)",
  )
}

fn create_flare_attempts_and_events_tables(
  conn: sqlight.Connection,
) -> Result(Nil, String) {
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS flare_attempts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      flare_id TEXT NOT NULL REFERENCES flares(id),
      executor_kind TEXT NOT NULL,
      status TEXT NOT NULL,
      runtime_reference TEXT,
      checkpoint TEXT,
      started_at_ms INTEGER,
      ended_at_ms INTEGER,
      failure TEXT
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_flare_attempts_flare ON flare_attempts(flare_id)",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS flare_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      flare_id TEXT NOT NULL REFERENCES flares(id),
      attempt_id INTEGER,
      sequence INTEGER NOT NULL DEFAULT 0,
      event_type TEXT NOT NULL,
      payload TEXT NOT NULL DEFAULT '{}',
      created_at_ms INTEGER NOT NULL
    )
  ",
  ))
  exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_flare_events_flare ON flare_events(flare_id, sequence)",
  )
}

fn create_integration_health_table(
  conn: sqlight.Connection,
) -> Result(Nil, String) {
  exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS integration_health (
      name TEXT PRIMARY KEY,
      status TEXT NOT NULL,
      message TEXT NOT NULL,
      last_success_at_ms INTEGER,
      last_error_at_ms INTEGER,
      updated_at_ms INTEGER NOT NULL
    )
  ",
  )
}

fn create_dream_observability_tables(
  conn: sqlight.Connection,
) -> Result(Nil, String) {
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS dream_run_effects (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      dream_run_id INTEGER NOT NULL REFERENCES dream_runs(id),
      domain TEXT NOT NULL,
      phase TEXT NOT NULL,
      target TEXT NOT NULL,
      key TEXT NOT NULL,
      action TEXT NOT NULL,
      effect_kind TEXT NOT NULL,
      previous_memory_entry_id INTEGER,
      new_memory_entry_id INTEGER,
      previous_chars INTEGER,
      content_chars INTEGER NOT NULL,
      created_at_ms INTEGER NOT NULL
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_dream_run_effects_run ON dream_run_effects(dream_run_id)",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_dream_run_effects_key ON dream_run_effects(domain, target, key)",
  ))
  use _ <- result.try(exec(
    conn,
    "
    CREATE TABLE IF NOT EXISTS dream_action_candidates (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      dream_run_id INTEGER NOT NULL REFERENCES dream_runs(id),
      domain TEXT NOT NULL,
      candidate_type TEXT NOT NULL,
      severity INTEGER NOT NULL,
      reason TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL
    )
  ",
  ))
  use _ <- result.try(exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_dream_action_candidates_run ON dream_action_candidates(dream_run_id)",
  ))
  exec(
    conn,
    "CREATE INDEX IF NOT EXISTS idx_dream_action_candidates_domain ON dream_action_candidates(domain, candidate_type)",
  )
}

fn migrate_flares_to_v11(conn: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(add_column_if_missing(
    conn,
    "flares",
    "dispatch_id",
    "ALTER TABLE flares ADD COLUMN dispatch_id TEXT",
  ))
  use _ <- result.try(add_column_if_missing(
    conn,
    "flares",
    "executor_kind",
    "ALTER TABLE flares ADD COLUMN executor_kind TEXT NOT NULL DEFAULT 'acp'",
  ))
  use _ <- result.try(add_column_if_missing(
    conn,
    "flares",
    "capability_manifest",
    "ALTER TABLE flares ADD COLUMN capability_manifest TEXT NOT NULL DEFAULT '{}'",
  ))
  use _ <- result.try(add_column_if_missing(
    conn,
    "flares",
    "context_manifest",
    "ALTER TABLE flares ADD COLUMN context_manifest TEXT NOT NULL DEFAULT '{}'",
  ))
  use _ <- result.try(add_column_if_missing(
    conn,
    "flares",
    "authority_boundary",
    "ALTER TABLE flares ADD COLUMN authority_boundary TEXT NOT NULL DEFAULT '{}'",
  ))
  use _ <- result.try(add_column_if_missing(
    conn,
    "flares",
    "final_result",
    "ALTER TABLE flares ADD COLUMN final_result TEXT",
  ))
  use _ <- result.try(add_column_if_missing(
    conn,
    "flares",
    "final_proof",
    "ALTER TABLE flares ADD COLUMN final_proof TEXT",
  ))
  use _ <- result.try(add_column_if_missing(
    conn,
    "flares",
    "archived",
    "ALTER TABLE flares ADD COLUMN archived INTEGER NOT NULL DEFAULT 0",
  ))
  // Existing rows are ACP-originated. Backfill the archived flag from legacy
  // status values so roster-visibility semantics survive the state rename.
  use _ <- result.try(exec(
    conn,
    "UPDATE flares SET archived = 1 WHERE status = 'archived' AND archived = 0",
  ))
  create_flare_attempts_and_events_tables(conn)
}

fn add_column_if_missing(
  conn: sqlight.Connection,
  table: String,
  column: String,
  alter_sql: String,
) -> Result(Nil, String) {
  case
    sqlight.query(
      "SELECT COUNT(*) FROM pragma_table_info('" <> table <> "') WHERE name = ?",
      on: conn,
      with: [sqlight.text(column)],
      expecting: decode.at([0], decode.int),
    )
  {
    Ok([0]) -> exec(conn, alter_sql)
    Ok(_) -> Ok(Nil)
    Error(_) -> exec(conn, alter_sql)
  }
}

fn exec(conn: sqlight.Connection, sql: String) -> Result(Nil, String) {
  sqlight.exec(sql, conn)
  |> result.map_error(fn(e) { "SQL error: " <> string.inspect(e) })
}
