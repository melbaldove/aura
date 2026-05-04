import aura/db_schema
import aura/dream_effect
import aura/event
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import sqlight

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A message row as loaded from the database.
/// `created_at` is milliseconds since epoch; `tool_calls` and `tool_call_id`
/// are JSON strings, empty string when absent.
pub type StoredMessage {
  StoredMessage(
    id: Int,
    conversation_id: String,
    role: String,
    content: String,
    author_id: String,
    author_name: String,
    tool_call_id: String,
    tool_calls: String,
    tool_name: String,
    created_at: Int,
  )
}

/// A single FTS5 search hit. `snippet` contains the matched excerpt with
/// `>>>` / `<<<` highlights; `content` is the full message body.
pub type SearchResult {
  SearchResult(
    conversation_id: String,
    role: String,
    snippet: String,
    content: String,
    author_name: String,
    created_at: Int,
    platform: String,
    platform_id: String,
  )
}

pub type StoredFlare {
  StoredFlare(
    id: String,
    label: String,
    status: String,
    domain: String,
    thread_id: String,
    original_prompt: String,
    execution: String,
    triggers: String,
    tools: String,
    workspace: String,
    session_id: String,
    created_at_ms: Int,
    updated_at_ms: Int,
  )
}

/// A shell approval request posted to Discord.
///
/// `status` is one of: pending, approved, rejected, expired, superseded, or
/// restart_cancelled. Only `pending` rows may transition.
pub type StoredShellApproval {
  StoredShellApproval(
    id: String,
    channel_id: String,
    message_id: String,
    command: String,
    reason: String,
    status: String,
    requested_at_ms: Int,
    updated_at_ms: Int,
  )
}

/// A memory entry row from the memory_entries table.
/// Represents a keyed piece of knowledge with optional supersession chain.
pub type MemoryEntry {
  MemoryEntry(
    id: Int,
    domain: String,
    target: String,
    key: String,
    content: String,
    created_at_ms: Int,
  )
}

type DreamRunWriteCounts {
  DreamRunWriteCounts(actual_writes: Int, noops: Int)
}

/// Internal actor message type for the DB actor.
/// Callers should use the public convenience functions (`append_message`,
/// `load_messages`, etc.) rather than sending these variants directly.
pub type DbMessage {
  Shutdown
  ResolveConversation(
    reply_to: process.Subject(Result(String, String)),
    platform: String,
    platform_id: String,
    timestamp: Int,
  )
  AppendMessage(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    role: String,
    content: String,
    author_id: String,
    author_name: String,
    timestamp: Int,
  )
  LoadMessages(
    reply_to: process.Subject(Result(List(StoredMessage), String)),
    conversation_id: String,
    limit: Int,
  )
  Search(
    reply_to: process.Subject(Result(List(SearchResult), String)),
    query: String,
    limit: Int,
  )
  UpdateCompactionSummary(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    summary: String,
  )
  UpdateLastActive(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    timestamp: Int,
  )
  SetDomain(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    domain: String,
  )
  GetCompactionSummary(
    reply_to: process.Subject(Result(String, String)),
    conversation_id: String,
  )
  HasMessages(reply_to: process.Subject(Result(Bool, String)))
  AppendMessageFull(
    reply_to: process.Subject(Result(Nil, String)),
    conversation_id: String,
    role: String,
    content: String,
    author_id: String,
    author_name: String,
    tool_call_id: String,
    tool_calls: String,
    timestamp: Int,
  )
  UpsertFlare(
    reply_to: process.Subject(Result(Nil, String)),
    stored: StoredFlare,
  )
  LoadFlares(
    reply_to: process.Subject(Result(List(StoredFlare), String)),
    exclude_archived: Bool,
  )
  UpdateFlareStatus(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    status: String,
    updated_at_ms: Int,
  )
  UpdateFlareSessionId(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    session_id: String,
    updated_at_ms: Int,
  )
  UpdateFlareRekindle(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    session_id: String,
    status: String,
    updated_at_ms: Int,
  )
  InsertMemoryEntry(
    reply_to: process.Subject(Result(Int, String)),
    domain: String,
    target: String,
    key: String,
    content: String,
    created_at_ms: Int,
  )
  SupersedeMemoryEntry(
    reply_to: process.Subject(Result(Nil, String)),
    entry_id: Int,
    superseded_by: Int,
    superseded_at_ms: Int,
  )
  GetActiveMemoryEntries(
    reply_to: process.Subject(Result(List(MemoryEntry), String)),
    domain: String,
    target: String,
  )
  GetActiveMemoryEntryByKey(
    reply_to: process.Subject(Result(Option(MemoryEntry), String)),
    domain: String,
    target: String,
    key: String,
  )
  GetActiveEntryId(
    reply_to: process.Subject(Result(Int, String)),
    domain: String,
    target: String,
    key: String,
    exclude_id: Int,
  )
  InsertDreamRun(
    reply_to: process.Subject(Result(Int, String)),
    domain: String,
    completed_at_ms: Int,
    phase_reached: String,
    entries_consolidated: Int,
    entries_promoted: Int,
    reflections_generated: Int,
    duration_ms: Int,
    entries_rendered: Int,
    entries_noop: Int,
    action_candidates_count: Int,
  )
  InsertDreamRunEffect(
    reply_to: process.Subject(Result(Int, String)),
    dream_run_id: Int,
    effect: dream_effect.DreamEffect,
  )
  InsertDreamActionCandidate(
    reply_to: process.Subject(Result(Int, String)),
    dream_run_id: Int,
    candidate: dream_effect.ActionCandidate,
    created_at_ms: Int,
  )
  GetLastDreamMs(reply_to: process.Subject(Result(Int, String)), domain: String)
  GetRecentNoopDreamRunCount(
    reply_to: process.Subject(Result(Int, String)),
    domain: String,
    limit: Int,
  )
  UpdateFlareResult(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    result_text: String,
    updated_at_ms: Int,
  )
  GetFlareOutcomes(
    reply_to: process.Subject(Result(List(#(String, String)), String)),
    domain: String,
    since_ms: Int,
  )
  GetCompactionSummaries(
    reply_to: process.Subject(Result(List(String), String)),
    domain: String,
  )
  InsertEvent(
    reply_to: process.Subject(Result(Bool, String)),
    event: event.AuraEvent,
  )
  GetEvent(
    reply_to: process.Subject(Result(Option(event.AuraEvent), String)),
    id: String,
  )
  SearchEvents(
    reply_to: process.Subject(Result(List(event.AuraEvent), String)),
    query: String,
    time_range_ms: Option(#(Int, Int)),
    source: Option(String),
    limit: Int,
  )
  GetIntegrationCheckpoint(
    reply_to: process.Subject(Result(Option(#(Int, Int)), String)),
    name: String,
  )
  SaveIntegrationCheckpoint(
    reply_to: process.Subject(Result(Nil, String)),
    name: String,
    uidvalidity: Int,
    last_seen_uid: Int,
    now_ms: Int,
  )
  SaveShellApproval(
    reply_to: process.Subject(Result(Nil, String)),
    approval: StoredShellApproval,
  )
  UpdateShellApprovalStatus(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    status: String,
    updated_at_ms: Int,
  )
  LoadPendingShellApprovalsForChannel(
    reply_to: process.Subject(Result(List(StoredShellApproval), String)),
    channel_id: String,
  )
}

type DbState {
  DbState(conn: sqlight.Connection)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Open (or create) the SQLite database at `path`, initialize the schema,
/// and return a subject for sending `DbMessage` requests to the actor.
pub fn start(path: String) -> Result(process.Subject(DbMessage), String) {
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      case sqlight.open(path) {
        Ok(conn) -> {
          case db_schema.initialize(conn) {
            Ok(Nil) -> {
              let state = DbState(conn: conn)
              Ok(actor.initialised(state) |> actor.returning(subject))
            }
            Error(err) -> Error("Failed to initialize schema: " <> err)
          }
        }
        Error(err) -> Error("Failed to open database: " <> string.inspect(err))
      }
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(err) -> Error("Failed to start db actor: " <> string.inspect(err))
  }
}

/// Look up a conversation by `(platform, platform_id)`, creating one if it
/// does not yet exist. Returns the conversation's string ID.
pub fn resolve_conversation(
  subject: process.Subject(DbMessage),
  platform: String,
  platform_id: String,
  timestamp: Int,
) -> Result(String, String) {
  process.call(subject, 5000, fn(reply_to) {
    ResolveConversation(
      reply_to: reply_to,
      platform: platform,
      platform_id: platform_id,
      timestamp: timestamp,
    )
  })
}

/// Append a new message row to an existing conversation.
pub fn append_message(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  role: String,
  content: String,
  author_id: String,
  author_name: String,
  timestamp: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    AppendMessage(
      reply_to: reply_to,
      conversation_id: conversation_id,
      role: role,
      content: content,
      author_id: author_id,
      author_name: author_name,
      timestamp: timestamp,
    )
  })
}

/// Load the most recent `limit` messages for a conversation, ordered oldest first.
pub fn load_messages(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  limit: Int,
) -> Result(List(StoredMessage), String) {
  process.call(subject, 5000, fn(reply_to) {
    LoadMessages(
      reply_to: reply_to,
      conversation_id: conversation_id,
      limit: limit,
    )
  })
}

/// Full-text search across all messages using FTS5. Returns up to `limit`
/// results ranked by relevance, with highlighted snippets.
pub fn search(
  subject: process.Subject(DbMessage),
  query: String,
  limit: Int,
) -> Result(List(SearchResult), String) {
  process.call(subject, 5000, fn(reply_to) {
    Search(reply_to: reply_to, query: query, limit: limit)
  })
}

/// Store a compaction summary for a conversation, replacing any prior value.
pub fn update_compaction_summary(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  summary: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateCompactionSummary(
      reply_to: reply_to,
      conversation_id: conversation_id,
      summary: summary,
    )
  })
}

/// Get the compaction summary for a conversation.
pub fn get_compaction_summary(
  subject: process.Subject(DbMessage),
  conversation_id: String,
) -> Result(String, String) {
  process.call(subject, 5000, fn(reply_to) {
    GetCompactionSummary(reply_to: reply_to, conversation_id: conversation_id)
  })
}

/// Update the `last_active_at` timestamp (ms since epoch) for a conversation.
pub fn update_last_active(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  timestamp: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateLastActive(
      reply_to: reply_to,
      conversation_id: conversation_id,
      timestamp: timestamp,
    )
  })
}

/// Assign a domain label to a conversation.
pub fn set_domain(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  domain: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    SetDomain(
      reply_to: reply_to,
      conversation_id: conversation_id,
      domain: domain,
    )
  })
}

