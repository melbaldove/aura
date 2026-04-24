import aura/conversation
import aura/db
import aura/event
import aura/llm
import aura/time
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlight

pub fn main() {
  gleeunit.main()
}

pub fn start_and_stop_test() {
  let assert Ok(subject) = db.start(":memory:")
  process.send(subject, db.Shutdown)
}

pub fn resolve_conversation_creates_new_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(convo_id) =
    db.resolve_conversation(subject, "discord", "123456", 1_711_843_200_000)
  should.be_true(string.length(convo_id) > 0)

  // Same platform+id returns same conversation
  let assert Ok(convo_id2) =
    db.resolve_conversation(subject, "discord", "123456", 1_711_843_200_000)
  should.equal(convo_id, convo_id2)

  process.send(subject, db.Shutdown)
}

pub fn append_and_load_messages_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) =
    db.resolve_conversation(subject, "discord", "chan1", 1_711_843_200_000)

  let assert Ok(_) =
    db.append_message(
      subject,
      convo_id,
      "user",
      "hello",
      "user123",
      "testuser",
      1_711_843_200_000,
    )
  let assert Ok(_) =
    db.append_message(
      subject,
      convo_id,
      "assistant",
      "hi there",
      "",
      "aura",
      1_711_843_200_001,
    )

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
  let assert Ok(convo_id) =
    db.resolve_conversation(subject, "discord", "chan1", 1_711_843_200_000)

  let assert Ok(_) =
    db.append_message(
      subject,
      convo_id,
      "user",
      "tell me about receipts",
      "u1",
      "testuser",
      1_711_843_200_000,
    )
  let assert Ok(_) =
    db.append_message(
      subject,
      convo_id,
      "assistant",
      "here are the receipt totals",
      "",
      "aura",
      1_711_843_200_001,
    )
  let assert Ok(_) =
    db.append_message(
      subject,
      convo_id,
      "user",
      "what about the weather",
      "u1",
      "testuser",
      1_711_843_200_002,
    )

  let assert Ok(results) = db.search(subject, "receipts", 10)
  should.equal(list.length(results), 2)

  let assert Ok(results2) = db.search(subject, "weather", 10)
  should.equal(list.length(results2), 1)

  process.send(subject, db.Shutdown)
}

pub fn cross_conversation_search_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(c1) =
    db.resolve_conversation(subject, "discord", "chan1", 1_711_843_200_000)
  let assert Ok(c2) =
    db.resolve_conversation(subject, "telegram", "chat99", 1_711_843_200_000)

  let assert Ok(_) =
    db.append_message(
      subject,
      c1,
      "user",
      "deploy the app",
      "u1",
      "testuser",
      1_711_843_200_000,
    )
  let assert Ok(_) =
    db.append_message(
      subject,
      c2,
      "user",
      "deploy the service",
      "u1",
      "testuser",
      1_711_843_200_001,
    )

  let assert Ok(results) = db.search(subject, "deploy", 10)
  should.equal(list.length(results), 2)

  process.send(subject, db.Shutdown)
}

