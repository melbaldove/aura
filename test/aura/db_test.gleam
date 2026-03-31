import aura/db
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn start_and_stop_test() {
  let assert Ok(subject) = db.start(":memory:")
  process.send(subject, db.Shutdown)
}

pub fn resolve_conversation_creates_new_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "123456", 1_711_843_200_000)
  should.be_true(string.length(convo_id) > 0)

  // Same platform+id returns same conversation
  let assert Ok(convo_id2) = db.resolve_conversation(subject, "discord", "123456", 1_711_843_200_000)
  should.equal(convo_id, convo_id2)

  process.send(subject, db.Shutdown)
}

pub fn append_and_load_messages_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "chan1", 1_711_843_200_000)

  let assert Ok(_) = db.append_message(subject, convo_id, "user", "hello", "user123", "melbs", 1_711_843_200_000)
  let assert Ok(_) = db.append_message(subject, convo_id, "assistant", "hi there", "", "aura", 1_711_843_200_001)

  let assert Ok(messages) = db.load_messages(subject, convo_id, 50)
  should.equal(list.length(messages), 2)

  // Verify first message
  let assert [first, ..] = messages
  should.equal(first.role, "user")
  should.equal(first.content, "hello")

  process.send(subject, db.Shutdown)
}

pub fn search_messages_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "chan1", 1_711_843_200_000)

  let assert Ok(_) = db.append_message(subject, convo_id, "user", "tell me about receipts", "u1", "melbs", 1_711_843_200_000)
  let assert Ok(_) = db.append_message(subject, convo_id, "assistant", "here are the receipt totals", "", "aura", 1_711_843_200_001)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "what about the weather", "u1", "melbs", 1_711_843_200_002)

  let assert Ok(results) = db.search(subject, "receipts", 10)
  should.equal(list.length(results), 2)

  let assert Ok(results2) = db.search(subject, "weather", 10)
  should.equal(list.length(results2), 1)

  process.send(subject, db.Shutdown)
}

pub fn cross_conversation_search_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(c1) = db.resolve_conversation(subject, "discord", "chan1", 1_711_843_200_000)
  let assert Ok(c2) = db.resolve_conversation(subject, "telegram", "chat99", 1_711_843_200_000)

  let assert Ok(_) = db.append_message(subject, c1, "user", "deploy the app", "u1", "melbs", 1_711_843_200_000)
  let assert Ok(_) = db.append_message(subject, c2, "user", "deploy the service", "u1", "melbs", 1_711_843_200_001)

  let assert Ok(results) = db.search(subject, "deploy", 10)
  should.equal(list.length(results), 2)

  process.send(subject, db.Shutdown)
}