/// Append a message with full tool call metadata (tool_call_id, tool_calls JSON).
/// Used when persisting the complete tool call chain.
pub fn append_message_full(
  subject: process.Subject(DbMessage),
  conversation_id: String,
  role: String,
  content: String,
  author_id: String,
  author_name: String,
  tool_call_id: String,
  tool_calls: String,
  timestamp: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    AppendMessageFull(
      reply_to: reply_to,
      conversation_id: conversation_id,
      role: role,
      content: content,
      author_id: author_id,
      author_name: author_name,
      tool_call_id: tool_call_id,
      tool_calls: tool_calls,
      timestamp: timestamp,
    )
  })
}

/// Check if the database has any messages at all.
/// Used by migration to avoid double-importing JSONL files.
pub fn has_messages(subject: process.Subject(DbMessage)) -> Result(Bool, String) {
  process.call(subject, 5000, fn(reply_to) { HasMessages(reply_to: reply_to) })
}

/// Insert or replace a flare record.
pub fn upsert_flare(
  subject: process.Subject(DbMessage),
  stored: StoredFlare,
) -> Result(Nil, String) {
  process.call(subject, 10_000, fn(reply_to) { UpsertFlare(reply_to:, stored:) })
}

/// Load all flares, optionally excluding archived ones.
pub fn load_flares(
  subject: process.Subject(DbMessage),
  exclude_archived: Bool,
) -> Result(List(StoredFlare), String) {
  process.call(subject, 10_000, fn(reply_to) {
    LoadFlares(reply_to:, exclude_archived:)
  })
}

/// Update the status of a flare.
pub fn update_flare_status(
  subject: process.Subject(DbMessage),
  id: String,
  status: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateFlareStatus(reply_to:, id:, status:, updated_at_ms:)
  })
}

/// Update the session_id of a flare.
pub fn update_flare_session_id(
  subject: process.Subject(DbMessage),
  id: String,
  session_id: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateFlareSessionId(reply_to:, id:, session_id:, updated_at_ms:)
  })
}

/// Atomically update a flare's session_id and status (used by rekindle).
pub fn update_flare_rekindle(
  subject: process.Subject(DbMessage),
  id: String,
  session_id: String,
  status: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateFlareRekindle(reply_to:, id:, session_id:, status:, updated_at_ms:)
  })
}

/// Insert a new memory entry and return its auto-generated id.
pub fn insert_memory_entry(
  subject: process.Subject(DbMessage),
  domain: String,
  target: String,
  key: String,
  content: String,
  created_at_ms: Int,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    InsertMemoryEntry(
      reply_to:,
      domain:,
      target:,
      key:,
      content:,
      created_at_ms:,
    )
  })
}

/// Mark a memory entry as superseded by another entry.
/// Only updates if the entry has not already been superseded (idempotent).
pub fn supersede_memory_entry(
  subject: process.Subject(DbMessage),
  entry_id: Int,
  superseded_by: Int,
  superseded_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    SupersedeMemoryEntry(
      reply_to:,
      entry_id:,
      superseded_by:,
      superseded_at_ms:,
    )
  })
}

/// Return all active (non-superseded) memory entries for a domain and target.
pub fn get_active_memory_entries(
  subject: process.Subject(DbMessage),
  domain: String,
  target: String,
) -> Result(List(MemoryEntry), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetActiveMemoryEntries(reply_to:, domain:, target:)
  })
}

/// Return the active memory entry for an exact domain/target/key, if present.
pub fn get_active_memory_entry_by_key(
  subject: process.Subject(DbMessage),
  domain: String,
  target: String,
  key: String,
) -> Result(Option(MemoryEntry), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetActiveMemoryEntryByKey(reply_to:, domain:, target:, key:)
  })
}

/// Find the active entry matching domain/target/key, excluding a specific id.
/// Used during write-through to find the old entry to supersede after inserting
/// a new one. Returns Error if no matching entry is found.
pub fn get_active_entry_id(
  subject: process.Subject(DbMessage),
  domain: String,
  target: String,
  key: String,
  exclude_id: Int,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    GetActiveEntryId(reply_to:, domain:, target:, key:, exclude_id:)
  })
}

/// Insert a dream run record.
pub fn insert_dream_run(
  subject: process.Subject(DbMessage),
  domain: String,
  completed_at_ms: Int,
  phase_reached: String,
  entries_consolidated: Int,
  entries_promoted: Int,
  reflections_generated: Int,
  duration_ms: Int,
  entries_rendered: Int,
  entries_noop: Int,
  action_candidates_count: Int,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    InsertDreamRun(
      reply_to:,
      domain:,
      completed_at_ms:,
      phase_reached:,
      entries_consolidated:,
      entries_promoted:,
      reflections_generated:,
      duration_ms:,
      entries_rendered:,
      entries_noop:,
      action_candidates_count:,
    )
  })
}

