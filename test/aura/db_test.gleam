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

  let assert Ok(_) = db.append_message(subject, convo_id, "user", "hello", "user123", "testuser", 1_711_843_200_000)
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

  let assert Ok(_) = db.append_message(subject, convo_id, "user", "tell me about receipts", "u1", "testuser", 1_711_843_200_000)
  let assert Ok(_) = db.append_message(subject, convo_id, "assistant", "here are the receipt totals", "", "aura", 1_711_843_200_001)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "what about the weather", "u1", "testuser", 1_711_843_200_002)

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

  let assert Ok(_) = db.append_message(subject, c1, "user", "deploy the app", "u1", "testuser", 1_711_843_200_000)
  let assert Ok(_) = db.append_message(subject, c2, "user", "deploy the service", "u1", "testuser", 1_711_843_200_001)

  let assert Ok(results) = db.search(subject, "deploy", 10)
  should.equal(list.length(results), 2)

  process.send(subject, db.Shutdown)
}

pub fn conversation_db_roundtrip_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "roundtrip-chan", 1_000_000)

  // Save via db.append_message directly
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "hello world", "user1", "testuser", 1_000_000)
  let assert Ok(_) = db.append_message(subject, convo_id, "assistant", "hi back", "", "aura", 1_000_001)

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
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "cached msg", "u1", "testuser", 1_000_000)

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

pub fn set_domain_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "ws-chan", 1_000_000)

  let assert Ok(_) = db.set_domain(subject, convo_id, "local-accounts")

  process.send(subject, db.Shutdown)
}

pub fn load_messages_returns_newest_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) = db.resolve_conversation(subject, "discord", "order-test", 1000)

  // Insert 10 messages with distinct timestamps
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "msg 1", "", "", 1000)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "msg 2", "", "", 2000)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "msg 3", "", "", 3000)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "msg 4", "", "", 4000)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "msg 5", "", "", 5000)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "msg 6", "", "", 6000)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "msg 7", "", "", 7000)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "msg 8", "", "", 8000)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "msg 9", "", "", 9000)
  let assert Ok(_) = db.append_message(subject, convo_id, "user", "msg 10", "", "", 10_000)

  // Load only 4 — should be the NEWEST 4, in chronological order
  let assert Ok(messages) = db.load_messages(subject, convo_id, 4)
  should.equal(list.length(messages), 4)

  // Verify we got the newest messages, not the oldest
  let assert [m1, m2, m3, m4] = messages
  should.equal(m1.content, "msg 7")
  should.equal(m2.content, "msg 8")
  should.equal(m3.content, "msg 9")
  should.equal(m4.content, "msg 10")

  // Verify chronological order (ascending timestamps)
  should.be_true(m1.created_at < m2.created_at)
  should.be_true(m2.created_at < m3.created_at)
  should.be_true(m3.created_at < m4.created_at)

  process.send(subject, db.Shutdown)
}

pub fn upsert_and_load_flare_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(_) = db.upsert_flare(
    subject,
    db.StoredFlare(id: "f1", label: "Test flare", status: "active", domain: "work", thread_id: "ch1", original_prompt: "Do stuff", execution: "{}", triggers: "[]", tools: "[]", workspace: "", session_id: "", created_at_ms: 1000, updated_at_ms: 1000),
  )
  let assert Ok(flares) = db.load_flares(subject, False)
  list.length(flares) |> should.equal(1)
  let assert Ok(f) = list.first(flares)
  f.id |> should.equal("f1")
  f.label |> should.equal("Test flare")
  f.status |> should.equal("active")
}

pub fn load_flares_excludes_archived_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(_) = db.upsert_flare(
    subject,
    db.StoredFlare(id: "f1", label: "Active", status: "active", domain: "work", thread_id: "ch1", original_prompt: "Do stuff", execution: "{}", triggers: "[]", tools: "[]", workspace: "", session_id: "", created_at_ms: 1000, updated_at_ms: 1000),
  )
  let assert Ok(_) = db.upsert_flare(
    subject,
    db.StoredFlare(id: "f2", label: "Archived", status: "archived", domain: "work", thread_id: "ch2", original_prompt: "Old stuff", execution: "{}", triggers: "[]", tools: "[]", workspace: "", session_id: "", created_at_ms: 1000, updated_at_ms: 1000),
  )
  let assert Ok(all) = db.load_flares(subject, False)
  list.length(all) |> should.equal(2)
  let assert Ok(active_only) = db.load_flares(subject, True)
  list.length(active_only) |> should.equal(1)
}

pub fn update_flare_status_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(_) = db.upsert_flare(
    subject,
    db.StoredFlare(id: "f1", label: "Test", status: "active", domain: "work", thread_id: "ch1", original_prompt: "Do stuff", execution: "{}", triggers: "[]", tools: "[]", workspace: "", session_id: "", created_at_ms: 1000, updated_at_ms: 1000),
  )
  let assert Ok(_) = db.update_flare_status(subject, "f1", "parked", 2000)
  let assert Ok(flares) = db.load_flares(subject, False)
  let assert Ok(f) = list.first(flares)
  f.status |> should.equal("parked")
  f.updated_at_ms |> should.equal(2000)
}

