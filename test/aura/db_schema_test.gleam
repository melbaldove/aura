import aura/db
import aura/db_schema
import aura/test_helpers
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleeunit
import gleeunit/should
import simplifile
import sqlight

pub fn main() {
  gleeunit.main()
}

pub fn initialize_creates_tables_test() {
  use conn <- sqlight.with_connection(":memory:")
  db_schema.initialize(conn)
  |> should.be_ok

  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='conversations'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.be_ok
  |> should.equal(["conversations"])
}

pub fn initialize_creates_messages_table_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='messages'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.be_ok
  |> should.equal(["messages"])
}

pub fn initialize_creates_fts_table_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='messages_fts'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.be_ok
  |> should.equal(["messages_fts"])
}

pub fn initialize_is_idempotent_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  db_schema.initialize(conn)
  |> should.be_ok
}

pub fn schema_version_is_set_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  db_schema.get_version(conn)
  |> should.be_ok
  |> should.equal(17)
}

pub fn schema_v17_creates_google_execution_tables_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('connector_oauth_client_sets', 'connector_oauth_sessions', 'connector_external_effects', 'connector_checkpoints') ORDER BY name",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(
    Ok([
      "connector_checkpoints",
      "connector_external_effects",
      "connector_oauth_client_sets",
      "connector_oauth_sessions",
    ]),
  )
}

pub fn schema_v17_references_abort_without_parent_rows_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  sqlight.query(
    "INSERT INTO connector_oauth_sessions (session_ref, connector_id, preparation_authorization_id, configuration_ref, configuration_hash, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, state_hash, pkce_challenge, redirect_uri, phase, expires_at_ms, created_at_ms, updated_at_ms) VALUES ('session:missing-parent', 'gmail', 'authorization:missing', 'configuration:gmail', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'oauth-client:gmail', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'oauth-client-set:one', 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd', 'challenge', 'http://127.0.0.1:49152/callback', 'waiting', 2, 1, 1)",
    on: conn,
    with: [],
    expecting: decode.success(Nil),
  )
  |> should.be_error
}