/// Insert one structured effect produced by a dream run.
pub fn insert_dream_run_effect(
  subject: process.Subject(DbMessage),
  dream_run_id: Int,
  effect: dream_effect.DreamEffect,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    InsertDreamRunEffect(reply_to:, dream_run_id:, effect:)
  })
}

/// Insert one deterministic action candidate produced by a dream run.
pub fn insert_dream_action_candidate(
  subject: process.Subject(DbMessage),
  dream_run_id: Int,
  candidate: dream_effect.ActionCandidate,
  created_at_ms: Int,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    InsertDreamActionCandidate(
      reply_to:,
      dream_run_id:,
      candidate:,
      created_at_ms:,
    )
  })
}

/// Return the `completed_at_ms` of the most recent dream run for this domain.
/// Returns 0 if no dream runs exist (safe default meaning "dream all history").
pub fn get_last_dream_ms(
  subject: process.Subject(DbMessage),
  domain: String,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    GetLastDreamMs(reply_to:, domain:)
  })
}

/// Return the number of latest consecutive dream runs that produced no writes
/// and at least one no-op effect for a domain.
pub fn get_recent_noop_dream_run_count(
  subject: process.Subject(DbMessage),
  domain: String,
  limit: Int,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    GetRecentNoopDreamRunCount(reply_to:, domain:, limit:)
  })
}

/// Update the result_text and updated_at_ms on a flare.
pub fn update_flare_result(
  subject: process.Subject(DbMessage),
  id: String,
  result_text: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateFlareResult(reply_to:, id:, result_text:, updated_at_ms:)
  })
}

/// Return (label, result_text) pairs for completed flares in this domain
/// with non-null result_text, where updated_at_ms > since_ms.
pub fn get_flare_outcomes(
  subject: process.Subject(DbMessage),
  domain: String,
  since_ms: Int,
) -> Result(List(#(String, String)), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetFlareOutcomes(reply_to:, domain:, since_ms:)
  })
}

/// Return non-empty compaction summaries for conversations in this domain.
pub fn get_compaction_summaries(
  subject: process.Subject(DbMessage),
  domain: String,
) -> Result(List(String), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetCompactionSummaries(reply_to:, domain:)
  })
}

/// Insert an ambient event. Returns `True` if a new row was written, or
/// `False` if the (source, external_id) pair already existed and the insert
/// was ignored. Use this to make event ingestion idempotent.
pub fn insert_event(
  subject: process.Subject(DbMessage),
  event: event.AuraEvent,
) -> Result(Bool, String) {
  process.call(subject, 5000, fn(reply_to) {
    InsertEvent(reply_to: reply_to, event: event)
  })
}

/// Load one ambient event by its primary event ID.
pub fn get_event(
  subject: process.Subject(DbMessage),
  id: String,
) -> Result(Option(event.AuraEvent), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetEvent(reply_to: reply_to, id: id)
  })
}

/// Search ambient events. An empty `query` skips the FTS MATCH and returns
/// rows ordered by `time_ms DESC`, subject to the optional filters. A
/// non-empty `query` matches against `events_fts` (source/type/subject/tags/data).
pub fn search_events(
  subject: process.Subject(DbMessage),
  query: String,
  time_range_ms: Option(#(Int, Int)),
  source: Option(String),
  limit: Int,
) -> Result(List(event.AuraEvent), String) {
  process.call(subject, 5000, fn(reply_to) {
    SearchEvents(
      reply_to: reply_to,
      query: query,
      time_range_ms: time_range_ms,
      source: source,
      limit: limit,
    )
  })
}

/// Load a per-integration IMAP checkpoint. Returns `Ok(None)` when no
/// checkpoint has been saved yet, `Ok(Some(#(uidvalidity, last_seen_uid)))`
/// otherwise. Used by integrations that need to resume cleanly after a
/// restart without missing messages that arrived during downtime.
pub fn get_integration_checkpoint(
  subject: process.Subject(DbMessage),
  name: String,
) -> Result(Option(#(Int, Int)), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetIntegrationCheckpoint(reply_to: reply_to, name: name)
  })
}

/// Upsert a per-integration IMAP checkpoint. Call after every successful
/// ingest so a crash or deploy doesn't re-ingest already-seen messages.
pub fn save_integration_checkpoint(
  subject: process.Subject(DbMessage),
  name: String,
  uidvalidity: Int,
  last_seen_uid: Int,
  now_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    SaveIntegrationCheckpoint(
      reply_to: reply_to,
      name: name,
      uidvalidity: uidvalidity,
      last_seen_uid: last_seen_uid,
      now_ms: now_ms,
    )
  })
}

/// Persist a pending shell approval request before waiting for a Discord click.
pub fn save_shell_approval(
  subject: process.Subject(DbMessage),
  approval: StoredShellApproval,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    SaveShellApproval(reply_to: reply_to, approval: approval)
  })
}

/// Transition a shell approval out of `pending`.
///
/// This is intentionally pending-only so a worker timeout cannot overwrite a
/// restart cancellation or a superseded approval.
pub fn update_shell_approval_status(
  subject: process.Subject(DbMessage),
  id: String,
  status: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateShellApprovalStatus(
      reply_to: reply_to,
      id: id,
      status: status,
      updated_at_ms: updated_at_ms,
    )
  })
}

/// Load all still-pending shell approvals for a channel.
pub fn load_pending_shell_approvals_for_channel(
  subject: process.Subject(DbMessage),
  channel_id: String,
) -> Result(List(StoredShellApproval), String) {
  process.call(subject, 5000, fn(reply_to) {
    LoadPendingShellApprovalsForChannel(
      reply_to: reply_to,
      channel_id: channel_id,
    )
  })
}

// ---------------------------------------------------------------------------
// Message handler
// ---------------------------------------------------------------------------