pub fn conversation_db_roundtrip_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) =
    db.resolve_conversation(subject, "discord", "roundtrip-chan", 1_000_000)

  // Save via db.append_message directly
  let assert Ok(_) =
    db.append_message(
      subject,
      convo_id,
      "user",
      "hello world",
      "user1",
      "testuser",
      1_000_000,
    )
  let assert Ok(_) =
    db.append_message(
      subject,
      convo_id,
      "assistant",
      "hi back",
      "",
      "aura",
      1_000_001,
    )

  // Load via conversation module
  let assert Ok(#(loaded_id, messages)) =
    conversation.load_from_db(subject, "discord", "roundtrip-chan", 1_000_001)
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
  let assert Ok(convo_id) =
    db.resolve_conversation(subject, "discord", "sys-chan", 1_000_000)

  let assert Ok(_) =
    db.append_message(
      subject,
      convo_id,
      "system",
      "you are helpful",
      "",
      "",
      1_000_000,
    )
  let assert Ok(#(_, messages)) =
    conversation.load_from_db(subject, "discord", "sys-chan", 1_000_001)

  let assert [msg] = messages
  case msg {
    llm.SystemMessage(content) -> should.equal(content, "you are helpful")
    _ -> should.fail()
  }

  process.send(subject, db.Shutdown)
}

pub fn tool_message_roundtrip_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) =
    db.resolve_conversation(subject, "discord", "tool-chan", 1_000_000)

  // Use append_message with "tool" role; tool_call_id will be empty string (no AppendMessageFull API)
  let assert Ok(_) =
    db.append_message(
      subject,
      convo_id,
      "tool",
      "file contents here",
      "",
      "",
      1_000_000,
    )

  let assert Ok(#(_, messages)) =
    conversation.load_from_db(subject, "discord", "tool-chan", 1_000_001)

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
  let assert Ok(convo_id) =
    db.resolve_conversation(subject, "discord", "cache-chan", 1_000_000)
  let assert Ok(_) =
    db.append_message(
      subject,
      convo_id,
      "user",
      "cached msg",
      "u1",
      "testuser",
      1_000_000,
    )

  let buffers = conversation.new()
  // First call: loads from DB
  let #(buffers2, id1, msgs1) =
    conversation.get_or_load_db(
      buffers,
      subject,
      "discord",
      "cache-chan",
      1_000_001,
    )
  should.equal(list.length(msgs1), 1)

  // Second call: returns from cache (same buffers)
  let #(_, id2, msgs2) =
    conversation.get_or_load_db(
      buffers2,
      subject,
      "discord",
      "cache-chan",
      1_000_002,
    )
  should.equal(id1, id2)
  should.equal(list.length(msgs2), 1)

  process.send(subject, db.Shutdown)
}

pub fn update_compaction_summary_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) =
    db.resolve_conversation(subject, "discord", "compact-chan", 1_000_000)

  let assert Ok(_) =
    db.update_compaction_summary(subject, convo_id, "## Goal\nTest")

  process.send(subject, db.Shutdown)
}

pub fn set_domain_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) =
    db.resolve_conversation(subject, "discord", "ws-chan", 1_000_000)

  let assert Ok(_) = db.set_domain(subject, convo_id, "local-accounts")

  process.send(subject, db.Shutdown)
}

pub fn load_messages_returns_newest_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(convo_id) =
    db.resolve_conversation(subject, "discord", "order-test", 1000)

  // Insert 10 messages with distinct timestamps
  let assert Ok(_) =
    db.append_message(subject, convo_id, "user", "msg 1", "", "", 1000)
  let assert Ok(_) =
    db.append_message(subject, convo_id, "user", "msg 2", "", "", 2000)
  let assert Ok(_) =
    db.append_message(subject, convo_id, "user", "msg 3", "", "", 3000)
  let assert Ok(_) =
    db.append_message(subject, convo_id, "user", "msg 4", "", "", 4000)
  let assert Ok(_) =
    db.append_message(subject, convo_id, "user", "msg 5", "", "", 5000)
  let assert Ok(_) =
    db.append_message(subject, convo_id, "user", "msg 6", "", "", 6000)
  let assert Ok(_) =
    db.append_message(subject, convo_id, "user", "msg 7", "", "", 7000)
  let assert Ok(_) =
    db.append_message(subject, convo_id, "user", "msg 8", "", "", 8000)
  let assert Ok(_) =
    db.append_message(subject, convo_id, "user", "msg 9", "", "", 9000)
  let assert Ok(_) =
    db.append_message(subject, convo_id, "user", "msg 10", "", "", 10_000)

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
  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f1",
        label: "Test flare",
        status: "active",
        domain: "work",
        thread_id: "ch1",
        original_prompt: "Do stuff",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 1000,
      ),
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
  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f1",
        label: "Active",
        status: "active",
        domain: "work",
        thread_id: "ch1",
        original_prompt: "Do stuff",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 1000,
      ),
    )
  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f2",
        label: "Archived",
        status: "archived",
        domain: "work",
        thread_id: "ch2",
        original_prompt: "Old stuff",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 1000,
      ),
    )
  let assert Ok(all) = db.load_flares(subject, False)
  list.length(all) |> should.equal(2)
  let assert Ok(active_only) = db.load_flares(subject, True)
  list.length(active_only) |> should.equal(1)
}

