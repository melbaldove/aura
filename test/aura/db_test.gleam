import aura/conversation
import aura/db
import aura/llm
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

pub fn conversation_db_roundtrip_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "roundtrip-chan", 1_000_000)

  // Save via conversation module
  let assert Ok(_) = conversation.save_to_db(subject, convo_id, "hello world", "hi back", "user1", "melbs", 1_000_000)

  // Load via conversation module
  let assert Ok(#(loaded_id, messages)) = conversation.load_from_db(subject, "discord", "roundtrip-chan", 1_000_001)
  should.equal(loaded_id, convo_id)
  should.equal(list.length(messages), 2)

  // Verify role mapping
  let assert [first, second] = messages
  case first {
    llm.UserMessage(content) -> should.equal(content, "hello world")
    _ -> should.fail()
  }
  case second {
    llm.AssistantMessage(content) -> should.equal(content, "hi back")
    _ -> should.fail()
  }

  process.send(subject, db.Shutdown)
}

pub fn system_message_roundtrip_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "sys-chan", 1_000_000)

  let assert Ok(_) = db.append_message(subject, convo_id, "system", "you are helpful", "", "", 1_000_000)
  let assert Ok(#(_, messages)) = conversation.load_from_db(subject, "discord", "sys-chan", 1_000_001)

  let assert [msg] = messages
  case msg {
    llm.SystemMessage(content) -> should.equal(content, "you are helpful")
    _ -> should.fail()
  }

  process.send(subject, db.Shutdown)
}

pub fn tool_message_roundtrip_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "tool-chan", 1_000_000)

  // Use append_message with "tool" role; tool_call_id will be empty string (no AppendMessageFull API)
  let assert Ok(_) = db.append_message(subject, convo_id, "tool", "file contents here", "", "", 1_000_000)

  let assert Ok(#(_, messages)) = conversation.load_from_db(subject, "discord", "tool-chan", 1_000_001)

  let assert [msg] = messages
  case msg {
    llm.ToolResultMessage(tool_call_id, content) -> {
      should.equal(tool_call_id, "")
      should.equal(content, "file contents here")
    }
    _ -> should.fail()
  }

  process.send(subject, db.Shutdown)
}

pub fn get_or_load_db_caches_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "cache-chan", 1_000_000)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "cached msg", "u1", "melbs", 1_000_000)

  let buffers = conversation.new()
  // First call: loads from DB
  let #(buffers2, id1, msgs1) = conversation.get_or_load_db(buffers, subject, "discord", "cache-chan", 1_000_001)
  should.equal(list.length(msgs1), 1)

  // Second call: returns from cache (same buffers)
  let #(_, id2, msgs2) = conversation.get_or_load_db(buffers2, subject, "discord", "cache-chan", 1_000_002)
  should.equal(id1, id2)
  should.equal(list.length(msgs2), 1)

  process.send(subject, db.Shutdown)
}

pub fn update_compaction_summary_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "compact-chan", 1_000_000)

  let assert Ok(_) = db.update_compaction_summary(subject, convo_id, "## Goal\nTest")

  process.send(subject, db.Shutdown)
}

pub fn set_workstream_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "ws-chan", 1_000_000)

  let assert Ok(_) = db.set_workstream(subject, convo_id, "local-accounts")

  process.send(subject, db.Shutdown)
}