pub fn migration_v16_to_v17_preserves_rows_and_keeps_old_activation_ineligible_test() {
  let path = "/tmp/aura-v16-v17-" <> test_helpers.random_suffix() <> ".db"
  let _ = simplifile.delete(path)
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO events (id, source, type, subject, time_ms, external_id) VALUES ('event-before-v17', 'system', 'test', 'Before v17', 1, 'before-v17')",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO canary_preparation_authorizations (authorization_id, schema_version, canary_id, canonical_json, payload_hash, expires_at_ms, created_at_ms) VALUES ('preparation-before-v17', 1, 'canary-before-v17', '{}', 'prep-hash', 9999999999999, 1)",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO canary_authorizations (authorization_id, preparation_authorization_id, schema_version, canary_id, canonical_json, payload_hash, monitor_capability_hash, starts_at_ms, ends_at_ms, created_at_ms) VALUES ('authorization-before-v17', 'preparation-before-v17', 1, 'canary-before-v17', '{}', 'auth-hash', 'monitor-hash', 1, 9999999999999, 1)",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO connector_activations (activation_id, authorization_id, connector_id, domain_id, concern_id, configuration_ref, oauth_scope, state, version, updated_at_ms) VALUES ('activation-before-v17', 'authorization-before-v17', 'gmail', 'domain:test', 'concern:test', 'configuration:gmail-test', 'https://www.googleapis.com/auth/gmail.readonly', 'enabled', 1, 1)",
      conn,
    )
  let assert Ok(_) = sqlight.exec("DROP TABLE connector_checkpoints", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE connector_external_effects", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE connector_oauth_sessions", conn)
  let assert Ok(_) =
    sqlight.exec("DROP TABLE connector_oauth_client_sets", conn)
  let assert Ok(_) =
    sqlight.exec("UPDATE schema_version SET version = 16", conn)
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) = db_schema.initialize(conn)
  db_schema.get_version(conn) |> should.equal(Ok(17))
  sqlight.query(
    "SELECT (SELECT COUNT(*) FROM events), (SELECT COUNT(*) FROM connector_activations), (SELECT COUNT(*) FROM connector_oauth_client_sets), (SELECT COUNT(*) FROM connector_oauth_sessions), (SELECT COUNT(*) FROM connector_external_effects), (SELECT COUNT(*) FROM connector_checkpoints)",
    on: conn,
    with: [],
    expecting: {
      use events <- decode.field(0, decode.int)
      use activations <- decode.field(1, decode.int)
      use client_sets <- decode.field(2, decode.int)
      use sessions <- decode.field(3, decode.int)
      use effects <- decode.field(4, decode.int)
      use checkpoints <- decode.field(5, decode.int)
      decode.success(#(
        events,
        activations,
        client_sets,
        sessions,
        effects,
        checkpoints,
      ))
    },
  )
  |> should.equal(Ok([#(1, 1, 0, 0, 0, 0)]))
  let assert Ok(subject) = db.start(path)
  db.reserve_connector_read(
    subject,
    "attempt:legacy-v16",
    "activation-before-v17",
    "authorization-before-v17",
    "worker:test",
    1000,
  )
  |> should.equal(Error("connector_execution_ineligible"))
  let _ = sqlight.close(conn)
  let _ = simplifile.delete(path)
}

pub fn schema_v13_creates_normalized_evidence_tables_test() {
  use conn <- sqlight.with_connection(":memory:")
  db_schema.initialize(conn) |> should.be_ok
  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('evidence_records', 'evidence_concern_links') ORDER BY name",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(Ok(["evidence_concern_links", "evidence_records"]))
}

pub fn migration_v12_to_v13_preserves_existing_events_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO events (id, source, type, subject, time_ms, external_id) VALUES ('event-before-v13', 'system', 'test', 'Before v13', 1, 'before-v13')",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec("UPDATE schema_version SET version = 12", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE evidence_concern_links", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE evidence_records", conn)

  db_schema.initialize(conn) |> should.be_ok
  db_schema.get_version(conn) |> should.equal(Ok(17))
  sqlight.query(
    "SELECT id FROM events WHERE id = 'event-before-v13'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(Ok(["event-before-v13"]))
}

pub fn schema_v5_creates_events_table_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  // Positive case: insert with all columns succeeds
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO events (id, source, type, subject, time_ms, tags_json, external_id, data_json) VALUES ('evt-1', 'gmail', 'message', 'Hello', 1000, '{}', 'ext-1', '{}')",
      conn,
    )

  let assert Ok(rows) =
    sqlight.query(
      "SELECT id FROM events",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  list.length(rows) |> should.equal(1)
}

pub fn schema_v5_events_dedup_on_source_external_id_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  // First insert succeeds
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO events (id, source, type, subject, time_ms, tags_json, external_id, data_json) VALUES ('evt-1', 'gmail', 'message', 'Hello', 1000, '{}', 'ext-dup', '{}')",
      conn,
    )

  // Second insert with same (source, external_id) must fail due to UNIQUE constraint
  sqlight.exec(
    "INSERT INTO events (id, source, type, subject, time_ms, tags_json, external_id, data_json) VALUES ('evt-2', 'gmail', 'message', 'Hello again', 2000, '{}', 'ext-dup', '{}')",
    conn,
  )
  |> result.is_error
  |> should.be_true
}

pub fn schema_v3_creates_flares_table_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  // Verify flares table exists by inserting a row
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, created_at_ms, updated_at_ms) VALUES ('test-id', 'test', 'active', 'work', 'ch1', 'do stuff', '{}', '[]', '[]', 1000, 1000)",
      conn,
    )
  let assert Ok(rows) =
    sqlight.query(
      "SELECT id FROM flares",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  list.length(rows) |> should.equal(1)
}

pub fn schema_v4_creates_memory_entries_table_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  // Verify memory_entries table exists by inserting a row
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO memory_entries (domain, target, key, content, created_at_ms) VALUES ('work', 'state', 'project_status', 'on track', 1000)",
      conn,
    )
  let assert Ok(rows) =
    sqlight.query(
      "SELECT key FROM memory_entries",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  list.length(rows) |> should.equal(1)
}

pub fn schema_v4_creates_dream_runs_table_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  // Verify dream_runs table exists by inserting a row
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO dream_runs (domain, completed_at_ms, phase_reached) VALUES ('work', 1000, 'consolidate')",
      conn,
    )
  let assert Ok(rows) =
    sqlight.query(
      "SELECT domain FROM dream_runs",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  list.length(rows) |> should.equal(1)
}