pub fn update_flare_status_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f1",
        label: "Test",
        status: "active",
        domain: "work",
        thread_id: "ch1",
        original_prompt: "Do stuff",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 1000,
      ),
    )
  let assert Ok(_) = db.update_flare_status(subject, "f1", "parked", 2000)
  let assert Ok(flares) = db.load_flares(subject, False)
  let assert Ok(f) = list.first(flares)
  f.status |> should.equal("parked")
  f.updated_at_ms |> should.equal(2000)
}

pub fn update_flare_session_id_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f1",
        label: "Test",
        status: "active",
        domain: "work",
        thread_id: "ch1",
        original_prompt: "Do stuff",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 1000,
      ),
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
    db.insert_memory_entry(
      subject,
      "work",
      "state",
      "current_task",
      "doing stuff",
      1000,
    )
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
    db.insert_memory_entry(
      subject,
      "work",
      "state",
      "task",
      "doing stuff",
      1000,
    )
  let assert Ok(_) =
    db.insert_memory_entry(subject, "work", "state", "mood", "focused", 2000)
  let assert Ok(_) =
    db.insert_memory_entry(
      subject,
      "work",
      "memory",
      "fact1",
      "gleam is great",
      3000,
    )

  // Should return only the two "state" entries for "work" domain
  let assert Ok(entries) =
    db.get_active_memory_entries(subject, "work", "state")
  list.length(entries) |> should.equal(2)

  // Should return only the one "memory" entry
  let assert Ok(mem_entries) =
    db.get_active_memory_entries(subject, "work", "memory")
  list.length(mem_entries) |> should.equal(1)

  // Different domain returns nothing
  let assert Ok(empty) =
    db.get_active_memory_entries(subject, "personal", "state")
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
  let assert Ok(_) = db.supersede_memory_entry(subject, old_id, new_id, 2000)

  // Only the new entry should be active
  let assert Ok(entries) =
    db.get_active_memory_entries(subject, "work", "state")
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
  let assert Ok(entries) =
    db.get_active_memory_entries(subject, "work", "state")
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
  let result2 =
    db.get_active_entry_id(subject, "work", "state", "nonexistent", 0)
  should.be_error(result2)

  process.send(subject, db.Shutdown)
}

pub fn memory_entry_fields_roundtrip_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(id) =
    db.insert_memory_entry(
      subject,
      "personal",
      "memory",
      "favorite_color",
      "blue",
      42_000,
    )

  let assert Ok(entries) =
    db.get_active_memory_entries(subject, "personal", "memory")
  let assert [entry] = entries
  entry.id |> should.equal(id)
  entry.domain |> should.equal("personal")
  entry.target |> should.equal("memory")
  entry.key |> should.equal("favorite_color")
  entry.content |> should.equal("blue")
  entry.created_at_ms |> should.equal(42_000)

  process.send(subject, db.Shutdown)
}

// ---------------------------------------------------------------------------
// Dream run tests
// ---------------------------------------------------------------------------

pub fn insert_dream_run_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(Nil) =
    db.insert_dream_run(subject, "work", 5000, "consolidate", 3, 1, 2, 1200)

  process.send(subject, db.Shutdown)
}

pub fn get_last_dream_ms_returns_latest_test() {
  let assert Ok(subject) = db.start(":memory:")

  // Insert two dream runs for the same domain with different timestamps
  let assert Ok(Nil) =
    db.insert_dream_run(subject, "work", 1000, "consolidate", 2, 0, 1, 500)
  let assert Ok(Nil) =
    db.insert_dream_run(subject, "work", 3000, "promote", 1, 1, 0, 800)

  // Should return the most recent completed_at_ms
  let assert Ok(ms) = db.get_last_dream_ms(subject, "work")
  ms |> should.equal(3000)

  process.send(subject, db.Shutdown)
}

pub fn get_last_dream_ms_returns_zero_when_none_test() {
  let assert Ok(subject) = db.start(":memory:")

  // No dream runs exist — should return 0
  let assert Ok(ms) = db.get_last_dream_ms(subject, "work")
  ms |> should.equal(0)

  process.send(subject, db.Shutdown)
}

