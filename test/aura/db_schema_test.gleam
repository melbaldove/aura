import aura/db_schema
import gleam/dynamic/decode
import gleam/list
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
  |> should.equal(4)
}

pub fn schema_v3_creates_flares_table_test() {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(_) = db_schema.initialize(conn)
  // Verify flares table exists by inserting a row
  let assert Ok(_) = sqlight.exec(
    "INSERT INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, created_at_ms, updated_at_ms) VALUES ('test-id', 'test', 'active', 'work', 'ch1', 'do stuff', '{}', '[]', '[]', 1000, 1000)",
    conn,
  )
  let assert Ok(rows) = sqlight.query(
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
  let assert Ok(_) = sqlight.exec(
    "INSERT INTO memory_entries (domain, target, key, content, created_at_ms) VALUES ('work', 'state', 'project_status', 'on track', 1000)",
    conn,
  )
  let assert Ok(rows) = sqlight.query(
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
  let assert Ok(_) = sqlight.exec(
    "INSERT INTO dream_runs (domain, completed_at_ms, phase_reached) VALUES ('work', 1000, 'consolidate')",
    conn,
  )
  let assert Ok(rows) = sqlight.query(
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
  let assert Ok(_) = sqlight.exec(
    "INSERT INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, created_at_ms, updated_at_ms, result_text) VALUES ('test-id', 'test', 'active', 'work', 'ch1', 'do stuff', '{}', '[]', '[]', 1000, 1000, 'some result')",
    conn,
  )
  let assert Ok(rows) = sqlight.query(
    "SELECT result_text FROM flares WHERE id = 'test-id'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.string),
  )
  rows |> should.equal(["some result"])
}