pub fn update_flare_session_id_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(_) = db.upsert_flare(
    subject,
    db.StoredFlare(id: "f1", label: "Test", status: "active", domain: "work", thread_id: "ch1", original_prompt: "Do stuff", execution: "{}", triggers: "[]", tools: "[]", workspace: "", session_id: "", created_at_ms: 1000, updated_at_ms: 1000),
  )
  let assert Ok(_) = db.update_flare_session_id(subject, "f1", "sess-123", 2000)
  let assert Ok(flares) = db.load_flares(subject, False)
  let assert Ok(f) = list.first(flares)
  f.session_id |> should.equal("sess-123")
}

// ---------------------------------------------------------------------------
// Memory entry tests
// ---------------------------------------------------------------------------

pub fn insert_memory_entry_returns_id_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(id) =
    db.insert_memory_entry(subject, "work", "state", "current_task", "doing stuff", 1000)
  should.be_true(id > 0)
  process.send(subject, db.Shutdown)
}

pub fn insert_memory_entry_increments_id_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(id1) =
    db.insert_memory_entry(subject, "work", "state", "key1", "content1", 1000)
  let assert Ok(id2) =
    db.insert_memory_entry(subject, "work", "state", "key2", "content2", 2000)
  should.be_true(id2 > id1)
  process.send(subject, db.Shutdown)
}

pub fn get_active_memory_entries_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(_) =
    db.insert_memory_entry(subject, "work", "state", "task", "doing stuff", 1000)
  let assert Ok(_) =
    db.insert_memory_entry(subject, "work", "state", "mood", "focused", 2000)
  let assert Ok(_) =
    db.insert_memory_entry(subject, "work", "memory", "fact1", "gleam is great", 3000)

  // Should return only the two "state" entries for "work" domain
  let assert Ok(entries) = db.get_active_memory_entries(subject, "work", "state")
  list.length(entries) |> should.equal(2)

  // Should return only the one "memory" entry
  let assert Ok(mem_entries) = db.get_active_memory_entries(subject, "work", "memory")
  list.length(mem_entries) |> should.equal(1)

  // Different domain returns nothing
  let assert Ok(empty) = db.get_active_memory_entries(subject, "personal", "state")
  list.length(empty) |> should.equal(0)

  process.send(subject, db.Shutdown)
}

pub fn get_active_memory_entries_excludes_superseded_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(old_id) =
    db.insert_memory_entry(subject, "work", "state", "task", "old task", 1000)
  let assert Ok(new_id) =
    db.insert_memory_entry(subject, "work", "state", "task", "new task", 2000)

  // Supersede the old entry
  let assert Ok(_) =
    db.supersede_memory_entry(subject, old_id, new_id, 2000)

  // Only the new entry should be active
  let assert Ok(entries) = db.get_active_memory_entries(subject, "work", "state")
  list.length(entries) |> should.equal(1)
  let assert [entry] = entries
  entry.id |> should.equal(new_id)
  entry.content |> should.equal("new task")

  process.send(subject, db.Shutdown)
}

pub fn supersede_memory_entry_idempotent_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(old_id) =
    db.insert_memory_entry(subject, "work", "state", "task", "old task", 1000)
  let assert Ok(new_id) =
    db.insert_memory_entry(subject, "work", "state", "task", "new task", 2000)
  let assert Ok(newer_id) =
    db.insert_memory_entry(subject, "work", "state", "task", "newer task", 3000)

  // Supersede old entry with new_id
  let assert Ok(_) = db.supersede_memory_entry(subject, old_id, new_id, 2000)

  // Try to re-supersede old entry with newer_id — should be a no-op
  let assert Ok(_) = db.supersede_memory_entry(subject, old_id, newer_id, 3000)

  // Verify old entry still points to new_id (not newer_id)
  // We check by getting active entries — old should still be superseded
  let assert Ok(entries) = db.get_active_memory_entries(subject, "work", "state")
  // new_id and newer_id should be active, old_id should be superseded
  list.length(entries) |> should.equal(2)

  process.send(subject, db.Shutdown)
}

pub fn get_active_entry_id_finds_old_entry_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(old_id) =
    db.insert_memory_entry(subject, "work", "state", "task", "old task", 1000)
  let assert Ok(new_id) =
    db.insert_memory_entry(subject, "work", "state", "task", "new task", 2000)

  // Should find old_id when excluding new_id
  let assert Ok(found_id) =
    db.get_active_entry_id(subject, "work", "state", "task", new_id)
  found_id |> should.equal(old_id)

  process.send(subject, db.Shutdown)
}

pub fn get_active_entry_id_returns_error_when_none_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(id) =
    db.insert_memory_entry(subject, "work", "state", "task", "only task", 1000)

  // No other active entry with this key — should error
  let result = db.get_active_entry_id(subject, "work", "state", "task", id)
  should.be_error(result)

  // Totally nonexistent key — should also error
  let result2 = db.get_active_entry_id(subject, "work", "state", "nonexistent", 0)
  should.be_error(result2)

  process.send(subject, db.Shutdown)
}

pub fn memory_entry_fields_roundtrip_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(id) =
    db.insert_memory_entry(subject, "personal", "memory", "favorite_color", "blue", 42_000)

  let assert Ok(entries) = db.get_active_memory_entries(subject, "personal", "memory")
  let assert [entry] = entries
  entry.id |> should.equal(id)
  entry.domain |> should.equal("personal")
  entry.target |> should.equal("memory")
  entry.key |> should.equal("favorite_color")
  entry.content |> should.equal("blue")
  entry.created_at_ms |> should.equal(42_000)

  process.send(subject, db.Shutdown)
}