pub fn get_last_dream_ms_scoped_to_domain_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(Nil) =
    db.insert_dream_run(subject, "work", 5000, "reflect", 0, 0, 3, 600)

  // Different domain should return 0
  let assert Ok(ms) = db.get_last_dream_ms(subject, "personal")
  ms |> should.equal(0)

  // Same domain should return the timestamp
  let assert Ok(ms2) = db.get_last_dream_ms(subject, "work")
  ms2 |> should.equal(5000)

  process.send(subject, db.Shutdown)
}

// ---------------------------------------------------------------------------
// Flare result_text tests
// ---------------------------------------------------------------------------

pub fn update_flare_result_test() {
  let assert Ok(subject) = db.start(":memory:")

  // Insert a flare first
  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f-res-1",
        label: "Build feature",
        status: "done",
        domain: "work",
        thread_id: "ch1",
        original_prompt: "Build the thing",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "sess-1",
        created_at_ms: 1000,
        updated_at_ms: 1000,
      ),
    )

  // Update its result_text
  let assert Ok(Nil) =
    db.update_flare_result(
      subject,
      "f-res-1",
      "Feature built successfully",
      2000,
    )

  // Verify by loading the flare outcomes
  let assert Ok(outcomes) = db.get_flare_outcomes(subject, "work", 0)
  list.length(outcomes) |> should.equal(1)
  let assert [#(label, result)] = outcomes
  label |> should.equal("Build feature")
  result |> should.equal("Feature built successfully")

  process.send(subject, db.Shutdown)
}

pub fn update_flare_result_updates_timestamp_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f-ts-1",
        label: "Test",
        status: "done",
        domain: "work",
        thread_id: "ch1",
        original_prompt: "Test",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 1000,
      ),
    )

  let assert Ok(Nil) = db.update_flare_result(subject, "f-ts-1", "Done", 5000)

  // Load flares to verify updated_at_ms changed
  let assert Ok(flares) = db.load_flares(subject, False)
  let assert Ok(f) = list.first(flares)
  f.updated_at_ms |> should.equal(5000)

  process.send(subject, db.Shutdown)
}

// ---------------------------------------------------------------------------
// Flare outcomes tests
// ---------------------------------------------------------------------------

pub fn get_flare_outcomes_filters_by_domain_test() {
  let assert Ok(subject) = db.start(":memory:")

  // Insert flares in two domains
  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f-d1",
        label: "Work task",
        status: "done",
        domain: "work",
        thread_id: "ch1",
        original_prompt: "Do work",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 2000,
      ),
    )
  let assert Ok(Nil) =
    db.update_flare_result(subject, "f-d1", "Work done", 2000)

  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f-d2",
        label: "Personal task",
        status: "done",
        domain: "personal",
        thread_id: "ch2",
        original_prompt: "Do personal",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 3000,
      ),
    )
  let assert Ok(Nil) =
    db.update_flare_result(subject, "f-d2", "Personal done", 3000)

  // Only work domain
  let assert Ok(work_outcomes) = db.get_flare_outcomes(subject, "work", 0)
  list.length(work_outcomes) |> should.equal(1)
  let assert [#(label, _)] = work_outcomes
  label |> should.equal("Work task")

  process.send(subject, db.Shutdown)
}

pub fn get_flare_outcomes_filters_by_since_ms_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f-old",
        label: "Old task",
        status: "done",
        domain: "work",
        thread_id: "ch1",
        original_prompt: "Old",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 1000,
      ),
    )
  let assert Ok(Nil) =
    db.update_flare_result(subject, "f-old", "Old result", 1000)

  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f-new",
        label: "New task",
        status: "done",
        domain: "work",
        thread_id: "ch2",
        original_prompt: "New",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 2000,
        updated_at_ms: 3000,
      ),
    )
  let assert Ok(Nil) =
    db.update_flare_result(subject, "f-new", "New result", 3000)

  // since_ms = 2000 should only return the newer flare (updated_at_ms > 2000)
  let assert Ok(outcomes) = db.get_flare_outcomes(subject, "work", 2000)
  list.length(outcomes) |> should.equal(1)
  let assert [#(label, _)] = outcomes
  label |> should.equal("New task")

  process.send(subject, db.Shutdown)
}