pub fn schema_v8_adds_dream_run_effects_table_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO dream_runs (domain, completed_at_ms, phase_reached) VALUES ('work', 1000, 'render')",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO dream_run_effects (dream_run_id, domain, phase, target, key, action, effect_kind, previous_memory_entry_id, new_memory_entry_id, previous_chars, content_chars, created_at_ms) VALUES (1, 'work', 'render', 'memory', 'domain-index', 'set', 'new', NULL, 10, NULL, 100, 1000)",
      conn,
    )

  let assert Ok(rows) =
    sqlight.query(
      "SELECT effect_kind FROM dream_run_effects",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  rows |> should.equal(["new"])
}

pub fn schema_v8_adds_dream_action_candidates_table_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO dream_runs (domain, completed_at_ms, phase_reached) VALUES ('work', 1000, 'render')",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO dream_action_candidates (dream_run_id, domain, candidate_type, severity, reason, created_at_ms) VALUES (1, 'work', 'sleep_candidate', 2, 'No changed memory across repeated cycles.', 1000)",
      conn,
    )

  let assert Ok(rows) =
    sqlight.query(
      "SELECT candidate_type FROM dream_action_candidates",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  rows |> should.equal(["sleep_candidate"])
}

pub fn schema_v4_adds_flares_result_text_column_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  // Verify result_text column exists on flares by inserting a row with it
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, created_at_ms, updated_at_ms, result_text) VALUES ('test-id', 'test', 'active', 'work', 'ch1', 'do stuff', '{}', '[]', '[]', 1000, 1000, 'some result')",
      conn,
    )
  let assert Ok(rows) =
    sqlight.query(
      "SELECT result_text FROM flares WHERE id = 'test-id'",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  rows |> should.equal(["some result"])
}

/// Regression test: ALTER TABLE ADD COLUMN must be idempotent.
/// Simulates a crash-after-ALTER-before-version-UPDATE scenario by manually
/// adding the column, then verifying that a v3→v4 migration doesn't fail.
pub fn schema_v4_alter_table_idempotent_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  // First initialization creates everything including result_text column
  let assert Ok(_) = db_schema.initialize(conn)
  // Manually revert version to 3 to force the v4 migration to run again
  let assert Ok(_) = sqlight.exec("UPDATE schema_version SET version = 3", conn)
  // Re-running initialize should NOT fail even though result_text already exists
  db_schema.initialize(conn)
  |> should.be_ok
  // Verify version is migrated forward to the current version
  db_schema.get_version(conn)
  |> should.be_ok
  |> should.equal(17)
}

pub fn schema_v6_creates_integration_checkpoints_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='integration_checkpoints'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> result.map(list.length)
  |> should.be_ok
  |> should.equal(1)
}

pub fn schema_v7_creates_shell_approvals_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO shell_approvals (id, channel_id, message_id, command, reason, status, requested_at_ms, updated_at_ms) VALUES ('sh1', 'ch1', 'm1', 'echo hi', 'test', 'pending', 1000, 1000)",
      conn,
    )

  sqlight.query(
    "SELECT status FROM shell_approvals WHERE id = 'sh1'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.be_ok
  |> should.equal(["pending"])
}

pub fn schema_v9_creates_integration_health_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='integration_health'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> result.map(list.length)
  |> should.be_ok
  |> should.equal(1)
}

pub fn schema_v10_creates_external_asks_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO external_asks (id, source, channel_id, message_id, text, buttons_json, status, decision, requested_at_ms, updated_at_ms) VALUES ('ask-1', 'linkedin', 'ch1', 'm1', 'Challenge up', '[\"Resolved\",\"Abort\"]', 'pending', '', 1000, 1000)",
      conn,
    )

  sqlight.query(
    "SELECT status FROM external_asks WHERE id = 'ask-1'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.be_ok
  |> should.equal(["pending"])

  db_schema.get_version(conn)
  |> should.be_ok
  |> should.equal(17)
}

pub fn schema_v11_adds_neutral_flare_columns_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  // New flares columns exist and accept values
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms, dispatch_id, executor_kind, capability_manifest, context_manifest, authority_boundary, archived) VALUES ('f1', 'l', 'queued', 'd', 't', 'p', '{}', '{}', '{}', NULL, '', 1, 1, 'd1', 'aura', '{}', '{}', '{}', 0)",
      conn,
    )
  db_schema.get_version(conn)
  |> should.be_ok
  |> should.equal(17)
}