fn handle_message(
  state: DbState,
  message: DbMessage,
) -> actor.Next(DbState, DbMessage) {
  case message {
    Shutdown -> {
      let _ = sqlight.close(state.conn)
      actor.stop()
    }

    ResolveConversation(reply_to:, platform:, platform_id:, timestamp:) -> {
      let result =
        do_resolve_conversation(state.conn, platform, platform_id, timestamp)
      process.send(reply_to, result)
      actor.continue(state)
    }

    AppendMessage(
      reply_to:,
      conversation_id:,
      role:,
      content:,
      author_id:,
      author_name:,
      timestamp:,
    ) -> {
      let result =
        do_append_message(
          state.conn,
          conversation_id,
          role,
          content,
          author_id,
          author_name,
          timestamp,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    LoadMessages(reply_to:, conversation_id:, limit:) -> {
      let result = do_load_messages(state.conn, conversation_id, limit)
      process.send(reply_to, result)
      actor.continue(state)
    }

    Search(reply_to:, query:, limit:) -> {
      let result = do_search(state.conn, query, limit)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateCompactionSummary(reply_to:, conversation_id:, summary:) -> {
      let result =
        do_update_compaction_summary(state.conn, conversation_id, summary)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetCompactionSummary(reply_to:, conversation_id:) -> {
      let result = do_get_compaction_summary(state.conn, conversation_id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateLastActive(reply_to:, conversation_id:, timestamp:) -> {
      let result = do_update_last_active(state.conn, conversation_id, timestamp)
      process.send(reply_to, result)
      actor.continue(state)
    }

    SetDomain(reply_to:, conversation_id:, domain:) -> {
      let result = do_set_domain(state.conn, conversation_id, domain)
      process.send(reply_to, result)
      actor.continue(state)
    }

    HasMessages(reply_to:) -> {
      let result = do_has_messages(state.conn)
      process.send(reply_to, result)
      actor.continue(state)
    }

    AppendMessageFull(
      reply_to:,
      conversation_id:,
      role:,
      content:,
      author_id:,
      author_name:,
      tool_call_id:,
      tool_calls:,
      timestamp:,
    ) -> {
      let result =
        do_append_message_full(
          state.conn,
          conversation_id,
          role,
          content,
          author_id,
          author_name,
          tool_call_id,
          tool_calls,
          timestamp,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpsertFlare(reply_to:, stored:) -> {
      let result = do_upsert_flare(state.conn, stored)
      process.send(reply_to, result)
      actor.continue(state)
    }

    LoadFlares(reply_to:, exclude_archived:) -> {
      let result = do_load_flares(state.conn, exclude_archived)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateFlareStatus(reply_to:, id:, status:, updated_at_ms:) -> {
      let result = do_update_flare_status(state.conn, id, status, updated_at_ms)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateFlareSessionId(reply_to:, id:, session_id:, updated_at_ms:) -> {
      let result =
        do_update_flare_session_id(state.conn, id, session_id, updated_at_ms)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateFlareRekindle(reply_to:, id:, session_id:, status:, updated_at_ms:) -> {
      let result =
        do_update_flare_rekindle(
          state.conn,
          id,
          session_id,
          status,
          updated_at_ms,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    InsertMemoryEntry(
      reply_to:,
      domain:,
      target:,
      key:,
      content:,
      created_at_ms:,
    ) -> {
      let result =
        do_insert_memory_entry(
          state.conn,
          domain,
          target,
          key,
          content,
          created_at_ms,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    SupersedeMemoryEntry(
      reply_to:,
      entry_id:,
      superseded_by:,
      superseded_at_ms:,
    ) -> {
      let result =
        do_supersede_memory_entry(
          state.conn,
          entry_id,
          superseded_by,
          superseded_at_ms,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetActiveMemoryEntries(reply_to:, domain:, target:) -> {
      let result = do_get_active_memory_entries(state.conn, domain, target)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetActiveMemoryEntryByKey(reply_to:, domain:, target:, key:) -> {
      let result =
        do_get_active_memory_entry_by_key(state.conn, domain, target, key)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetActiveEntryId(reply_to:, domain:, target:, key:, exclude_id:) -> {
      let result =
        do_get_active_entry_id(state.conn, domain, target, key, exclude_id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    InsertDreamRun(
      reply_to:,
      domain:,
      completed_at_ms:,
      phase_reached:,
      entries_consolidated:,
      entries_promoted:,
      reflections_generated:,
      duration_ms:,
      entries_rendered:,
      entries_noop:,
      action_candidates_count:,
    ) -> {
      let result =
        do_insert_dream_run(
          state.conn,
          domain,
          completed_at_ms,
          phase_reached,
          entries_consolidated,
          entries_promoted,
          reflections_generated,
          duration_ms,
          entries_rendered,
          entries_noop,
          action_candidates_count,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    InsertDreamRunEffect(reply_to:, dream_run_id:, effect:) -> {
      let result = do_insert_dream_run_effect(state.conn, dream_run_id, effect)
      process.send(reply_to, result)
      actor.continue(state)
    }

    InsertDreamActionCandidate(
      reply_to:,
      dream_run_id:,
      candidate:,
      created_at_ms:,
    ) -> {
      let result =
        do_insert_dream_action_candidate(
          state.conn,
          dream_run_id,
          candidate,
          created_at_ms,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetLastDreamMs(reply_to:, domain:) -> {
      let result = do_get_last_dream_ms(state.conn, domain)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetRecentNoopDreamRunCount(reply_to:, domain:, limit:) -> {
      let result = do_get_recent_noop_dream_run_count(state.conn, domain, limit)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateFlareResult(reply_to:, id:, result_text:, updated_at_ms:) -> {
      let result =
        do_update_flare_result(state.conn, id, result_text, updated_at_ms)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetFlareOutcomes(reply_to:, domain:, since_ms:) -> {
      let result = do_get_flare_outcomes(state.conn, domain, since_ms)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetCompactionSummaries(reply_to:, domain:) -> {
      let result = do_get_compaction_summaries(state.conn, domain)
      process.send(reply_to, result)
      actor.continue(state)
    }

    InsertEvent(reply_to:, event:) -> {
      let result = do_insert_event(state.conn, event)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetEvent(reply_to:, id:) -> {
      let result = do_get_event(state.conn, id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    SearchEvents(reply_to:, query:, time_range_ms:, source:, limit:) -> {
      let result =
        do_search_events(state.conn, query, time_range_ms, source, limit)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetIntegrationCheckpoint(reply_to:, name:) -> {
      let result = do_get_integration_checkpoint(state.conn, name)
      process.send(reply_to, result)
      actor.continue(state)
    }

    SaveIntegrationCheckpoint(
      reply_to:,
      name:,
      uidvalidity:,
      last_seen_uid:,
      now_ms:,
    ) -> {
      let result =
        do_save_integration_checkpoint(
          state.conn,
          name,
          uidvalidity,
          last_seen_uid,
          now_ms,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    SaveShellApproval(reply_to:, approval:) -> {
      let result = do_save_shell_approval(state.conn, approval)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateShellApprovalStatus(reply_to:, id:, status:, updated_at_ms:) -> {
      let result =
        do_update_shell_approval_status(state.conn, id, status, updated_at_ms)
      process.send(reply_to, result)
      actor.continue(state)
    }

    LoadPendingShellApprovalsForChannel(reply_to:, channel_id:) -> {
      let result =
        do_load_pending_shell_approvals_for_channel(state.conn, channel_id)
      process.send(reply_to, result)
      actor.continue(state)
    }
  }
}

// ---------------------------------------------------------------------------
// Database operations
// ---------------------------------------------------------------------------

fn do_resolve_conversation(
  conn: sqlight.Connection,
  platform: String,
  platform_id: String,
  timestamp: Int,
) -> Result(String, String) {
  let id = platform <> ":" <> platform_id

  // Try to find existing conversation
  let select_result =
    sqlight.query(
      "SELECT id FROM conversations WHERE platform = ? AND platform_id = ?",
      on: conn,
      with: [sqlight.text(platform), sqlight.text(platform_id)],
      expecting: decode.at([0], decode.string),
    )

  case select_result {
    Ok([existing_id]) -> Ok(existing_id)
    Ok([]) -> {
      // Insert new conversation
      case
        sqlight.query(
          "INSERT INTO conversations (id, platform, platform_id, last_active_at) VALUES (?, ?, ?, ?)",
          on: conn,
          with: [
            sqlight.text(id),
            sqlight.text(platform),
            sqlight.text(platform_id),
            sqlight.int(timestamp),
          ],
          expecting: decode.success(Nil),
        )
      {
        Ok(_) -> Ok(id)
        Error(err) ->
          Error("Failed to insert conversation: " <> string.inspect(err))
      }
    }
    Ok(_) -> Ok(id)
    Error(err) -> Error("Failed to query conversation: " <> string.inspect(err))
  }
}

fn do_append_message(
  conn: sqlight.Connection,
  conversation_id: String,
  role: String,
  content: String,
  author_id: String,
  author_name: String,
  timestamp: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO messages (conversation_id, role, content, author_id, author_name, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(conversation_id),
      sqlight.text(role),
      sqlight.text(content),
      sqlight.text(author_id),
      sqlight.text(author_name),
      sqlight.int(timestamp),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to insert message: " <> string.inspect(err)
  })
}

fn do_append_message_full(
  conn: sqlight.Connection,
  conversation_id: String,
  role: String,
  content: String,
  author_id: String,
  author_name: String,
  tool_call_id: String,
  tool_calls: String,
  timestamp: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO messages (conversation_id, role, content, author_id, author_name, tool_call_id, tool_calls, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(conversation_id),
      sqlight.text(role),
      sqlight.text(content),
      sqlight.text(author_id),
      sqlight.text(author_name),
      sqlight.text(tool_call_id),
      sqlight.text(tool_calls),
      sqlight.int(timestamp),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to insert message: " <> string.inspect(err)
  })
}

fn do_load_messages(
  conn: sqlight.Connection,
  conversation_id: String,
  limit: Int,
) -> Result(List(StoredMessage), String) {
  sqlight.query(
    "SELECT id, conversation_id, role, COALESCE(content,''), COALESCE(author_id,''), COALESCE(author_name,''), COALESCE(tool_call_id,''), COALESCE(tool_calls,''), COALESCE(tool_name,''), created_at FROM (SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at DESC, seq DESC, id DESC LIMIT ?) ORDER BY created_at ASC, seq ASC, id ASC",
    on: conn,
    with: [sqlight.text(conversation_id), sqlight.int(limit)],
    expecting: stored_message_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to load messages: " <> string.inspect(err)
  })
}

fn do_search(
  conn: sqlight.Connection,
  query: String,
  limit: Int,
) -> Result(List(SearchResult), String) {
  // Sanitize FTS5 query: strip special chars, reject empty
  let cleaned =
    query
    |> string.replace("\"", "")
    |> string.replace("*", "")
    |> string.trim
  case cleaned {
    "" -> Ok([])
    _ -> {
      let safe_query = "\"" <> cleaned <> "\""

      sqlight.query(
        "SELECT m.conversation_id, m.role, snippet(messages_fts, 0, '>>>', '<<<', '...', 32) AS snippet, m.content, m.author_name, m.created_at, c.platform, c.platform_id FROM messages_fts AS fts JOIN messages AS m ON fts.rowid = m.id JOIN conversations AS c ON m.conversation_id = c.id WHERE messages_fts MATCH ? ORDER BY fts.rank LIMIT ?",
        on: conn,
        with: [sqlight.text(safe_query), sqlight.int(limit)],
        expecting: search_result_decoder(),
      )
      |> result.map_error(fn(err) {
        "Failed to search messages: " <> string.inspect(err)
      })
    }
  }
}

fn do_update_compaction_summary(
  conn: sqlight.Connection,
  conversation_id: String,
  summary: String,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE conversations SET compaction_summary = ? WHERE id = ?",
    on: conn,
    with: [sqlight.text(summary), sqlight.text(conversation_id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update compaction summary: " <> string.inspect(err)
  })
}

fn do_get_compaction_summary(
  conn: sqlight.Connection,
  conversation_id: String,
) -> Result(String, String) {
  let result =
    sqlight.query(
      "SELECT COALESCE(compaction_summary, '') FROM conversations WHERE id = ?",
      on: conn,
      with: [sqlight.text(conversation_id)],
      expecting: decode.at([0], decode.string),
    )
  case result {
    Ok([summary]) -> Ok(summary)
    Ok([]) -> Ok("")
    Ok(_) -> Ok("")
    Error(e) -> Error("Failed to get compaction summary: " <> string.inspect(e))
  }
}

fn do_update_last_active(
  conn: sqlight.Connection,
  conversation_id: String,
  timestamp: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE conversations SET last_active_at = ? WHERE id = ?",
    on: conn,
    with: [sqlight.int(timestamp), sqlight.text(conversation_id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update last_active_at: " <> string.inspect(err)
  })
}

fn do_set_domain(
  conn: sqlight.Connection,
  conversation_id: String,
  domain: String,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE conversations SET domain = ? WHERE id = ?",
    on: conn,
    with: [sqlight.text(domain), sqlight.text(conversation_id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to set domain: " <> string.inspect(err)
  })
}

fn do_has_messages(conn: sqlight.Connection) -> Result(Bool, String) {
  case
    sqlight.query(
      "SELECT 1 FROM messages LIMIT 1",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  {
    Ok([]) -> Ok(False)
    Ok(_) -> Ok(True)
    Error(e) -> Error("Failed to check messages: " <> string.inspect(e))
  }
}

fn do_upsert_flare(
  conn: sqlight.Connection,
  stored: StoredFlare,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT OR REPLACE INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(stored.id),
      sqlight.text(stored.label),
      sqlight.text(stored.status),
      sqlight.text(stored.domain),
      sqlight.text(stored.thread_id),
      sqlight.text(stored.original_prompt),
      sqlight.text(stored.execution),
      sqlight.text(stored.triggers),
      sqlight.text(stored.tools),
      sqlight.text(stored.workspace),
      sqlight.text(stored.session_id),
      sqlight.int(stored.created_at_ms),
      sqlight.int(stored.updated_at_ms),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to upsert flare: " <> string.inspect(err)
  })
}

fn do_load_flares(
  conn: sqlight.Connection,
  exclude_archived: Bool,
) -> Result(List(StoredFlare), String) {
  let sql = case exclude_archived {
    True ->
      "SELECT id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms FROM flares WHERE status != 'archived' ORDER BY created_at_ms ASC"
    False ->
      "SELECT id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms FROM flares ORDER BY created_at_ms ASC"
  }
  sqlight.query(sql, on: conn, with: [], expecting: flare_decoder())
  |> result.map_error(fn(err) {
    "Failed to load flares: " <> string.inspect(err)
  })
}

fn do_update_flare_status(
  conn: sqlight.Connection,
  id: String,
  status: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE flares SET status = ?, updated_at_ms = ? WHERE id = ?",
    on: conn,
    with: [sqlight.text(status), sqlight.int(updated_at_ms), sqlight.text(id)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update flare status: " <> string.inspect(err)
  })
}

fn do_update_flare_session_id(
  conn: sqlight.Connection,
  id: String,
  session_id: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE flares SET session_id = ?, updated_at_ms = ? WHERE id = ?",
    on: conn,
    with: [
      sqlight.text(session_id),
      sqlight.int(updated_at_ms),
      sqlight.text(id),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update flare session_id: " <> string.inspect(err)
  })
}

fn do_update_flare_rekindle(
  conn: sqlight.Connection,
  id: String,
  session_id: String,
  status: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE flares SET session_id = ?1, status = ?2, updated_at_ms = ?3 WHERE id = ?4",
    on: conn,
    with: [
      sqlight.text(session_id),
      sqlight.text(status),
      sqlight.int(updated_at_ms),
      sqlight.text(id),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update flare rekindle: " <> string.inspect(err)
  })
}

fn do_insert_memory_entry(
  conn: sqlight.Connection,
  domain: String,
  target: String,
  key: String,
  content: String,
  created_at_ms: Int,
) -> Result(Int, String) {
  sqlight.query(
    "INSERT INTO memory_entries (domain, target, key, content, created_at_ms) VALUES (?, ?, ?, ?, ?) RETURNING id",
    on: conn,
    with: [
      sqlight.text(domain),
      sqlight.text(target),
      sqlight.text(key),
      sqlight.text(content),
      sqlight.int(created_at_ms),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(err) {
    "Failed to insert memory entry: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    case rows {
      [id] -> Ok(id)
      _ ->
        Error(
          "Expected one row from INSERT RETURNING, got " <> string.inspect(rows),
        )
    }
  })
}

fn do_supersede_memory_entry(
  conn: sqlight.Connection,
  entry_id: Int,
  superseded_by: Int,
  superseded_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE memory_entries SET superseded_at_ms = ?, superseded_by = ? WHERE id = ? AND superseded_at_ms IS NULL",
    on: conn,
    with: [
      sqlight.int(superseded_at_ms),
      sqlight.int(superseded_by),
      sqlight.int(entry_id),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to supersede memory entry: " <> string.inspect(err)
  })
}

fn do_get_active_memory_entries(
  conn: sqlight.Connection,
  domain: String,
  target: String,
) -> Result(List(MemoryEntry), String) {
  sqlight.query(
    "SELECT id, domain, target, key, content, created_at_ms FROM memory_entries WHERE domain = ? AND target = ? AND superseded_at_ms IS NULL ORDER BY created_at_ms ASC",
    on: conn,
    with: [sqlight.text(domain), sqlight.text(target)],
    expecting: memory_entry_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to get active memory entries: " <> string.inspect(err)
  })
}

fn do_get_active_memory_entry_by_key(
  conn: sqlight.Connection,
  domain: String,
  target: String,
  key: String,
) -> Result(Option(MemoryEntry), String) {
  case
    sqlight.query(
      "SELECT id, domain, target, key, content, created_at_ms FROM memory_entries WHERE domain = ? AND target = ? AND key = ? AND superseded_at_ms IS NULL ORDER BY created_at_ms DESC, id DESC LIMIT 1",
      on: conn,
      with: [sqlight.text(domain), sqlight.text(target), sqlight.text(key)],
      expecting: memory_entry_decoder(),
    )
  {
    Ok([entry]) -> Ok(Some(entry))
    Ok([]) -> Ok(None)
    Ok(_) -> Ok(None)
    Error(e) ->
      Error("Failed to get active memory entry by key: " <> string.inspect(e))
  }
}

fn do_get_active_entry_id(
  conn: sqlight.Connection,
  domain: String,
  target: String,
  key: String,
  exclude_id: Int,
) -> Result(Int, String) {
  sqlight.query(
    "SELECT id FROM memory_entries WHERE domain = ? AND target = ? AND key = ? AND id != ? AND superseded_at_ms IS NULL LIMIT 1",
    on: conn,
    with: [
      sqlight.text(domain),
      sqlight.text(target),
      sqlight.text(key),
      sqlight.int(exclude_id),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(err) {
    "Failed to get active entry id: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    case rows {
      [id] -> Ok(id)
      _ -> Error("No active entry found for key")
    }
  })
}

fn do_insert_dream_run(
  conn: sqlight.Connection,
  domain: String,
  completed_at_ms: Int,
  phase_reached: String,
  entries_consolidated: Int,
  entries_promoted: Int,
  reflections_generated: Int,
  duration_ms: Int,
  entries_rendered: Int,
  entries_noop: Int,
  action_candidates_count: Int,
) -> Result(Int, String) {
  sqlight.query(
    "INSERT INTO dream_runs (domain, completed_at_ms, phase_reached, entries_consolidated, entries_promoted, reflections_generated, duration_ms, entries_rendered, entries_noop, action_candidates_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
    on: conn,
    with: [
      sqlight.text(domain),
      sqlight.int(completed_at_ms),
      sqlight.text(phase_reached),
      sqlight.int(entries_consolidated),
      sqlight.int(entries_promoted),
      sqlight.int(reflections_generated),
      sqlight.int(duration_ms),
      sqlight.int(entries_rendered),
      sqlight.int(entries_noop),
      sqlight.int(action_candidates_count),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(err) {
    "Failed to insert dream run: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    case rows {
      [id] -> Ok(id)
      _ ->
        Error(
          "Expected one row from INSERT RETURNING, got " <> string.inspect(rows),
        )
    }
  })
}

fn do_insert_dream_run_effect(
  conn: sqlight.Connection,
  dream_run_id: Int,
  effect: dream_effect.DreamEffect,
) -> Result(Int, String) {
  sqlight.query(
    "INSERT INTO dream_run_effects (dream_run_id, domain, phase, target, key, action, effect_kind, previous_memory_entry_id, new_memory_entry_id, previous_chars, content_chars, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
    on: conn,
    with: [
      sqlight.int(dream_run_id),
      sqlight.text(effect.domain),
      sqlight.text(effect.phase),
      sqlight.text(effect.target),
      sqlight.text(effect.key),
      sqlight.text(effect.action),
      sqlight.text(dream_effect.effect_kind_to_string(effect.kind)),
      nullable_int(effect.previous_memory_entry_id),
      nullable_int(effect.new_memory_entry_id),
      nullable_int(effect.previous_chars),
      sqlight.int(effect.content_chars),
      sqlight.int(effect.created_at_ms),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(err) {
    "Failed to insert dream run effect: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    case rows {
      [id] -> Ok(id)
      _ ->
        Error(
          "Expected one row from INSERT RETURNING, got " <> string.inspect(rows),
        )
    }
  })
}

fn do_insert_dream_action_candidate(
  conn: sqlight.Connection,
  dream_run_id: Int,
  candidate: dream_effect.ActionCandidate,
  created_at_ms: Int,
) -> Result(Int, String) {
  sqlight.query(
    "INSERT INTO dream_action_candidates (dream_run_id, domain, candidate_type, severity, reason, created_at_ms) VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
    on: conn,
    with: [
      sqlight.int(dream_run_id),
      sqlight.text(candidate.domain),
      sqlight.text(candidate.candidate_type),
      sqlight.int(candidate.severity),
      sqlight.text(candidate.reason),
      sqlight.int(created_at_ms),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(err) {
    "Failed to insert dream action candidate: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    case rows {
      [id] -> Ok(id)
      _ ->
        Error(
          "Expected one row from INSERT RETURNING, got " <> string.inspect(rows),
        )
    }
  })
}

fn do_get_last_dream_ms(
  conn: sqlight.Connection,
  domain: String,
) -> Result(Int, String) {
  case
    sqlight.query(
      "SELECT completed_at_ms FROM dream_runs WHERE domain = ? ORDER BY completed_at_ms DESC LIMIT 1",
      on: conn,
      with: [sqlight.text(domain)],
      expecting: decode.at([0], decode.int),
    )
  {
    Ok([ms]) -> Ok(ms)
    Ok([]) -> Ok(0)
    Ok(_) -> Ok(0)
    Error(e) -> Error("Failed to get last dream ms: " <> string.inspect(e))
  }
}

fn do_get_recent_noop_dream_run_count(
  conn: sqlight.Connection,
  domain: String,
  limit: Int,
) -> Result(Int, String) {
  sqlight.query(
    "SELECT entries_consolidated, entries_promoted, reflections_generated, entries_rendered, entries_noop FROM dream_runs WHERE domain = ? ORDER BY completed_at_ms DESC, id DESC LIMIT ?",
    on: conn,
    with: [sqlight.text(domain), sqlight.int(limit)],
    expecting: dream_run_write_counts_decoder(),
  )
  |> result.map(count_consecutive_noop_runs)
  |> result.map_error(fn(err) {
    "Failed to get recent noop dream run count: " <> string.inspect(err)
  })
}

fn count_consecutive_noop_runs(rows: List(DreamRunWriteCounts)) -> Int {
  case rows {
    [] -> 0
    [row, ..rest] -> {
      case row.actual_writes == 0 && row.noops > 0 {
        True -> 1 + count_consecutive_noop_runs(rest)
        False -> 0
      }
    }
  }
}

fn do_update_flare_result(
  conn: sqlight.Connection,
  id: String,
  result_text: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE flares SET result_text = ?, updated_at_ms = ? WHERE id = ?",
    on: conn,
    with: [
      sqlight.text(result_text),
      sqlight.int(updated_at_ms),
      sqlight.text(id),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update flare result: " <> string.inspect(err)
  })
}

fn do_get_flare_outcomes(
  conn: sqlight.Connection,
  domain: String,
  since_ms: Int,
) -> Result(List(#(String, String)), String) {
  sqlight.query(
    "SELECT label, result_text FROM flares WHERE domain = ? AND result_text IS NOT NULL AND updated_at_ms > ? ORDER BY updated_at_ms ASC",
    on: conn,
    with: [sqlight.text(domain), sqlight.int(since_ms)],
    expecting: {
      use label <- decode.field(0, decode.string)
      use result_text <- decode.field(1, decode.string)
      decode.success(#(label, result_text))
    },
  )
  |> result.map_error(fn(err) {
    "Failed to get flare outcomes: " <> string.inspect(err)
  })
}

fn do_get_compaction_summaries(
  conn: sqlight.Connection,
  domain: String,
) -> Result(List(String), String) {
  sqlight.query(
    "SELECT compaction_summary FROM conversations WHERE domain = ? AND compaction_summary IS NOT NULL AND compaction_summary != ''",
    on: conn,
    with: [sqlight.text(domain)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(err) {
    "Failed to get compaction summaries: " <> string.inspect(err)
  })
}

fn do_insert_event(
  conn: sqlight.Connection,
  e: event.AuraEvent,
) -> Result(Bool, String) {
  // INSERT OR IGNORE ... RETURNING id returns a row only when the insert
  // actually happened. A duplicate (source, external_id) hits the UNIQUE
  // constraint, is ignored, and yields an empty result set — which is how
  // we detect the dedup without a separate SELECT.
  let tags_json = event.tags_to_json(e.tags)
  sqlight.query(
    "INSERT OR IGNORE INTO events (id, source, type, subject, time_ms, tags_json, external_id, data_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
    on: conn,
    with: [
      sqlight.text(e.id),
      sqlight.text(e.source),
      sqlight.text(e.type_),
      sqlight.text(e.subject),
      sqlight.int(e.time_ms),
      sqlight.text(tags_json),
      sqlight.text(e.external_id),
      sqlight.text(e.data),
    ],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(err) {
    "Failed to insert event: " <> string.inspect(err)
  })
  |> result.map(fn(rows) {
    case rows {
      [] -> False
      _ -> True
    }
  })
}

fn do_get_event(
  conn: sqlight.Connection,
  id: String,
) -> Result(Option(event.AuraEvent), String) {
  sqlight.query(
    "SELECT id, source, type, subject, time_ms, tags_json, external_id, data_json FROM events WHERE id = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(id)],
    expecting: event_row_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to load event: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    case rows {
      [] -> Ok(None)
      [row, ..] ->
        event_from_row(row)
        |> result.map(fn(e) { Some(e) })
    }
  })
}

fn do_search_events(
  conn: sqlight.Connection,
  query: String,
  time_range_ms: Option(#(Int, Int)),
  source_filter: Option(String),
  limit: Int,
) -> Result(List(event.AuraEvent), String) {
  // Empty query short-circuits FTS and selects straight from events with the
  // optional filters. FTS5 errors on an empty MATCH string, so this branch
  // is required — not a convenience.
  let #(sql, args) = case string.trim(query) {
    "" -> build_events_plain_query(time_range_ms, source_filter, limit)
    cleaned ->
      build_events_fts_query(cleaned, time_range_ms, source_filter, limit)
  }

  sqlight.query(sql, on: conn, with: args, expecting: event_row_decoder())
  |> result.map_error(fn(err) {
    "Failed to search events: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    // Parse each stored tags_json back to a Dict; a broken tag blob is a
    // parse failure, not silent garbage.
    list.try_map(rows, event_from_row)
  })
}

fn event_from_row(
  row: #(String, String, String, String, Int, String, String, String),
) -> Result(event.AuraEvent, String) {
  let #(id, source, type_, subject, time_ms, tags_raw, external_id, data) = row
  case event.tags_from_json(tags_raw) {
    Ok(tags) ->
      Ok(event.AuraEvent(
        id: id,
        source: source,
        type_: type_,
        subject: subject,
        time_ms: time_ms,
        tags: tags,
        external_id: external_id,
        data: data,
      ))
    Error(err) -> Error("Failed to decode event tags: " <> err)
  }
}

fn build_events_plain_query(
  time_range_ms: Option(#(Int, Int)),
  source_filter: Option(String),
  limit: Int,
) -> #(String, List(sqlight.Value)) {
  let #(where_sql, args) =
    build_events_filter_sql(time_range_ms, source_filter, [])
  let where_clause = case where_sql {
    "" -> ""
    _ -> " WHERE " <> where_sql
  }
  let sql =
    "SELECT id, source, type, subject, time_ms, tags_json, external_id, data_json FROM events"
    <> where_clause
    <> " ORDER BY time_ms DESC LIMIT ?"
  #(sql, list.append(args, [sqlight.int(limit)]))
}

fn build_events_fts_query(
  cleaned_query: String,
  time_range_ms: Option(#(Int, Int)),
  source_filter: Option(String),
  limit: Int,
) -> #(String, List(sqlight.Value)) {
  // Quote the user's query as an FTS phrase so we don't need to sanitize
  // every FTS operator. Strip the same chars as `do_search` (`"` and `*`)
  // so the two sites stay in lockstep.
  let safe =
    cleaned_query
    |> string.replace("\"", "")
    |> string.replace("*", "")
  let quoted = "\"" <> safe <> "\""
  let base_args = [sqlight.text(quoted)]
  let #(filter_sql, filter_args) =
    build_events_filter_sql(time_range_ms, source_filter, base_args)
  let and_clause = case filter_sql {
    "" -> ""
    _ -> " AND " <> filter_sql
  }
  let sql =
    "SELECT events.id, events.source, events.type, events.subject, events.time_ms, events.tags_json, events.external_id, events.data_json FROM events_fts JOIN events ON events.rowid = events_fts.rowid WHERE events_fts MATCH ?"
    <> and_clause
    <> " ORDER BY events.time_ms DESC LIMIT ?"
  #(sql, list.append(filter_args, [sqlight.int(limit)]))
}

fn build_events_filter_sql(
  time_range_ms: Option(#(Int, Int)),
  source_filter: Option(String),
  seed_args: List(sqlight.Value),
) -> #(String, List(sqlight.Value)) {
  let #(parts, args) = case time_range_ms {
    Some(#(lo, hi)) -> #(
      ["events.time_ms BETWEEN ? AND ?"],
      list.append(seed_args, [sqlight.int(lo), sqlight.int(hi)]),
    )
    None -> #([], seed_args)
  }
  let #(parts, args) = case source_filter {
    Some(src) -> #(
      list.append(parts, ["events.source = ?"]),
      list.append(args, [sqlight.text(src)]),
    )
    None -> #(parts, args)
  }
  #(string.join(parts, " AND "), args)
}

// ---------------------------------------------------------------------------
// Decoders
// ---------------------------------------------------------------------------

fn stored_message_decoder() -> decode.Decoder(StoredMessage) {
  use id <- decode.field(0, decode.int)
  use conversation_id <- decode.field(1, decode.string)
  use role <- decode.field(2, decode.string)
  use content <- decode.field(3, nullable_string_decoder())
  use author_id <- decode.field(4, nullable_string_decoder())
  use author_name <- decode.field(5, nullable_string_decoder())
  use tool_call_id <- decode.field(6, nullable_string_decoder())
  use tool_calls <- decode.field(7, nullable_string_decoder())
  use tool_name <- decode.field(8, nullable_string_decoder())
  use created_at <- decode.field(9, decode.int)
  decode.success(StoredMessage(
    id: id,
    conversation_id: conversation_id,
    role: role,
    content: content,
    author_id: author_id,
    author_name: author_name,
    tool_call_id: tool_call_id,
    tool_calls: tool_calls,
    tool_name: tool_name,
    created_at: created_at,
  ))
}

fn search_result_decoder() -> decode.Decoder(SearchResult) {
  use conversation_id <- decode.field(0, decode.string)
  use role <- decode.field(1, decode.string)
  use snippet <- decode.field(2, nullable_string_decoder())
  use content <- decode.field(3, nullable_string_decoder())
  use author_name <- decode.field(4, nullable_string_decoder())
  use created_at <- decode.field(5, decode.int)
  use platform <- decode.field(6, decode.string)
  use platform_id <- decode.field(7, decode.string)
  decode.success(SearchResult(
    conversation_id: conversation_id,
    role: role,
    snippet: snippet,
    content: content,
    author_name: author_name,
    created_at: created_at,
    platform: platform,
    platform_id: platform_id,
  ))
}

fn nullable_string_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.string, [
    decode.success(""),
  ])
}

fn nullable_int(value: Option(Int)) -> sqlight.Value {
  sqlight.nullable(sqlight.int, value)
}

fn dream_run_write_counts_decoder() -> decode.Decoder(DreamRunWriteCounts) {
  use entries_consolidated <- decode.field(0, decode.int)
  use entries_promoted <- decode.field(1, decode.int)
  use reflections_generated <- decode.field(2, decode.int)
  use entries_rendered <- decode.field(3, decode.int)
  use entries_noop <- decode.field(4, decode.int)
  decode.success(DreamRunWriteCounts(
    actual_writes: entries_consolidated
      + entries_promoted
      + reflections_generated
      + entries_rendered,
    noops: entries_noop,
  ))
}

fn memory_entry_decoder() -> decode.Decoder(MemoryEntry) {
  use id <- decode.field(0, decode.int)
  use domain <- decode.field(1, decode.string)
  use target <- decode.field(2, decode.string)
  use key <- decode.field(3, decode.string)
  use content <- decode.field(4, decode.string)
  use created_at_ms <- decode.field(5, decode.int)
  decode.success(MemoryEntry(
    id: id,
    domain: domain,
    target: target,
    key: key,
    content: content,
    created_at_ms: created_at_ms,
  ))
}

fn event_row_decoder() -> decode.Decoder(
  #(String, String, String, String, Int, String, String, String),
) {
  use id <- decode.field(0, decode.string)
  use source <- decode.field(1, decode.string)
  use type_ <- decode.field(2, decode.string)
  use subject <- decode.field(3, decode.string)
  use time_ms <- decode.field(4, decode.int)
  use tags_json <- decode.field(5, decode.string)
  use external_id <- decode.field(6, decode.string)
  use data_json <- decode.field(7, decode.string)
  decode.success(#(
    id,
    source,
    type_,
    subject,
    time_ms,
    tags_json,
    external_id,
    data_json,
  ))
}

fn flare_decoder() -> decode.Decoder(StoredFlare) {
  use id <- decode.field(0, decode.string)
  use label <- decode.field(1, decode.string)
  use status <- decode.field(2, decode.string)
  use domain <- decode.field(3, decode.string)
  use thread_id <- decode.field(4, decode.string)
  use original_prompt <- decode.field(5, decode.string)
  use execution <- decode.field(6, decode.string)
  use triggers <- decode.field(7, decode.string)
  use tools <- decode.field(8, decode.string)
  use workspace <- decode.field(9, nullable_string_decoder())
  use session_id <- decode.field(10, nullable_string_decoder())
  use created_at_ms <- decode.field(11, decode.int)
  use updated_at_ms <- decode.field(12, decode.int)
  decode.success(StoredFlare(
    id: id,
    label: label,
    status: status,
    domain: domain,
    thread_id: thread_id,
    original_prompt: original_prompt,
    execution: execution,
    triggers: triggers,
    tools: tools,
    workspace: workspace,
    session_id: session_id,
    created_at_ms: created_at_ms,
    updated_at_ms: updated_at_ms,
  ))
}

fn shell_approval_decoder() -> decode.Decoder(StoredShellApproval) {
  use id <- decode.field(0, decode.string)
  use channel_id <- decode.field(1, decode.string)
  use message_id <- decode.field(2, decode.string)
  use command <- decode.field(3, decode.string)
  use reason <- decode.field(4, decode.string)
  use status <- decode.field(5, decode.string)
  use requested_at_ms <- decode.field(6, decode.int)
  use updated_at_ms <- decode.field(7, decode.int)
  decode.success(StoredShellApproval(
    id: id,
    channel_id: channel_id,
    message_id: message_id,
    command: command,
    reason: reason,
    status: status,
    requested_at_ms: requested_at_ms,
    updated_at_ms: updated_at_ms,
  ))
}

fn do_get_integration_checkpoint(
  conn: sqlight.Connection,
  name: String,
) -> Result(Option(#(Int, Int)), String) {
  sqlight.query(
    "SELECT uidvalidity, last_seen_uid FROM integration_checkpoints WHERE name = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(name)],
    expecting: {
      use uidvalidity <- decode.field(0, decode.int)
      use last_seen_uid <- decode.field(1, decode.int)
      decode.success(#(uidvalidity, last_seen_uid))
    },
  )
  |> result.map_error(fn(err) {
    "Failed to read integration checkpoint: " <> string.inspect(err)
  })
  |> result.map(fn(rows) {
    case rows {
      [] -> option.None
      [row, ..] -> option.Some(row)
    }
  })
}

fn do_save_integration_checkpoint(
  conn: sqlight.Connection,
  name: String,
  uidvalidity: Int,
  last_seen_uid: Int,
  now_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO integration_checkpoints (name, uidvalidity, last_seen_uid, updated_at_ms) VALUES (?, ?, ?, ?) ON CONFLICT(name) DO UPDATE SET uidvalidity = excluded.uidvalidity, last_seen_uid = excluded.last_seen_uid, updated_at_ms = excluded.updated_at_ms",
    on: conn,
    with: [
      sqlight.text(name),
      sqlight.int(uidvalidity),
      sqlight.int(last_seen_uid),
      sqlight.int(now_ms),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map_error(fn(err) {
    "Failed to save integration checkpoint: " <> string.inspect(err)
  })
  |> result.map(fn(_) { Nil })
}

fn do_save_shell_approval(
  conn: sqlight.Connection,
  approval: StoredShellApproval,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO shell_approvals (id, channel_id, message_id, command, reason, status, requested_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET channel_id = excluded.channel_id, message_id = excluded.message_id, command = excluded.command, reason = excluded.reason, status = excluded.status, requested_at_ms = excluded.requested_at_ms, updated_at_ms = excluded.updated_at_ms",
    on: conn,
    with: [
      sqlight.text(approval.id),
      sqlight.text(approval.channel_id),
      sqlight.text(approval.message_id),
      sqlight.text(approval.command),
      sqlight.text(approval.reason),
      sqlight.text(approval.status),
      sqlight.int(approval.requested_at_ms),
      sqlight.int(approval.updated_at_ms),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map_error(fn(err) {
    "Failed to save shell approval: " <> string.inspect(err)
  })
  |> result.map(fn(_) { Nil })
}

fn do_update_shell_approval_status(
  conn: sqlight.Connection,
  id: String,
  status: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE shell_approvals SET status = ?, updated_at_ms = ? WHERE id = ? AND status = 'pending' RETURNING id",
    on: conn,
    with: [sqlight.text(status), sqlight.int(updated_at_ms), sqlight.text(id)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(err) {
    "Failed to update shell approval status: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    case rows {
      [_] -> Ok(Nil)
      [] -> Error("Shell approval is not pending: " <> id)
      _ -> Error("Unexpected shell approval update result for: " <> id)
    }
  })
}

fn do_load_pending_shell_approvals_for_channel(
  conn: sqlight.Connection,
  channel_id: String,
) -> Result(List(StoredShellApproval), String) {
  sqlight.query(
    "SELECT id, channel_id, message_id, command, reason, status, requested_at_ms, updated_at_ms FROM shell_approvals WHERE channel_id = ? AND status = 'pending' ORDER BY requested_at_ms ASC",
    on: conn,
    with: [sqlight.text(channel_id)],
    expecting: shell_approval_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to load pending shell approvals: " <> string.inspect(err)
  })
}