pub fn get_flare_outcomes_excludes_null_result_test() {
  let assert Ok(subject) = db.start(":memory:")

  // Flare without result_text
  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f-nores",
        label: "No result",
        status: "active",
        domain: "work",
        thread_id: "ch1",
        original_prompt: "Running",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 2000,
      ),
    )

  // Flare with result_text
  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f-hasres",
        label: "Has result",
        status: "done",
        domain: "work",
        thread_id: "ch2",
        original_prompt: "Done",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 3000,
      ),
    )
  let assert Ok(Nil) =
    db.update_flare_result(subject, "f-hasres", "Completed", 3000)

  let assert Ok(outcomes) = db.get_flare_outcomes(subject, "work", 0)
  list.length(outcomes) |> should.equal(1)
  let assert [#(label, _)] = outcomes
  label |> should.equal("Has result")

  process.send(subject, db.Shutdown)
}

pub fn get_flare_outcomes_ordered_by_updated_at_asc_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f-later",
        label: "Later task",
        status: "done",
        domain: "work",
        thread_id: "ch1",
        original_prompt: "Later",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 5000,
      ),
    )
  let assert Ok(Nil) =
    db.update_flare_result(subject, "f-later", "Later result", 5000)

  let assert Ok(_) =
    db.upsert_flare(
      subject,
      db.StoredFlare(
        id: "f-earlier",
        label: "Earlier task",
        status: "done",
        domain: "work",
        thread_id: "ch2",
        original_prompt: "Earlier",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "",
        created_at_ms: 1000,
        updated_at_ms: 2000,
      ),
    )
  let assert Ok(Nil) =
    db.update_flare_result(subject, "f-earlier", "Earlier result", 2000)

  // Results should be ordered by updated_at_ms ASC — earlier first
  let assert Ok(outcomes) = db.get_flare_outcomes(subject, "work", 0)
  list.length(outcomes) |> should.equal(2)
  let assert [#(first_label, _), #(second_label, _)] = outcomes
  first_label |> should.equal("Earlier task")
  second_label |> should.equal("Later task")

  process.send(subject, db.Shutdown)
}

// ---------------------------------------------------------------------------
// Event tests
// ---------------------------------------------------------------------------

fn sample_event(
  id: String,
  source: String,
  external_id: String,
  subject: String,
  time_ms: Int,
) -> event.AuraEvent {
  event.AuraEvent(
    id: id,
    source: source,
    type_: "message",
    subject: subject,
    time_ms: time_ms,
    tags: dict.new(),
    external_id: external_id,
    data: "{}",
  )
}

pub fn insert_event_new_returns_true_test() {
  let assert Ok(subject) = db.start(":memory:")

  let e = sample_event("e1", "gmail", "msg-1", "hello world", 1000)
  let assert Ok(inserted) = db.insert_event(subject, e)
  should.be_true(inserted)

  process.send(subject, db.Shutdown)
}

pub fn insert_event_duplicate_returns_false_test() {
  let assert Ok(subject) = db.start(":memory:")

  let first = sample_event("e1", "gmail", "msg-1", "hello world", 1000)
  let assert Ok(True) = db.insert_event(subject, first)

  // Second insert with same (source, external_id) should be ignored
  let second = sample_event("e2", "gmail", "msg-1", "different subject", 2000)
  let assert Ok(inserted) = db.insert_event(subject, second)
  should.be_false(inserted)

  process.send(subject, db.Shutdown)
}

pub fn search_events_finds_by_subject_fts_test() {
  let assert Ok(subject) = db.start(":memory:")

  let e1 = sample_event("e1", "gmail", "m1", "quarterly invoice attached", 1000)
  let e2 = sample_event("e2", "gmail", "m2", "lunch plans tomorrow", 2000)
  let assert Ok(True) = db.insert_event(subject, e1)
  let assert Ok(True) = db.insert_event(subject, e2)

  let assert Ok(results) = db.search_events(subject, "invoice", None, None, 10)
  list.length(results) |> should.equal(1)
  let assert [hit] = results
  hit.id |> should.equal("e1")
  hit.subject |> should.equal("quarterly invoice attached")

  process.send(subject, db.Shutdown)
}