pub fn migration_v11_backfills_archived_and_executor_kind_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  // Build the legacy v10-era flares table without the v11 neutral columns
  let assert Ok(_) =
    sqlight.exec(
      "
      CREATE TABLE flares (
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
      conn,
    )
  // Seed the legacy version so the migration chain runs
  let assert Ok(_) =
    sqlight.exec("CREATE TABLE schema_version (version INTEGER NOT NULL)", conn)
  let assert Ok(_) =
    sqlight.exec("INSERT INTO schema_version (version) VALUES (10)", conn)
  // Insert a legacy archived row
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, created_at_ms, updated_at_ms) VALUES ('legacy-1', 'l', 'archived', 'd', 't', 'p', '{}', '{}', '[]', 1, 1)",
      conn,
    )
  // Running initialize triggers migrate_flares_to_v11
  db_schema.initialize(conn)
  |> should.be_ok

  db_schema.get_version(conn)
  |> should.be_ok
  |> should.equal(17)

  sqlight.query(
    "SELECT archived FROM flares WHERE id = 'legacy-1'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> should.be_ok
  |> should.equal([1])

  sqlight.query(
    "SELECT executor_kind FROM flares WHERE id = 'legacy-1'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.be_ok
  |> should.equal(["acp"])

  sqlight.close(conn)
}

pub fn schema_v11_creates_flare_attempts_and_events_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms, executor_kind) VALUES ('f1', 'l', 'queued', 'd', 't', 'p', '{}', '{}', '{}', NULL, '', 1, 1, 'acp')",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO flare_attempts (flare_id, executor_kind, status, started_at_ms) VALUES ('f1', 'acp', 'running', 1)",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO flare_events (flare_id, sequence, event_type, payload, created_at_ms) VALUES ('f1', 1, 'flare_created', '{}', 1)",
      conn,
    )
  db_schema.get_version(conn)
  |> should.be_ok
  |> should.equal(17)
}

pub fn schema_v12_creates_operational_tables_and_indexes_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)

  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('attention_queue', 'concern_links', 'mutation_receipts', 'operational_audit', 'verification_records') ORDER BY name",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.be_ok
  |> should.equal([
    "attention_queue",
    "concern_links",
    "mutation_receipts",
    "operational_audit",
    "verification_records",
  ])
  db_schema.get_version(conn)
  |> should.be_ok
  |> should.equal(17)
}

