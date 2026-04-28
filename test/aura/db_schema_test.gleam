import aura/db_schema
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleeunit
import gleeunit/should
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
  |> should.equal(7)
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
  |> should.equal(7)
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