pub fn search_events_filters_by_source_test() {
  let assert Ok(subject) = db.start(":memory:")

  let g = sample_event("g1", "gmail", "m1", "ship the feature", 1000)
  let l = sample_event("l1", "linear", "iss-1", "ship the feature", 2000)
  let assert Ok(True) = db.insert_event(subject, g)
  let assert Ok(True) = db.insert_event(subject, l)

  let assert Ok(results) =
    db.search_events(subject, "ship", None, Some("gmail"), 10)
  list.length(results) |> should.equal(1)
  let assert [hit] = results
  hit.source |> should.equal("gmail")

  process.send(subject, db.Shutdown)
}

pub fn search_events_filters_by_time_range_test() {
  let assert Ok(subject) = db.start(":memory:")

  let past = sample_event("p", "gmail", "p1", "budget report ready", 1000)
  let now = sample_event("n", "gmail", "n1", "budget report ready", 5000)
  let future = sample_event("f", "gmail", "f1", "budget report ready", 9000)
  let assert Ok(True) = db.insert_event(subject, past)
  let assert Ok(True) = db.insert_event(subject, now)
  let assert Ok(True) = db.insert_event(subject, future)

  // Window [3000, 7000] should only include `now`
  let assert Ok(results) =
    db.search_events(subject, "budget", Some(#(3000, 7000)), None, 10)
  list.length(results) |> should.equal(1)
  let assert [hit] = results
  hit.id |> should.equal("n")

  process.send(subject, db.Shutdown)
}

pub fn search_events_empty_query_returns_recent_test() {
  let assert Ok(subject) = db.start(":memory:")

  let e1 = sample_event("e1", "gmail", "m1", "first", 1000)
  let e2 = sample_event("e2", "gmail", "m2", "second", 2000)
  let e3 = sample_event("e3", "gmail", "m3", "third", 3000)
  let assert Ok(True) = db.insert_event(subject, e1)
  let assert Ok(True) = db.insert_event(subject, e2)
  let assert Ok(True) = db.insert_event(subject, e3)

  // Empty query bypasses FTS; results ordered by time_ms DESC
  let assert Ok(results) = db.search_events(subject, "", None, None, 10)
  list.length(results) |> should.equal(3)
  let assert [first, second, third] = results
  first.id |> should.equal("e3")
  second.id |> should.equal("e2")
  third.id |> should.equal("e1")

  process.send(subject, db.Shutdown)
}

pub fn search_events_respects_limit_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(True) =
    db.insert_event(subject, sample_event("e1", "gmail", "m1", "ping", 1000))
  let assert Ok(True) =
    db.insert_event(subject, sample_event("e2", "gmail", "m2", "ping", 2000))
  let assert Ok(True) =
    db.insert_event(subject, sample_event("e3", "gmail", "m3", "ping", 3000))
  let assert Ok(True) =
    db.insert_event(subject, sample_event("e4", "gmail", "m4", "ping", 4000))
  let assert Ok(True) =
    db.insert_event(subject, sample_event("e5", "gmail", "m5", "ping", 5000))

  let assert Ok(results) = db.search_events(subject, "ping", None, None, 2)
  list.length(results) |> should.equal(2)

  process.send(subject, db.Shutdown)
}

pub fn search_events_surfaces_malformed_tags_json_test() {
  // Regression guard for the fail-noisily path: if `tags_json` is stored as
  // non-JSON (schema corruption, bad migration, direct write), `search_events`
  // must surface a decode error instead of silently returning a broken row.
  let ts = int.to_string(time.now_ms())
  let path = "/tmp/aura-db-corrupt-tags-" <> ts <> ".db"
  let _ = simplifile.delete(path)

  let assert Ok(subject) = db.start(path)
  let assert Ok(True) =
    db.insert_event(
      subject,
      sample_event("bad", "gmail", "m-bad", "hello world", 1000),
    )

  // Bypass `tags_to_json` by writing the corrupt blob through a second
  // connection to the same file-backed DB. WAL mode makes this safe.
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "UPDATE events SET tags_json = 'not-a-json' WHERE id = 'bad'",
      on: conn,
    )

  let result = db.search_events(subject, "", None, None, 10)
  case result {
    Error(msg) ->
      should.be_true(string.starts_with(msg, "Failed to decode event tags"))
    Ok(_) -> panic as "expected decode failure on corrupt tags_json"
  }

  process.send(subject, db.Shutdown)
  let _ = simplifile.delete(path)
}

