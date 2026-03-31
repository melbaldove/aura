import aura/db_schema
import gleam/dynamic/decode
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
  |> should.equal(1)
}