pub fn migration_v13_to_v14_preserves_queue_rows_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO attention_queue (queue_id, schema_version, decision_id, domain_id, action, summary, rationale, state, delivery_owner, delivery_key, available_at_ms, created_at_ms, updated_at_ms, version) VALUES ('queue-before', 1, 'decision-before', 'domain-before', 'surface_now', 'Summary', 'Rationale', 'pending', 'discord_compat', 'delivery-before', 1, 1, 1, 1)",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec("UPDATE schema_version SET version = 13", conn)
  let assert Ok(_) =
    sqlight.exec("DROP INDEX idx_attention_queue_authorized_route", conn)
  let assert Ok(_) =
    sqlight.exec(
      "ALTER TABLE attention_queue DROP COLUMN route_authorization_id",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "ALTER TABLE attention_queue DROP COLUMN route_activation_ids_json",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "ALTER TABLE attention_queue DROP COLUMN delivery_target",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec("ALTER TABLE attention_queue DROP COLUMN payload_hash", conn)
  let assert Ok(_) =
    sqlight.exec("DROP TABLE attention_delivery_attempts", conn)

  db_schema.initialize(conn) |> should.be_ok
  db_schema.initialize(conn) |> should.be_ok
  db_schema.get_version(conn) |> should.equal(Ok(17))
  sqlight.query(
    "SELECT queue_id, state, delivery_target, payload_hash FROM attention_queue WHERE queue_id = 'queue-before'",
    on: conn,
    with: [],
    expecting: {
      use queue_id <- decode.field(0, decode.string)
      use state <- decode.field(1, decode.string)
      use delivery_target <- decode.field(2, decode.string)
      use payload_hash <- decode.field(3, decode.string)
      decode.success(#(queue_id, state, delivery_target, payload_hash))
    },
  )
  |> should.equal(Ok([#("queue-before", "dead_letter", "", "")]))
  sqlight.query(
    "SELECT action FROM operational_audit WHERE target_id = 'queue-before' ORDER BY action",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(Ok(["attention.migration_quarantined"]))
  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='attention_delivery_attempts'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(Ok(["attention_delivery_attempts"]))
}

pub fn migration_v14_to_v15_preserves_trusted_queue_rows_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO attention_queue (queue_id, schema_version, decision_id, domain_id, event_refs_json, action, summary, rationale, state, delivery_owner, delivery_target, delivery_key, payload_hash, available_at_ms, created_at_ms, updated_at_ms, version) VALUES ('queue-v14', 1, 'decision-v14', 'domain:sample', '[\"event-v14\"]', 'surface_now', 'Summary', 'Rationale', 'pending', 'codex', 'codex_monitor', 'delivery-v14', 'trusted-hash', 1, 1, 1, 1)",
      conn,
    )
  let assert Ok(_) = sqlight.exec("DROP TABLE attention_monitor_outcomes", conn)
  let assert Ok(_) =
    sqlight.exec("UPDATE schema_version SET version = 14", conn)

  db_schema.initialize(conn) |> should.be_ok
  db_schema.initialize(conn) |> should.be_ok
  db_schema.get_version(conn) |> should.equal(Ok(17))
  sqlight.query(
    "SELECT queue_id, state, delivery_target, payload_hash FROM attention_queue WHERE queue_id = 'queue-v14'",
    on: conn,
    with: [],
    expecting: {
      use queue_id <- decode.field(0, decode.string)
      use state <- decode.field(1, decode.string)
      use target <- decode.field(2, decode.string)
      use hash <- decode.field(3, decode.string)
      decode.success(#(queue_id, state, target, hash))
    },
  )
  |> should.equal(
    Ok([#("queue-v14", "pending", "codex_monitor", "trusted-hash")]),
  )
  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='attention_monitor_outcomes'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(Ok(["attention_monitor_outcomes"]))
}

pub fn migration_v15_to_v16_preserves_existing_rows_test() {
  let root = "/tmp/aura-v15-copy-" <> test_helpers.random_suffix()
  let source_path = root <> "-source.db"
  let copied_path = root <> "-copied.db"
  let _ = simplifile.delete_all([source_path, copied_path])
  use conn <- sqlight.with_connection(source_path)
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO events (id, source, type, subject, time_ms, external_id) VALUES ('event-before-v16', 'system', 'test', 'Before v16', 1, 'before-v16')",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO attention_queue (queue_id, schema_version, decision_id, domain_id, action, summary, rationale, state, delivery_owner, delivery_target, delivery_key, payload_hash, available_at_ms, created_at_ms, updated_at_ms, version) VALUES ('queue-before-v16', 1, 'decision-before-v16', 'domain:sample', 'surface_now', 'Summary', 'Rationale', 'pending', 'discord_compat', 'default', 'delivery-before-v16', 'trusted-hash', 1, 1, 1, 1)",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec("DROP INDEX idx_attention_queue_authorized_route", conn)
  let assert Ok(_) =
    sqlight.exec(
      "ALTER TABLE attention_queue DROP COLUMN route_authorization_id",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "ALTER TABLE attention_queue DROP COLUMN route_activation_ids_json",
      conn,
    )
  let assert Ok(_) = sqlight.exec("DROP TABLE connector_read_attempts", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE connector_activations", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE canary_authorizations", conn)
  let assert Ok(_) =
    sqlight.exec("DROP TABLE canary_preparation_authorizations", conn)
  let assert Ok(_) =
    sqlight.exec("UPDATE schema_version SET version = 15", conn)
  let assert Ok(_) = sqlight.exec("VACUUM INTO '" <> copied_path <> "'", conn)

  use conn <- sqlight.with_connection(copied_path)

  db_schema.initialize(conn) |> should.be_ok
  db_schema.initialize(conn) |> should.be_ok
  db_schema.get_version(conn) |> should.equal(Ok(17))
  sqlight.query(
    "SELECT id FROM events WHERE id = 'event-before-v16'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(Ok(["event-before-v16"]))
  sqlight.query(
    "SELECT queue_id FROM attention_queue WHERE queue_id = 'queue-before-v16'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(Ok(["queue-before-v16"]))
  sqlight.query(
    "SELECT payload_hash FROM attention_queue WHERE queue_id = 'queue-before-v16'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(Ok(["trusted-hash"]))
  sqlight.query(
    "SELECT (SELECT COUNT(*) FROM events), (SELECT COUNT(*) FROM attention_queue)",
    on: conn,
    with: [],
    expecting: {
      use event_count <- decode.field(0, decode.int)
      use queue_count <- decode.field(1, decode.int)
      decode.success(#(event_count, queue_count))
    },
  )
  |> should.equal(Ok([#(1, 1)]))
  sqlight.query(
    "SELECT COUNT(*) FROM connector_activations",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> should.equal(Ok([0]))
  sqlight.query(
    "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('canary_preparation_authorizations', 'canary_authorizations', 'connector_activations', 'connector_read_attempts') ORDER BY name",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(
    Ok([
      "canary_authorizations",
      "canary_preparation_authorizations",
      "connector_activations",
      "connector_read_attempts",
    ]),
  )
  let _ = simplifile.delete_all([source_path, copied_path])
}

pub fn schema_v16_canary_authorization_rows_are_immutable_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO canary_preparation_authorizations (authorization_id, schema_version, canary_id, canonical_json, payload_hash, expires_at_ms, created_at_ms) VALUES ('preparation-v16', 1, 'canary-v16', '{}', 'hash-v16', 2, 1)",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO canary_authorizations (authorization_id, preparation_authorization_id, schema_version, canary_id, canonical_json, payload_hash, monitor_capability_hash, starts_at_ms, ends_at_ms, created_at_ms) VALUES ('authorization-v16', 'preparation-v16', 1, 'canary-v16', '{}', 'authorization-hash-v16', 'monitor-hash-v16', 1, 2, 1)",
      conn,
    )

  sqlight.exec(
    "UPDATE canary_preparation_authorizations SET payload_hash = 'changed' WHERE authorization_id = 'preparation-v16'",
    conn,
  )
  |> should.be_error
  sqlight.exec(
    "DELETE FROM canary_preparation_authorizations WHERE authorization_id = 'preparation-v16'",
    conn,
  )
  |> should.be_error
  sqlight.exec(
    "UPDATE canary_authorizations SET payload_hash = 'changed' WHERE authorization_id = 'authorization-v16'",
    conn,
  )
  |> should.be_error
  sqlight.exec(
    "DELETE FROM canary_authorizations WHERE authorization_id = 'authorization-v16'",
    conn,
  )
  |> should.be_error
}

pub fn migration_v11_to_v12_preserves_existing_rows_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO events (id, source, type, subject, time_ms, external_id) VALUES ('event-before', 'system', 'test', 'Before migration', 1, 'before')",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, created_at_ms, updated_at_ms) VALUES ('flare-before', 'Before', 'active', 'domain', 'thread', 'prompt', '{}', '[]', '[]', 1, 1)",
      conn,
    )
  let assert Ok(_) =
    sqlight.exec("UPDATE schema_version SET version = 11", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE attention_queue", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE concern_links", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE mutation_receipts", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE operational_audit", conn)
  let assert Ok(_) = sqlight.exec("DROP TABLE verification_records", conn)
  let assert Ok(_) =
    sqlight.exec("ALTER TABLE flare_events DROP COLUMN audit_id", conn)

  db_schema.initialize(conn)
  |> should.be_ok
  sqlight.query(
    "SELECT COUNT(*) FROM events WHERE id = 'event-before'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> should.be_ok
  |> should.equal([1])
  sqlight.query(
    "SELECT COUNT(*) FROM flares WHERE id = 'flare-before'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> should.be_ok
  |> should.equal([1])
  db_schema.get_version(conn)
  |> should.be_ok
  |> should.equal(17)
  sqlight.query(
    "SELECT name FROM pragma_table_info('flare_events') WHERE name = 'audit_id'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  |> should.equal(Ok(["audit_id"]))
}

pub fn schema_v12_partial_ddl_rerun_is_idempotent_test() {
  use conn <- sqlight.with_connection(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  let assert Ok(_) =
    sqlight.exec("UPDATE schema_version SET version = 11", conn)

  db_schema.initialize(conn)
  |> should.be_ok
  db_schema.get_version(conn)
  |> should.be_ok
  |> should.equal(17)
}