pub fn integration_checkpoint_missing_returns_none_test() {
  let assert Ok(subject) = db.start(":memory:")

  db.get_integration_checkpoint(subject, "gmail-x")
  |> should.be_ok
  |> should.equal(None)

  process.send(subject, db.Shutdown)
}

pub fn integration_checkpoint_save_and_load_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(_) =
    db.save_integration_checkpoint(subject, "gmail-x", 12_345, 4427, 1_000_000)

  db.get_integration_checkpoint(subject, "gmail-x")
  |> should.be_ok
  |> should.equal(Some(#(12_345, 4427)))

  process.send(subject, db.Shutdown)
}

pub fn integration_checkpoint_upsert_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(_) =
    db.save_integration_checkpoint(subject, "gmail-x", 100, 1, 1000)
  let assert Ok(_) =
    db.save_integration_checkpoint(subject, "gmail-x", 100, 2, 2000)
  let assert Ok(_) =
    db.save_integration_checkpoint(subject, "gmail-x", 100, 3, 3000)

  db.get_integration_checkpoint(subject, "gmail-x")
  |> should.be_ok
  |> should.equal(Some(#(100, 3)))

  process.send(subject, db.Shutdown)
}

pub fn integration_checkpoint_separate_names_test() {
  let assert Ok(subject) = db.start(":memory:")

  let assert Ok(_) =
    db.save_integration_checkpoint(subject, "gmail-a", 100, 5, 1000)
  let assert Ok(_) =
    db.save_integration_checkpoint(subject, "gmail-b", 200, 7, 1000)

  db.get_integration_checkpoint(subject, "gmail-a")
  |> should.be_ok
  |> should.equal(Some(#(100, 5)))

  db.get_integration_checkpoint(subject, "gmail-b")
  |> should.be_ok
  |> should.equal(Some(#(200, 7)))

  process.send(subject, db.Shutdown)
}

fn sample_shell_approval(
  id: String,
  channel_id: String,
) -> db.StoredShellApproval {
  db.StoredShellApproval(
    id: id,
    channel_id: channel_id,
    message_id: "msg-" <> id,
    command: "rm -rf /tmp/nope",
    reason: "dangerous command",
    status: "pending",
    requested_at_ms: 1000,
    updated_at_ms: 1000,
  )
}

pub fn shell_approval_load_pending_and_status_transition_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(_) =
    db.save_shell_approval(subject, sample_shell_approval("sh1", "ch1"))
  let assert Ok(_) =
    db.save_shell_approval(subject, sample_shell_approval("sh2", "ch2"))

  let assert Ok(cancelled) =
    db.load_pending_shell_approvals_for_channel(subject, "ch1")
  cancelled |> list.length |> should.equal(1)
  let assert [approval] = cancelled
  approval.id |> should.equal("sh1")
  approval.status |> should.equal("pending")

  let assert Ok(_) =
    db.update_shell_approval_status(subject, "sh1", "restart_cancelled", 2000)

  db.load_pending_shell_approvals_for_channel(subject, "ch1")
  |> should.be_ok
  |> should.equal([])

  let assert Ok(cancelled_other_channel) =
    db.load_pending_shell_approvals_for_channel(subject, "ch2")
  cancelled_other_channel |> list.length |> should.equal(1)

  process.send(subject, db.Shutdown)
}

pub fn shell_approval_status_update_is_pending_only_test() {
  let assert Ok(subject) = db.start(":memory:")
  let assert Ok(_) =
    db.save_shell_approval(subject, sample_shell_approval("sh1", "ch1"))

  let assert Ok(_) =
    db.update_shell_approval_status(subject, "sh1", "rejected", 2000)
  case db.update_shell_approval_status(subject, "sh1", "expired", 3000) {
    Ok(_) -> should.fail()
    Error(e) ->
      string.starts_with(e, "Shell approval is not pending") |> should.be_true
  }

  db.load_pending_shell_approvals_for_channel(subject, "ch1")
  |> should.be_ok
  |> should.equal([])

  process.send(subject, db.Shutdown)
}
