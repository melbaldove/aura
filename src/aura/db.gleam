import aura/attention_queue
import aura/db_schema
import aura/dream_effect
import aura/event
import aura/evidence
import aura/operating_contracts
import aura/operational_audit
import aura/time
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
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
    dispatch_id: String,
    executor_kind: String,
    capability_manifest: String,
    context_manifest: String,
    authority_boundary: String,
    final_result: String,
    final_proof: String,
    archived: Bool,
  )
}

/// One execution attempt of a flare. Durable identity lives on the flare; the
/// attempt is transient but recorded for audit and recovery.
pub type StoredFlareAttempt {
  StoredFlareAttempt(
    id: Int,
    flare_id: String,
    executor_kind: String,
    status: String,
    runtime_reference: String,
    checkpoint: String,
    started_at_ms: Int,
    ended_at_ms: Int,
    failure: String,
  )
}

/// Append-only audit event for a flare. `sequence` is per-flare ordering.
pub type StoredFlareEvent {
  StoredFlareEvent(
    id: Int,
    flare_id: String,
    attempt_id: Int,
    sequence: Int,
    event_type: String,
    payload: String,
    created_at_ms: Int,
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

/// A pending or resolved external (hook-layer) ask. Unlike shell approvals,
/// pending rows survive restarts: the waiter is an external OS process.
pub type StoredExternalAsk {
  StoredExternalAsk(
    id: String,
    source: String,
    channel_id: String,
    message_id: String,
    text: String,
    buttons_json: String,
    status: String,
    decision: String,
    requested_at_ms: Int,
    updated_at_ms: Int,
  )
}

/// Current health for an external integration.
pub type IntegrationHealth {
  IntegrationHealth(
    name: String,
    status: String,
    message: String,
    last_success_at_ms: Option(Int),
    last_error_at_ms: Option(Int),
    updated_at_ms: Int,
  )
}

/// Immutable result stored for one idempotent mutation.
pub type MutationReceipt {
  MutationReceipt(
    idempotency_key: String,
    schema_version: Int,
    payload_hash: String,
    operation_type: String,
    result_target_type: String,
    result_target_id: String,
    result_version: Int,
    result_json: String,
    created_at_ms: Int,
  )
}

/// One immutable preparation authorization loaded from SQLite.
pub type StoredCanaryPreparationAuthorization {
  StoredCanaryPreparationAuthorization(
    authorization: operating_contracts.CanaryPreparationAuthorizationV1,
    payload_hash: String,
    created_at_ms: Int,
  )
}

/// One immutable final canary authorization loaded from SQLite.
pub type StoredCanaryAuthorization {
  StoredCanaryAuthorization(
    authorization: operating_contracts.CanaryAuthorizationV1,
    payload_hash: String,
    created_at_ms: Int,
  )
}

/// Immutable route bindings required by an authorized Codex monitor transfer.
pub type MonitorRoute {
  MonitorRoute(
    authorization_id: String,
    activation_ids_json: String,
    domain_id: String,
    concern_id: String,
    claim_command_id: String,
    claim_payload_hash: String,
  )
}

/// Canonical result of one normalized evidence submission.
pub type EvidenceInsert {
  EvidenceInsert(event_id: String, inserted: Bool)
}

/// One bounded read reservation for an enabled connector activation.
pub type ConnectorReadAttempt {
  ConnectorReadAttempt(
    attempt_id: String,
    activation_id: String,
    activation_version: Int,
    attempt_version: Int,
    worker_id: String,
    phase: String,
  )
}

/// One checkpoint mutation committed with an authorized evidence batch.
pub type ConnectorCheckpointUpdate {
  NoConnectorCheckpoint
  GmailHistoryCheckpoint(
    configuration_ref: String,
    activation_id: String,
    expected_version: Int,
    history_id: String,
  )
  GmailHistoryCheckpointWithMissing(
    configuration_ref: String,
    activation_id: String,
    expected_version: Int,
    history_id: String,
    missing_count: Int,
  )
  CalendarPollCheckpoint(
    configuration_ref: String,
    activation_id: String,
    expected_version: Int,
    next_due_at_ms: Int,
  )
  GmailHistoryGap(
    configuration_ref: String,
    activation_id: String,
    expected_version: Int,
    reason_code: String,
    prior_history_hash: String,
  )
}

/// One durable connector cursor and retry record.
pub type ConnectorCheckpoint {
  ConnectorCheckpoint(
    configuration_ref: String,
    connector_id: String,
    authorization_id: String,
    activation_id: String,
    cursor_kind: String,
    cursor_value: String,
    next_due_at_ms: Int,
    retry_count: Int,
    gap_code: String,
    version: Int,
  )
}

/// One durable, secret-free Google loopback OAuth session.
pub type GoogleOAuthSession {
  GoogleOAuthSession(
    session_ref: String,
    connector_id: String,
    preparation_authorization_id: String,
    configuration_ref: String,
    configuration_hash: String,
    oauth_client_ref: String,
    oauth_client_hash: String,
    client_set_ref: String,
    client_set_hash: String,
    state_hash: String,
    pkce_challenge: String,
    redirect_uri: String,
    phase: String,
    expires_at_ms: Int,
  )
}

/// One immutable secret-free binding for the two Google Desktop app clients.
pub type GoogleOAuthClientSet {
  GoogleOAuthClientSet(
    client_set_ref: String,
    client_set_hash: String,
    gmail_client_ref: String,
    gmail_client_hash: String,
    calendar_client_ref: String,
    calendar_client_hash: String,
  )
}

/// One durable intent or outcome for a Google OAuth or identity effect.
pub type GoogleExternalEffect {
  GoogleExternalEffect(
    effect_id: String,
    preparation_authorization_id: String,
    authorization_id: String,
    activation_id: String,
    configuration_ref: String,
    configuration_hash: String,
    connector_id: String,
    oauth_client_ref: String,
    oauth_client_hash: String,
    client_set_ref: String,
    client_set_hash: String,
    effect_kind: String,
    logical_effect_key: String,
    attempt_number: Int,
    request_hash: String,
    phase: String,
    proof_ref: String,
    oauth_scope: String,
    account_fingerprint: String,
    result_hash: String,
    error_class: String,
  )
}

/// One persisted count for an authorized canary acceptance metric.
pub type CanaryMetricCount {
  CanaryMetricCount(metric_id: String, value: Int)
}

/// One compact normalized evidence record loaded from SQLite.
pub type StoredEvidence {
  StoredEvidence(
    event_id: String,
    envelope: operating_contracts.EvidenceEvent,
    raw_ref: String,
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
  AppendDeliveryMessageWithAudit(
    reply_to: process.Subject(Result(Nil, String)),
    platform_id: String,
    event_id: String,
    content: String,
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
  UpsertFlareWithEvent(
    reply_to: process.Subject(Result(Nil, String)),
    stored: StoredFlare,
    event: StoredFlareEvent,
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
  AppendFlareEvent(
    reply_to: process.Subject(Result(Nil, String)),
    event: StoredFlareEvent,
  )
  ListFlareEvents(
    reply_to: process.Subject(Result(List(StoredFlareEvent), String)),
    flare_id: String,
  )
  CreateFlareAttempt(
    reply_to: process.Subject(Result(Int, String)),
    attempt: StoredFlareAttempt,
  )
  CreateFlareAttemptWithEvent(
    reply_to: process.Subject(Result(Int, String)),
    attempt: StoredFlareAttempt,
    event: StoredFlareEvent,
  )
  UpdateFlareAttempt(
    reply_to: process.Subject(Result(Nil, String)),
    attempt: StoredFlareAttempt,
  )
  ListFlareAttempts(
    reply_to: process.Subject(Result(List(StoredFlareAttempt), String)),
    flare_id: String,
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
  GetFlareResult(reply_to: process.Subject(Result(String, String)), id: String)
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
  InsertNormalizedEvidence(
    reply_to: process.Subject(Result(EvidenceInsert, String)),
    envelope: operating_contracts.EvidenceEvent,
    concern_links: List(evidence.ConcernLink),
  )
  SubmitAuthorizedConnectorEvidence(
    reply_to: process.Subject(Result(Option(EvidenceInsert), String)),
    context: operating_contracts.ConnectorSubmissionContext,
    envelope: operating_contracts.EvidenceEvent,
    concern_links: List(evidence.ConcernLink),
  )
  SubmitAuthorizedConnectorEvidenceBatch(
    reply_to: process.Subject(Result(Option(List(EvidenceInsert)), String)),
    context: operating_contracts.ConnectorSubmissionContext,
    evidence_items: List(
      #(operating_contracts.EvidenceEvent, List(evidence.ConcernLink)),
    ),
  )
  SubmitAuthorizedConnectorEvidenceBatchWithCheckpoint(
    reply_to: process.Subject(Result(Option(List(EvidenceInsert)), String)),
    context: operating_contracts.ConnectorSubmissionContext,
    evidence_items: List(
      #(operating_contracts.EvidenceEvent, List(evidence.ConcernLink)),
    ),
    checkpoint: ConnectorCheckpointUpdate,
  )
  GetStoredEvidence(
    reply_to: process.Subject(Result(Option(StoredEvidence), String)),
    event_id: String,
  )
  ListEvidenceConcernLinks(
    reply_to: process.Subject(Result(List(evidence.ConcernLink), String)),
    event_id: String,
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
  GetIntegrationHealth(
    reply_to: process.Subject(Result(Option(IntegrationHealth), String)),
    name: String,
  )
  SaveIntegrationHealth(
    reply_to: process.Subject(Result(Nil, String)),
    health: IntegrationHealth,
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
  SaveExternalAsk(
    reply_to: process.Subject(Result(Bool, String)),
    ask: StoredExternalAsk,
  )
  UpdateExternalAskDecision(
    reply_to: process.Subject(Result(Bool, String)),
    id: String,
    status: String,
    decision: String,
    updated_at_ms: Int,
  )
  UpdateExternalAskMessageId(
    reply_to: process.Subject(Result(Nil, String)),
    id: String,
    message_id: String,
    updated_at_ms: Int,
  )
  GetExternalAsk(
    reply_to: process.Subject(Result(Option(StoredExternalAsk), String)),
    id: String,
  )
  ListExternalAsks(
    reply_to: process.Subject(Result(List(StoredExternalAsk), String)),
    limit: Int,
  )
  ListEventSources(
    reply_to: process.Subject(Result(List(#(String, Int, Int)), String)),
  )
  LinkConcernIdempotently(
    reply_to: process.Subject(Result(MutationReceipt, String)),
    idempotency_key: String,
    concern_id: String,
    kind: String,
    linked_id: String,
    result_json: String,
    occurred_at_ms: Int,
  )
  GetMutationReceipt(
    reply_to: process.Subject(Result(Option(MutationReceipt), String)),
    idempotency_key: String,
  )
  CheckMutationIdempotency(
    reply_to: process.Subject(Result(Option(MutationReceipt), String)),
    idempotency_key: String,
    operation_type: String,
    payload_json: String,
  )
  ClaimOperationalMutation(
    reply_to: process.Subject(Result(Option(MutationReceipt), String)),
    idempotency_key: String,
    operation_type: String,
    payload_json: String,
    claimed_at_ms: Int,
  )
  AbandonOperationalMutation(
    reply_to: process.Subject(Result(Nil, String)),
    idempotency_key: String,
    operation_type: String,
    payload_json: String,
  )
  CompleteOperationalMutation(
    reply_to: process.Subject(Result(MutationReceipt, String)),
    idempotency_key: String,
    operation_type: String,
    payload_json: String,
    target_type: String,
    target_id: String,
    action: String,
    result_json: String,
    concern_domain_id: Option(String),
    occurred_at_ms: Int,
  )
  ListConcernLinks(
    reply_to: process.Subject(Result(List(#(String, String)), String)),
    concern_id: String,
  )
  AppendOperationalAudit(
    reply_to: process.Subject(Result(Nil, String)),
    record: operational_audit.Record,
  )
  ListOperationalAudit(
    reply_to: process.Subject(Result(List(operational_audit.Record), String)),
    target_type: String,
    target_id: String,
  )
  CollectCanaryMetrics(
    reply_to: process.Subject(Result(List(CanaryMetricCount), String)),
    authorization_id: String,
    metric_ids: List(String),
  )
  CreateCanaryPreparationAuthorization(
    reply_to: process.Subject(
      Result(StoredCanaryPreparationAuthorization, String),
    ),
    authorization: operating_contracts.CanaryPreparationAuthorizationV1,
  )
  GetCanaryPreparationAuthorization(
    reply_to: process.Subject(
      Result(Option(StoredCanaryPreparationAuthorization), String),
    ),
    authorization_id: String,
  )
  CreateCanaryAuthorization(
    reply_to: process.Subject(Result(StoredCanaryAuthorization, String)),
    authorization: operating_contracts.CanaryAuthorizationV1,
  )
  GetCanaryAuthorization(
    reply_to: process.Subject(Result(Option(StoredCanaryAuthorization), String)),
    authorization_id: String,
  )
  GetEffectiveConnectorActivation(
    reply_to: process.Subject(
      Result(Option(operating_contracts.ConnectorActivationV1), String),
    ),
    activation_id: String,
    authorization_id: String,
  )
  ListEffectiveConnectorActivations(
    reply_to: process.Subject(
      Result(List(operating_contracts.ConnectorActivationV1), String),
    ),
  )
  ReserveConnectorRead(
    reply_to: process.Subject(Result(ConnectorReadAttempt, String)),
    attempt_id: String,
    activation_id: String,
    authorization_id: String,
    worker_id: String,
    lease_ms: Int,
  )
  BeginConnectorRead(
    reply_to: process.Subject(Result(Nil, String)),
    attempt_id: String,
    worker_id: String,
  )
  RenewConnectorRead(
    reply_to: process.Subject(Result(ConnectorReadAttempt, String)),
    attempt_id: String,
    worker_id: String,
    expected_attempt_version: Int,
    lease_ms: Int,
  )
  GetConnectorCheckpoint(
    reply_to: process.Subject(Result(Option(ConnectorCheckpoint), String)),
    configuration_ref: String,
    activation_id: String,
  )
  RecordConnectorReadFailure(
    reply_to: process.Subject(Result(ConnectorReadAttempt, String)),
    context: operating_contracts.ConnectorSubmissionContext,
    next_due_at_ms: Int,
    error_code: String,
    effect_unknown: Bool,
  )
  FinishConnectorRead(
    reply_to: process.Subject(Result(Nil, String)),
    attempt_id: String,
    worker_id: String,
    phase: String,
    error_code: String,
  )
  RecoverExpiredConnectorReads(reply_to: process.Subject(Result(Int, String)))
  CreateGoogleOAuthSession(
    reply_to: process.Subject(Result(GoogleOAuthSession, String)),
    session: GoogleOAuthSession,
  )
  RegisterGoogleOAuthClientSet(
    reply_to: process.Subject(Result(GoogleOAuthClientSet, String)),
    client_set: GoogleOAuthClientSet,
  )
  ClaimGoogleOAuthSession(
    reply_to: process.Subject(Result(GoogleOAuthSession, String)),
    session_ref: String,
    accept_before_ms: Int,
  )
  FinishGoogleOAuthSession(
    reply_to: process.Subject(Result(GoogleOAuthSession, String)),
    session_ref: String,
    phase: String,
    error_class: String,
  )
  RecoverGoogleOAuthSession(
    reply_to: process.Subject(Result(GoogleOAuthSession, String)),
    session_ref: String,
  )
  ExpireGoogleOAuthSessions(reply_to: process.Subject(Result(Int, String)))
  BeginGoogleExternalEffect(
    reply_to: process.Subject(Result(GoogleExternalEffect, String)),
    effect: GoogleExternalEffect,
  )
  GetGoogleExternalEffect(
    reply_to: process.Subject(Result(Option(GoogleExternalEffect), String)),
    effect_id: String,
  )
  GetGoogleExternalEffectByProof(
    reply_to: process.Subject(Result(GoogleExternalEffect, String)),
    proof_ref: String,
  )
  GetLatestGoogleExternalEffect(
    reply_to: process.Subject(Result(Option(GoogleExternalEffect), String)),
    logical_effect_key: String,
  )
  NextGoogleExternalEffectAttempt(
    reply_to: process.Subject(Result(Int, String)),
    logical_effect_key: String,
    effect_kind: String,
  )
  FinishGoogleExternalEffect(
    reply_to: process.Subject(Result(GoogleExternalEffect, String)),
    effect_id: String,
    phase: String,
    proof_ref: String,
    account_fingerprint: String,
    result_hash: String,
    error_class: String,
  )
  TransitionConnectorActivationSet(
    reply_to: process.Subject(
      Result(List(operating_contracts.ConnectorActivationV1), String),
    ),
    authorization_id: String,
    idempotency_key: String,
    actor_ref: String,
    authority_grants: List(String),
    operation: String,
  )
  EnqueueAttention(
    reply_to: process.Subject(
      Result(operating_contracts.AttentionQueueItem, String),
    ),
    request: attention_queue.EnqueueRequest,
  )
  EnqueueAuthorizedAttention(
    reply_to: process.Subject(
      Result(operating_contracts.AttentionQueueItem, String),
    ),
    request: attention_queue.EnqueueRequest,
    authorization_id: String,
  )
  GetAttention(
    reply_to: process.Subject(
      Result(operating_contracts.AttentionQueueItem, String),
    ),
    queue_id: String,
  )
  ListAttention(
    reply_to: process.Subject(
      Result(List(operating_contracts.AttentionQueueItem), String),
    ),
    delivery_owner: String,
    state: String,
  )
  ClaimAttention(
    reply_to: process.Subject(Result(Option(attention_queue.Claim), String)),
    delivery_owner: String,
    worker_id: String,
    lease_ms: Int,
    now: Int,
  )
  ClaimAuthorizedAttention(
    reply_to: process.Subject(Result(Option(attention_queue.Claim), String)),
    worker_id: String,
    lease_ms: Int,
    now: Int,
    route: MonitorRoute,
  )
  BeginAttentionDelivery(
    reply_to: process.Subject(Result(Nil, String)),
    lease_token: String,
    now: Int,
  )
  BeginAuthorizedAttentionDelivery(
    reply_to: process.Subject(Result(Nil, String)),
    lease_token: String,
  )
  RenewAttentionLease(
    reply_to: process.Subject(Result(Nil, String)),
    lease_token: String,
    lease_ms: Int,
    now: Int,
  )
  RescheduleAttention(
    reply_to: process.Subject(Result(Nil, String)),
    lease_token: String,
    error: String,
    available_at: Int,
    now: Int,
  )
  ExpireAttention(
    reply_to: process.Subject(Result(Int, String)),
    delivery_owner: String,
    now: Int,
  )
  RecoverAttention(
    reply_to: process.Subject(Result(attention_queue.RecoverySummary, String)),
    delivery_owner: String,
    now: Int,
  )
  CompleteAttentionDelivery(
    reply_to: process.Subject(Result(Nil, String)),
    lease_token: String,
    channel_id: String,
    visible_content: String,
    receipts: List(String),
    now: Int,
  )
  MarkAttentionEffectUnknown(
    reply_to: process.Subject(Result(Nil, String)),
    lease_token: String,
    channel_id: String,
    visible_content: String,
    receipts: List(String),
    error: String,
    now: Int,
  )
  AcknowledgeAttention(
    reply_to: process.Subject(Result(Nil, String)),
    queue_id: String,
    actor_id: String,
    now: Int,
  )
  ListAttentionAttempts(
    reply_to: process.Subject(
      Result(List(attention_queue.DeliveryAttempt), String),
    ),
    queue_id: String,
  )
  ApplyMonitorOutcome(
    reply_to: process.Subject(
      Result(operating_contracts.MonitorOutcomeReceipt, String),
    ),
    outcome: operating_contracts.MonitorOutcome,
  )
  ApplyAuthorizedMonitorOutcome(
    reply_to: process.Subject(
      Result(operating_contracts.MonitorOutcomeReceipt, String),
    ),
    outcome: operating_contracts.MonitorOutcome,
    route: MonitorRoute,
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
  case actor.start(builder(path)) {
    Ok(started) -> Ok(started.data)
    Error(err) -> Error("Failed to start db actor: " <> string.inspect(err))
  }
}

fn builder(
  path: String,
) -> actor.Builder(DbState, DbMessage, process.Subject(DbMessage)) {
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
}

/// Start a named database actor for use in a restart tree.
pub fn start_named(
  path: String,
  name: process.Name(DbMessage),
) -> Result(actor.Started(process.Subject(DbMessage)), actor.StartError) {
  builder(path)
  |> actor.named(name)
  |> actor.start
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

/// Append one Discord compatibility message and its compact delivery audit in
/// one transaction. The audit record does not contain message content.
pub fn append_delivery_message_with_audit(
  subject: process.Subject(DbMessage),
  platform_id: String,
  event_id: String,
  content: String,
  timestamp: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    AppendDeliveryMessageWithAudit(
      reply_to:,
      platform_id:,
      event_id:,
      content:,
      timestamp:,
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

/// Insert or replace a flare and append its audit event in one transaction.
pub fn upsert_flare_with_event(
  subject: process.Subject(DbMessage),
  stored: StoredFlare,
  event: StoredFlareEvent,
) -> Result(Nil, String) {
  process.call(subject, 10_000, fn(reply_to) {
    UpsertFlareWithEvent(reply_to:, stored:, event:)
  })
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

/// Append an audit event for a flare. `sequence` is assigned automatically
/// as one past the current maximum for the flare.
pub fn append_flare_event(
  subject: process.Subject(DbMessage),
  event: StoredFlareEvent,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    AppendFlareEvent(reply_to:, event:)
  })
}

/// List audit events for a flare, ordered by `sequence`.
pub fn list_flare_events(
  subject: process.Subject(DbMessage),
  flare_id: String,
) -> Result(List(StoredFlareEvent), String) {
  process.call(subject, 5000, fn(reply_to) {
    ListFlareEvents(reply_to:, flare_id:)
  })
}

/// Create a new execution attempt for a flare and return its auto-generated id.
pub fn create_flare_attempt(
  subject: process.Subject(DbMessage),
  attempt: StoredFlareAttempt,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    CreateFlareAttempt(reply_to:, attempt:)
  })
}

/// Create a flare attempt and its first audit event in one transaction.
pub fn create_flare_attempt_with_event(
  subject: process.Subject(DbMessage),
  attempt: StoredFlareAttempt,
  event: StoredFlareEvent,
) -> Result(Int, String) {
  process.call(subject, 10_000, fn(reply_to) {
    CreateFlareAttemptWithEvent(reply_to:, attempt:, event:)
  })
}

/// Update an existing execution attempt record.
pub fn update_flare_attempt(
  subject: process.Subject(DbMessage),
  attempt: StoredFlareAttempt,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateFlareAttempt(reply_to:, attempt:)
  })
}

/// List execution attempts for a flare, oldest first.
pub fn list_flare_attempts(
  subject: process.Subject(DbMessage),
  flare_id: String,
) -> Result(List(StoredFlareAttempt), String) {
  process.call(subject, 5000, fn(reply_to) {
    ListFlareAttempts(reply_to:, flare_id:)
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

/// Return the latest persisted result_text for a flare, or an empty string.
pub fn get_flare_result(
  subject: process.Subject(DbMessage),
  id: String,
) -> Result(String, String) {
  process.call(subject, 5000, fn(reply_to) { GetFlareResult(reply_to:, id:) })
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

/// Store one normalized evidence envelope, its legacy event view, concern
/// candidates, and audit record in one transaction.
pub fn insert_normalized_evidence(
  subject: process.Subject(DbMessage),
  envelope: operating_contracts.EvidenceEvent,
  concern_links: List(evidence.ConcernLink),
) -> Result(EvidenceInsert, String) {
  process.call(subject, 10_000, fn(reply_to) {
    InsertNormalizedEvidence(reply_to:, envelope:, concern_links:)
  })
}

/// Submit evidence only for a current, started, authorized connector read.
pub fn submit_authorized_connector_evidence(
  subject: process.Subject(DbMessage),
  context: operating_contracts.ConnectorSubmissionContext,
  envelope: operating_contracts.EvidenceEvent,
  concern_links: List(evidence.ConcernLink),
) -> Result(Option(EvidenceInsert), String) {
  process.call(subject, 10_000, fn(reply_to) {
    SubmitAuthorizedConnectorEvidence(
      reply_to:,
      context:,
      envelope:,
      concern_links:,
    )
  })
}

/// Submit one bounded evidence batch for one current connector read attempt.
/// The activation check, all inserts, attempt completion, and audit are atomic.
pub fn submit_authorized_connector_evidence_batch(
  subject: process.Subject(DbMessage),
  context: operating_contracts.ConnectorSubmissionContext,
  evidence_items: List(
    #(operating_contracts.EvidenceEvent, List(evidence.ConcernLink)),
  ),
) -> Result(Option(List(EvidenceInsert)), String) {
  process.call(subject, 10_000, fn(reply_to) {
    SubmitAuthorizedConnectorEvidenceBatch(reply_to:, context:, evidence_items:)
  })
}

/// Submit evidence and advance one connector checkpoint atomically.
pub fn submit_authorized_connector_evidence_batch_with_checkpoint(
  subject: process.Subject(DbMessage),
  context: operating_contracts.ConnectorSubmissionContext,
  evidence_items: List(
    #(operating_contracts.EvidenceEvent, List(evidence.ConcernLink)),
  ),
  checkpoint: ConnectorCheckpointUpdate,
) -> Result(Option(List(EvidenceInsert)), String) {
  process.call(subject, 10_000, fn(reply_to) {
    SubmitAuthorizedConnectorEvidenceBatchWithCheckpoint(
      reply_to:,
      context:,
      evidence_items:,
      checkpoint:,
    )
  })
}

/// Load one compact normalized evidence record.
pub fn get_stored_evidence(
  subject: process.Subject(DbMessage),
  event_id: String,
) -> Result(Option(StoredEvidence), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetStoredEvidence(reply_to:, event_id:)
  })
}

/// Load explicit evidence-to-concern candidate metadata.
pub fn list_evidence_concern_links(
  subject: process.Subject(DbMessage),
  event_id: String,
) -> Result(List(evidence.ConcernLink), String) {
  process.call(subject, 5000, fn(reply_to) {
    ListEvidenceConcernLinks(reply_to:, event_id:)
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

/// Load the current health row for an integration.
pub fn get_integration_health(
  subject: process.Subject(DbMessage),
  name: String,
) -> Result(Option(IntegrationHealth), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetIntegrationHealth(reply_to: reply_to, name: name)
  })
}

/// Upsert the current health row for an integration.
pub fn save_integration_health(
  subject: process.Subject(DbMessage),
  health: IntegrationHealth,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    SaveIntegrationHealth(reply_to: reply_to, health: health)
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

/// Persist an external ask row with INSERT OR IGNORE semantics. Returns
/// `True` if it was a new row, `False` if the id already existed.
pub fn save_external_ask(
  subject: process.Subject(DbMessage),
  ask: StoredExternalAsk,
) -> Result(Bool, String) {
  process.call(subject, 5000, fn(reply_to) {
    SaveExternalAsk(reply_to: reply_to, ask: ask)
  })
}

/// Transition an external ask out of `pending`. Returns `True` if a row was
/// updated (it was still pending), `False` otherwise. Same conditional
/// discipline as shell approvals.
pub fn update_external_ask_decision(
  subject: process.Subject(DbMessage),
  id: String,
  status: String,
  decision: String,
  updated_at_ms: Int,
) -> Result(Bool, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateExternalAskDecision(
      reply_to: reply_to,
      id: id,
      status: status,
      decision: decision,
      updated_at_ms: updated_at_ms,
    )
  })
}

/// Attach the posted Discord message id to a pending ask.
pub fn update_external_ask_message_id(
  subject: process.Subject(DbMessage),
  id: String,
  message_id: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    UpdateExternalAskMessageId(
      reply_to: reply_to,
      id: id,
      message_id: message_id,
      updated_at_ms: updated_at_ms,
    )
  })
}

/// Fetch one external ask by id.
pub fn get_external_ask(
  subject: process.Subject(DbMessage),
  id: String,
) -> Result(Option(StoredExternalAsk), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetExternalAsk(reply_to: reply_to, id: id)
  })
}

/// List external asks, newest first by requested_at_ms.
pub fn list_external_asks(
  subject: process.Subject(DbMessage),
  limit: Int,
) -> Result(List(StoredExternalAsk), String) {
  process.call(subject, 5000, fn(reply_to) {
    ListExternalAsks(reply_to: reply_to, limit: limit)
  })
}

/// List event sources and activity, ordered by count descending.
pub fn list_event_sources(
  subject: process.Subject(DbMessage),
) -> Result(List(#(String, Int, Int)), String) {
  process.call(subject, 5000, fn(reply_to) {
    ListEventSources(reply_to: reply_to)
  })
}

/// Add one concern link, audit row, and immutable mutation receipt in one
/// transaction. Aura derives the payload hash from the mutation fields. A
/// replay of the same mutation returns the first receipt. A changed mutation
/// with the same key returns `idempotency_conflict`.
pub fn link_concern_idempotently(
  subject: process.Subject(DbMessage),
  idempotency_key: String,
  concern_id: String,
  kind: String,
  linked_id: String,
  result_json: String,
  occurred_at_ms: Int,
) -> Result(MutationReceipt, String) {
  process.call(subject, 10_000, fn(reply_to) {
    LinkConcernIdempotently(
      reply_to:,
      idempotency_key:,
      concern_id:,
      kind:,
      linked_id:,
      result_json:,
      occurred_at_ms:,
    )
  })
}

/// Load one immutable mutation receipt by idempotency key.
pub fn get_mutation_receipt(
  subject: process.Subject(DbMessage),
  idempotency_key: String,
) -> Result(Option(MutationReceipt), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetMutationReceipt(reply_to:, idempotency_key:)
  })
}

/// Check a file-backed mutation before its file effect. A matching replay
/// returns its first receipt. A changed payload returns a conflict.
pub fn check_mutation_idempotency(
  subject: process.Subject(DbMessage),
  idempotency_key: String,
  operation_type: String,
  payload_json: String,
) -> Result(Option(MutationReceipt), String) {
  process.call(subject, 5000, fn(reply_to) {
    CheckMutationIdempotency(
      reply_to:,
      idempotency_key:,
      operation_type:,
      payload_json:,
    )
  })
}

/// Claim one file-backed mutation before the file write. `None` means this
/// caller owns the claim. `Some` is an existing pending or complete receipt.
pub fn claim_operational_mutation(
  subject: process.Subject(DbMessage),
  idempotency_key: String,
  operation_type: String,
  payload_json: String,
  claimed_at_ms: Int,
) -> Result(Option(MutationReceipt), String) {
  process.call(subject, 5000, fn(reply_to) {
    ClaimOperationalMutation(
      reply_to:,
      idempotency_key:,
      operation_type:,
      payload_json:,
      claimed_at_ms:,
    )
  })
}

/// Remove this caller's pending claim after a file write fails.
pub fn abandon_operational_mutation(
  subject: process.Subject(DbMessage),
  idempotency_key: String,
  operation_type: String,
  payload_json: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    AbandonOperationalMutation(
      reply_to:,
      idempotency_key:,
      operation_type:,
      payload_json:,
    )
  })
}

/// Store one file-backed operational mutation receipt and audit record in one
/// SQLite transaction. Concern mutations also maintain the domain link index.
pub fn complete_operational_mutation(
  subject: process.Subject(DbMessage),
  idempotency_key: String,
  operation_type: String,
  payload_json: String,
  target_type: String,
  target_id: String,
  action: String,
  result_json: String,
  concern_domain_id: Option(String),
  occurred_at_ms: Int,
) -> Result(MutationReceipt, String) {
  process.call(subject, 10_000, fn(reply_to) {
    CompleteOperationalMutation(
      reply_to:,
      idempotency_key:,
      operation_type:,
      payload_json:,
      target_type:,
      target_id:,
      action:,
      result_json:,
      concern_domain_id:,
      occurred_at_ms:,
    )
  })
}

/// List compact concern links in creation order.
pub fn list_concern_links(
  subject: process.Subject(DbMessage),
  concern_id: String,
) -> Result(List(#(String, String)), String) {
  process.call(subject, 5000, fn(reply_to) {
    ListConcernLinks(reply_to:, concern_id:)
  })
}

/// Append one general operational audit record.
pub fn append_operational_audit(
  subject: process.Subject(DbMessage),
  record: operational_audit.Record,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    AppendOperationalAudit(reply_to:, record:)
  })
}

/// List general operational audit records for one target, oldest first.
pub fn list_operational_audit(
  subject: process.Subject(DbMessage),
  target_type: String,
  target_id: String,
) -> Result(List(operational_audit.Record), String) {
  process.call(subject, 5000, fn(reply_to) {
    ListOperationalAudit(reply_to:, target_type:, target_id:)
  })
}

/// Count only authorized canary metrics from persisted operational records.
pub fn collect_canary_metrics(
  subject: process.Subject(DbMessage),
  authorization_id: String,
  metric_ids: List(String),
) -> Result(List(CanaryMetricCount), String) {
  process.call(subject, 5000, fn(reply_to) {
    CollectCanaryMetrics(reply_to:, authorization_id:, metric_ids:)
  })
}

/// Create or replay one immutable preparation authorization and its audit.
pub fn create_canary_preparation_authorization(
  subject: process.Subject(DbMessage),
  authorization: operating_contracts.CanaryPreparationAuthorizationV1,
) -> Result(StoredCanaryPreparationAuthorization, String) {
  process.call(subject, 10_000, fn(reply_to) {
    CreateCanaryPreparationAuthorization(reply_to:, authorization:)
  })
}

/// Load one immutable preparation authorization by ID.
pub fn get_canary_preparation_authorization(
  subject: process.Subject(DbMessage),
  authorization_id: String,
) -> Result(Option(StoredCanaryPreparationAuthorization), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetCanaryPreparationAuthorization(reply_to:, authorization_id:)
  })
}

/// Create or replay one immutable final canary authorization and its audit.
pub fn create_canary_authorization(
  subject: process.Subject(DbMessage),
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> Result(StoredCanaryAuthorization, String) {
  process.call(subject, 10_000, fn(reply_to) {
    CreateCanaryAuthorization(reply_to:, authorization:)
  })
}

/// Load one immutable final canary authorization by ID.
pub fn get_canary_authorization(
  subject: process.Subject(DbMessage),
  authorization_id: String,
) -> Result(Option(StoredCanaryAuthorization), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetCanaryAuthorization(reply_to:, authorization_id:)
  })
}

/// Load one enabled, non-expired connector activation by activation ID.
pub fn get_effective_connector_activation(
  subject: process.Subject(DbMessage),
  activation_id: String,
  authorization_id: String,
) -> Result(Option(operating_contracts.ConnectorActivationV1), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetEffectiveConnectorActivation(
      reply_to:,
      activation_id:,
      authorization_id:,
    )
  })
}

/// Load all enabled, non-expired connector activations at Aura server time.
pub fn list_effective_connector_activations(
  subject: process.Subject(DbMessage),
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  process.call(subject, 5000, fn(reply_to) {
    ListEffectiveConnectorActivations(reply_to:)
  })
}

/// Reserve one read only while its activation is enabled and authorized.
pub fn reserve_connector_read(
  subject: process.Subject(DbMessage),
  attempt_id: String,
  activation_id: String,
  authorization_id: String,
  worker_id: String,
  lease_ms: Int,
) -> Result(ConnectorReadAttempt, String) {
  process.call(subject, 5000, fn(reply_to) {
    ReserveConnectorRead(
      reply_to:,
      attempt_id:,
      activation_id:,
      authorization_id:,
      worker_id:,
      lease_ms:,
    )
  })
}

/// Record the local start of an already reserved read.
pub fn begin_connector_read(
  subject: process.Subject(DbMessage),
  attempt_id: String,
  worker_id: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    BeginConnectorRead(reply_to:, attempt_id:, worker_id:)
  })
}

/// Renew one active connector-read lease with owner and version checks.
pub fn renew_connector_read(
  subject: process.Subject(DbMessage),
  attempt_id: String,
  worker_id: String,
  expected_attempt_version: Int,
  lease_ms: Int,
) -> Result(ConnectorReadAttempt, String) {
  process.call(subject, 5000, fn(reply_to) {
    RenewConnectorRead(
      reply_to:,
      attempt_id:,
      worker_id:,
      expected_attempt_version:,
      lease_ms:,
    )
  })
}

/// Load one connector checkpoint for an exact activation.
pub fn get_connector_checkpoint(
  subject: process.Subject(DbMessage),
  configuration_ref: String,
  activation_id: String,
) -> Result(Option(ConnectorCheckpoint), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetConnectorCheckpoint(reply_to:, configuration_ref:, activation_id:)
  })
}

/// Atomically record one provider-read failure, retry checkpoint, and audit.
pub fn record_connector_read_failure(
  subject: process.Subject(DbMessage),
  context: operating_contracts.ConnectorSubmissionContext,
  next_due_at_ms: Int,
  error_code: String,
  effect_unknown: Bool,
) -> Result(ConnectorReadAttempt, String) {
  process.call(subject, 5000, fn(reply_to) {
    RecordConnectorReadFailure(
      reply_to:,
      context:,
      next_due_at_ms:,
      error_code:,
      effect_unknown:,
    )
  })
}

/// Atomically finish a read attempt and append its audit record.
pub fn finish_connector_read(
  subject: process.Subject(DbMessage),
  attempt_id: String,
  worker_id: String,
  phase: String,
  error_code: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    FinishConnectorRead(reply_to:, attempt_id:, worker_id:, phase:, error_code:)
  })
}

/// Interrupt expired connector reads without accepting any late response.
pub fn recover_expired_connector_reads(
  subject: process.Subject(DbMessage),
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    RecoverExpiredConnectorReads(reply_to:)
  })
}

/// Create or replay one secret-free Google OAuth session record.
pub fn register_google_oauth_client_set(
  subject: process.Subject(DbMessage),
  client_set: GoogleOAuthClientSet,
) -> Result(GoogleOAuthClientSet, String) {
  process.call(subject, 5000, fn(reply_to) {
    RegisterGoogleOAuthClientSet(reply_to:, client_set:)
  })
}

/// Create or replay one secret-free Google OAuth session record.
pub fn create_google_oauth_session(
  subject: process.Subject(DbMessage),
  session: GoogleOAuthSession,
) -> Result(GoogleOAuthSession, String) {
  process.call(subject, 5000, fn(reply_to) {
    CreateGoogleOAuthSession(reply_to:, session:)
  })
}

/// Claim one waiting Google OAuth callback session once.
pub fn claim_google_oauth_session(
  subject: process.Subject(DbMessage),
  session_ref: String,
) -> Result(GoogleOAuthSession, String) {
  claim_google_oauth_session_before(subject, session_ref, 9_999_999_999_999)
}

/// Claim one callback only before its server-issued acceptance deadline.
pub fn claim_google_oauth_session_before(
  subject: process.Subject(DbMessage),
  session_ref: String,
  accept_before_ms: Int,
) -> Result(GoogleOAuthSession, String) {
  process.call(subject, 5000, fn(reply_to) {
    ClaimGoogleOAuthSession(reply_to:, session_ref:, accept_before_ms:)
  })
}

/// Finish one claimed Google OAuth session with a terminal phase.
pub fn finish_google_oauth_session(
  subject: process.Subject(DbMessage),
  session_ref: String,
  phase: String,
  error_class: String,
) -> Result(GoogleOAuthSession, String) {
  process.call(subject, 5000, fn(reply_to) {
    FinishGoogleOAuthSession(reply_to:, session_ref:, phase:, error_class:)
  })
}

/// Recover one claimed session after its private one-shot owner fails.
pub fn recover_google_oauth_session(
  subject: process.Subject(DbMessage),
  session_ref: String,
) -> Result(GoogleOAuthSession, String) {
  process.call(subject, 5000, fn(reply_to) {
    RecoverGoogleOAuthSession(reply_to:, session_ref:)
  })
}

/// Resolve all non-terminal Google OAuth sessions during owner recovery.
pub fn expire_google_oauth_sessions(
  subject: process.Subject(DbMessage),
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    ExpireGoogleOAuthSessions(reply_to:)
  })
}

/// Store or replay one durable Google external-effect intent.
pub fn begin_google_external_effect(
  subject: process.Subject(DbMessage),
  effect: GoogleExternalEffect,
) -> Result(GoogleExternalEffect, String) {
  process.call(subject, 5000, fn(reply_to) {
    BeginGoogleExternalEffect(reply_to:, effect:)
  })
}

/// Load one Google external effect by its opaque identifier.
pub fn get_google_external_effect(
  subject: process.Subject(DbMessage),
  effect_id: String,
) -> Result(Option(GoogleExternalEffect), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetGoogleExternalEffect(reply_to:, effect_id:)
  })
}

/// Load one successful Google effect by its opaque proof reference.
pub fn get_google_external_effect_by_proof(
  subject: process.Subject(DbMessage),
  proof_ref: String,
) -> Result(GoogleExternalEffect, String) {
  process.call(subject, 5000, fn(reply_to) {
    GetGoogleExternalEffectByProof(reply_to:, proof_ref:)
  })
}

/// Load the latest attempt for one Google logical effect.
pub fn get_latest_google_external_effect(
  subject: process.Subject(DbMessage),
  logical_effect_key: String,
) -> Result(Option(GoogleExternalEffect), String) {
  process.call(subject, 5000, fn(reply_to) {
    GetLatestGoogleExternalEffect(reply_to:, logical_effect_key:)
  })
}

/// Resolve the next permitted attempt for one retryable Google effect.
pub fn next_google_external_effect_attempt(
  subject: process.Subject(DbMessage),
  logical_effect_key: String,
  effect_kind: String,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    NextGoogleExternalEffectAttempt(
      reply_to:,
      logical_effect_key:,
      effect_kind:,
    )
  })
}

/// Finish one Google external effect with a terminal outcome.
pub fn finish_google_external_effect(
  subject: process.Subject(DbMessage),
  effect_id: String,
  phase: String,
  proof_ref: String,
  account_fingerprint: String,
  result_hash: String,
  error_class: String,
) -> Result(GoogleExternalEffect, String) {
  process.call(subject, 5000, fn(reply_to) {
    FinishGoogleExternalEffect(
      reply_to:,
      effect_id:,
      phase:,
      proof_ref:,
      account_fingerprint:,
      result_hash:,
      error_class:,
    )
  })
}

/// Apply one audited connector-activation set transition in SQLite.
pub fn transition_connector_activation_set(
  subject: process.Subject(DbMessage),
  authorization_id: String,
  idempotency_key: String,
  actor_ref: String,
  authority_grants: List(String),
  operation: String,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  process.call(subject, 10_000, fn(reply_to) {
    TransitionConnectorActivationSet(
      reply_to:,
      authorization_id:,
      idempotency_key:,
      actor_ref:,
      authority_grants:,
      operation:,
    )
  })
}

/// Enqueue one approved attention item idempotently with its audit record.
pub fn enqueue_attention(
  subject: process.Subject(DbMessage),
  request: attention_queue.EnqueueRequest,
) -> Result(operating_contracts.AttentionQueueItem, String) {
  process.call(subject, 5000, fn(reply_to) {
    EnqueueAttention(reply_to:, request:)
  })
}

/// Enqueue one approved Codex item under an effective canary authorization.
pub fn enqueue_authorized_attention(
  subject: process.Subject(DbMessage),
  request: attention_queue.EnqueueRequest,
  authorization_id: String,
) -> Result(operating_contracts.AttentionQueueItem, String) {
  process.call(subject, 5000, fn(reply_to) {
    EnqueueAuthorizedAttention(reply_to:, request:, authorization_id:)
  })
}

/// Load one attention item by its durable identifier.
pub fn get_attention(
  subject: process.Subject(DbMessage),
  queue_id: String,
) -> Result(operating_contracts.AttentionQueueItem, String) {
  process.call(subject, 5000, fn(reply_to) {
    GetAttention(reply_to:, queue_id:)
  })
}

/// List attention items for one delivery owner and lifecycle state.
pub fn list_attention(
  subject: process.Subject(DbMessage),
  delivery_owner: String,
  state: String,
) -> Result(List(operating_contracts.AttentionQueueItem), String) {
  process.call(subject, 5000, fn(reply_to) {
    ListAttention(reply_to:, delivery_owner:, state:)
  })
}

/// Claim the oldest available item with an exclusive lease.
pub fn claim_attention(
  subject: process.Subject(DbMessage),
  delivery_owner: String,
  worker_id: String,
  lease_ms: Int,
  now: Int,
) -> Result(Option(attention_queue.Claim), String) {
  process.call(subject, 5000, fn(reply_to) {
    ClaimAttention(reply_to:, delivery_owner:, worker_id:, lease_ms:, now:)
  })
}

/// Claim one item only when its complete authorized route matches.
pub fn claim_authorized_attention(
  subject: process.Subject(DbMessage),
  worker_id: String,
  lease_ms: Int,
  route: MonitorRoute,
  now: Int,
) -> Result(Option(attention_queue.Claim), String) {
  process.call(subject, 5000, fn(reply_to) {
    ClaimAuthorizedAttention(reply_to:, worker_id:, lease_ms:, now:, route:)
  })
}

/// Record durable external-effect intent for the current lease.
pub fn begin_attention_delivery(
  subject: process.Subject(DbMessage),
  lease_token: String,
  now: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    BeginAttentionDelivery(reply_to:, lease_token:, now:)
  })
}

/// Record authorized monitor intent using time resolved in the DB transaction.
pub fn begin_authorized_attention_delivery(
  subject: process.Subject(DbMessage),
  lease_token: String,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    BeginAuthorizedAttentionDelivery(reply_to:, lease_token:)
  })
}

/// Renew the current claim before its lease expires.
pub fn renew_attention_lease(
  subject: process.Subject(DbMessage),
  lease_token: String,
  lease_ms: Int,
  now: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    RenewAttentionLease(reply_to:, lease_token:, lease_ms:, now:)
  })
}

/// Reschedule a pre-intent claim after a deterministic adapter failure.
pub fn reschedule_attention(
  subject: process.Subject(DbMessage),
  lease_token: String,
  error: String,
  available_at: Int,
  now: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    RescheduleAttention(reply_to:, lease_token:, error:, available_at:, now:)
  })
}

/// Expire due unclaimed items with one audit transition per item.
pub fn expire_attention(
  subject: process.Subject(DbMessage),
  delivery_owner: String,
  now: Int,
) -> Result(Int, String) {
  process.call(subject, 5000, fn(reply_to) {
    ExpireAttention(reply_to:, delivery_owner:, now:)
  })
}

/// Recover all expired claims for one delivery owner.
pub fn recover_attention(
  subject: process.Subject(DbMessage),
  delivery_owner: String,
  now: Int,
) -> Result(attention_queue.RecoverySummary, String) {
  process.call(subject, 5000, fn(reply_to) {
    RecoverAttention(reply_to:, delivery_owner:, now:)
  })
}

/// Apply one Codex monitor outcome with its receipt and audit atomically.
pub fn apply_monitor_outcome(
  subject: process.Subject(DbMessage),
  outcome: operating_contracts.MonitorOutcome,
) -> Result(operating_contracts.MonitorOutcomeReceipt, String) {
  process.call(subject, 5000, fn(reply_to) {
    ApplyMonitorOutcome(reply_to:, outcome:)
  })
}

/// Apply a Codex outcome only when its complete authorized route matches.
pub fn apply_authorized_monitor_outcome(
  subject: process.Subject(DbMessage),
  outcome: operating_contracts.MonitorOutcome,
  route: MonitorRoute,
) -> Result(operating_contracts.MonitorOutcomeReceipt, String) {
  process.call(subject, 5000, fn(reply_to) {
    ApplyAuthorizedMonitorOutcome(reply_to:, outcome:, route:)
  })
}

/// Commit a successful external effect, audit, and visible history together.
pub fn complete_attention_delivery(
  subject: process.Subject(DbMessage),
  lease_token: String,
  channel_id: String,
  visible_content: String,
  receipts: List(String),
  now: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    CompleteAttentionDelivery(
      reply_to:,
      lease_token:,
      channel_id:,
      visible_content:,
      receipts:,
      now:,
    )
  })
}

/// Commit an uncertain external effect and its known visible history together.
pub fn mark_attention_effect_unknown(
  subject: process.Subject(DbMessage),
  lease_token: String,
  channel_id: String,
  visible_content: String,
  receipts: List(String),
  error: String,
  now: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    MarkAttentionEffectUnknown(
      reply_to:,
      lease_token:,
      channel_id:,
      visible_content:,
      receipts:,
      error:,
      now:,
    )
  })
}

/// Acknowledge a delivered item with an atomic audit transition.
pub fn acknowledge_attention(
  subject: process.Subject(DbMessage),
  queue_id: String,
  actor_id: String,
  now: Int,
) -> Result(Nil, String) {
  process.call(subject, 5000, fn(reply_to) {
    AcknowledgeAttention(reply_to:, queue_id:, actor_id:, now:)
  })
}

/// List delivery attempts for one queue item in attempt order.
pub fn list_attention_attempts(
  subject: process.Subject(DbMessage),
  queue_id: String,
) -> Result(List(attention_queue.DeliveryAttempt), String) {
  process.call(subject, 5000, fn(reply_to) {
    ListAttentionAttempts(reply_to:, queue_id:)
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

    AppendDeliveryMessageWithAudit(
      reply_to:,
      platform_id:,
      event_id:,
      content:,
      timestamp:,
    ) -> {
      let result =
        do_append_delivery_message_with_audit(
          state.conn,
          platform_id,
          event_id,
          content,
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

    UpsertFlareWithEvent(reply_to:, stored:, event:) -> {
      let result = do_upsert_flare_with_event(state.conn, stored, event)
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

    AppendFlareEvent(reply_to:, event:) -> {
      let result = do_append_flare_event(state.conn, event)
      process.send(reply_to, result)
      actor.continue(state)
    }

    ListFlareEvents(reply_to:, flare_id:) -> {
      let result = do_list_flare_events(state.conn, flare_id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    CreateFlareAttempt(reply_to:, attempt:) -> {
      let result = do_create_flare_attempt(state.conn, attempt)
      process.send(reply_to, result)
      actor.continue(state)
    }

    CreateFlareAttemptWithEvent(reply_to:, attempt:, event:) -> {
      let result =
        do_create_flare_attempt_with_event(state.conn, attempt, event)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateFlareAttempt(reply_to:, attempt:) -> {
      let result = do_update_flare_attempt(state.conn, attempt)
      process.send(reply_to, result)
      actor.continue(state)
    }

    ListFlareAttempts(reply_to:, flare_id:) -> {
      let result = do_list_flare_attempts(state.conn, flare_id)
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

    GetFlareResult(reply_to:, id:) -> {
      let result = do_get_flare_result(state.conn, id)
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

    InsertNormalizedEvidence(reply_to:, envelope:, concern_links:) -> {
      let result =
        do_insert_normalized_evidence(state.conn, envelope, concern_links)
      process.send(reply_to, result)
      actor.continue(state)
    }

    SubmitAuthorizedConnectorEvidence(
      reply_to:,
      context:,
      envelope:,
      concern_links:,
    ) -> {
      process.send(
        reply_to,
        do_submit_authorized_connector_evidence(
          state.conn,
          context,
          envelope,
          concern_links,
        ),
      )
      actor.continue(state)
    }

    SubmitAuthorizedConnectorEvidenceBatch(reply_to:, context:, evidence_items:) -> {
      process.send(
        reply_to,
        do_submit_authorized_connector_evidence_batch(
          state.conn,
          context,
          evidence_items,
        ),
      )
      actor.continue(state)
    }

    SubmitAuthorizedConnectorEvidenceBatchWithCheckpoint(
      reply_to:,
      context:,
      evidence_items:,
      checkpoint:,
    ) -> {
      process.send(
        reply_to,
        do_submit_authorized_connector_evidence_batch_with_checkpoint(
          state.conn,
          context,
          evidence_items,
          checkpoint,
        ),
      )
      actor.continue(state)
    }

    GetStoredEvidence(reply_to:, event_id:) -> {
      process.send(reply_to, do_get_stored_evidence(state.conn, event_id))
      actor.continue(state)
    }

    ListEvidenceConcernLinks(reply_to:, event_id:) -> {
      process.send(
        reply_to,
        do_list_evidence_concern_links(state.conn, event_id),
      )
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

    GetIntegrationHealth(reply_to:, name:) -> {
      let result = do_get_integration_health(state.conn, name)
      process.send(reply_to, result)
      actor.continue(state)
    }

    SaveIntegrationHealth(reply_to:, health:) -> {
      let result = do_save_integration_health(state.conn, health)
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

    SaveExternalAsk(reply_to:, ask:) -> {
      let result = do_save_external_ask(state.conn, ask)
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateExternalAskDecision(
      reply_to:,
      id:,
      status:,
      decision:,
      updated_at_ms:,
    ) -> {
      let result =
        do_update_external_ask_decision(
          state.conn,
          id,
          status,
          decision,
          updated_at_ms,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    UpdateExternalAskMessageId(reply_to:, id:, message_id:, updated_at_ms:) -> {
      let result =
        do_update_external_ask_message_id(
          state.conn,
          id,
          message_id,
          updated_at_ms,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetExternalAsk(reply_to:, id:) -> {
      let result = do_get_external_ask(state.conn, id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    ListExternalAsks(reply_to:, limit:) -> {
      let result = do_list_external_asks(state.conn, limit)
      process.send(reply_to, result)
      actor.continue(state)
    }

    ListEventSources(reply_to:) -> {
      let result = do_list_event_sources(state.conn)
      process.send(reply_to, result)
      actor.continue(state)
    }

    LinkConcernIdempotently(
      reply_to:,
      idempotency_key:,
      concern_id:,
      kind:,
      linked_id:,
      result_json:,
      occurred_at_ms:,
    ) -> {
      let result =
        do_link_concern_idempotently(
          state.conn,
          idempotency_key,
          concern_id,
          kind,
          linked_id,
          result_json,
          occurred_at_ms,
        )
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetMutationReceipt(reply_to:, idempotency_key:) -> {
      process.send(
        reply_to,
        do_get_mutation_receipt(state.conn, idempotency_key),
      )
      actor.continue(state)
    }

    CheckMutationIdempotency(
      reply_to:,
      idempotency_key:,
      operation_type:,
      payload_json:,
    ) -> {
      process.send(
        reply_to,
        do_check_mutation_idempotency(
          state.conn,
          idempotency_key,
          operation_type,
          payload_json,
        ),
      )
      actor.continue(state)
    }

    ClaimOperationalMutation(
      reply_to:,
      idempotency_key:,
      operation_type:,
      payload_json:,
      claimed_at_ms:,
    ) -> {
      process.send(
        reply_to,
        do_claim_operational_mutation(
          state.conn,
          idempotency_key,
          operation_type,
          payload_json,
          claimed_at_ms,
        ),
      )
      actor.continue(state)
    }

    AbandonOperationalMutation(
      reply_to:,
      idempotency_key:,
      operation_type:,
      payload_json:,
    ) -> {
      process.send(
        reply_to,
        do_abandon_operational_mutation(
          state.conn,
          idempotency_key,
          operation_type,
          payload_json,
        ),
      )
      actor.continue(state)
    }

    CompleteOperationalMutation(
      reply_to:,
      idempotency_key:,
      operation_type:,
      payload_json:,
      target_type:,
      target_id:,
      action:,
      result_json:,
      concern_domain_id:,
      occurred_at_ms:,
    ) -> {
      process.send(
        reply_to,
        do_complete_operational_mutation(
          state.conn,
          idempotency_key,
          operation_type,
          payload_json,
          target_type,
          target_id,
          action,
          result_json,
          concern_domain_id,
          occurred_at_ms,
        ),
      )
      actor.continue(state)
    }

    ListConcernLinks(reply_to:, concern_id:) -> {
      process.send(reply_to, do_list_concern_links(state.conn, concern_id))
      actor.continue(state)
    }

    AppendOperationalAudit(reply_to:, record:) -> {
      let result = do_append_operational_audit(state.conn, record)
      process.send(reply_to, result |> result.map(fn(_) { Nil }))
      actor.continue(state)
    }

    ListOperationalAudit(reply_to:, target_type:, target_id:) -> {
      process.send(
        reply_to,
        do_list_operational_audit(state.conn, target_type, target_id),
      )
      actor.continue(state)
    }

    CollectCanaryMetrics(reply_to:, authorization_id:, metric_ids:) -> {
      process.send(
        reply_to,
        do_collect_canary_metrics(state.conn, authorization_id, metric_ids),
      )
      actor.continue(state)
    }

    CreateCanaryPreparationAuthorization(reply_to:, authorization:) -> {
      process.send(
        reply_to,
        do_create_canary_preparation_authorization(state.conn, authorization),
      )
      actor.continue(state)
    }

    GetCanaryPreparationAuthorization(reply_to:, authorization_id:) -> {
      process.send(
        reply_to,
        do_get_canary_preparation_authorization(state.conn, authorization_id),
      )
      actor.continue(state)
    }

    CreateCanaryAuthorization(reply_to:, authorization:) -> {
      process.send(
        reply_to,
        do_create_canary_authorization(state.conn, authorization),
      )
      actor.continue(state)
    }

    GetCanaryAuthorization(reply_to:, authorization_id:) -> {
      process.send(
        reply_to,
        do_get_canary_authorization(state.conn, authorization_id),
      )
      actor.continue(state)
    }

    GetEffectiveConnectorActivation(
      reply_to:,
      activation_id:,
      authorization_id:,
    ) -> {
      process.send(
        reply_to,
        do_get_effective_connector_activation(
          state.conn,
          activation_id,
          authorization_id,
        ),
      )
      actor.continue(state)
    }

    ListEffectiveConnectorActivations(reply_to:) -> {
      process.send(
        reply_to,
        do_list_effective_connector_activations(state.conn),
      )
      actor.continue(state)
    }

    ReserveConnectorRead(
      reply_to:,
      attempt_id:,
      activation_id:,
      authorization_id:,
      worker_id:,
      lease_ms:,
    ) -> {
      process.send(
        reply_to,
        do_reserve_connector_read(
          state.conn,
          attempt_id,
          activation_id,
          authorization_id,
          worker_id,
          lease_ms,
        ),
      )
      actor.continue(state)
    }

    BeginConnectorRead(reply_to:, attempt_id:, worker_id:) -> {
      process.send(
        reply_to,
        do_begin_connector_read(state.conn, attempt_id, worker_id),
      )
      actor.continue(state)
    }

    RenewConnectorRead(
      reply_to:,
      attempt_id:,
      worker_id:,
      expected_attempt_version:,
      lease_ms:,
    ) -> {
      process.send(
        reply_to,
        do_renew_connector_read(
          state.conn,
          attempt_id,
          worker_id,
          expected_attempt_version,
          lease_ms,
        ),
      )
      actor.continue(state)
    }

    GetConnectorCheckpoint(reply_to:, configuration_ref:, activation_id:) -> {
      process.send(
        reply_to,
        do_get_connector_checkpoint(
          state.conn,
          configuration_ref,
          activation_id,
        ),
      )
      actor.continue(state)
    }

    RecordConnectorReadFailure(
      reply_to:,
      context:,
      next_due_at_ms:,
      error_code:,
      effect_unknown:,
    ) -> {
      process.send(
        reply_to,
        do_record_connector_read_failure(
          state.conn,
          context,
          next_due_at_ms,
          error_code,
          effect_unknown,
        ),
      )
      actor.continue(state)
    }

    FinishConnectorRead(reply_to:, attempt_id:, worker_id:, phase:, error_code:) -> {
      process.send(
        reply_to,
        do_finish_connector_read(
          state.conn,
          attempt_id,
          worker_id,
          phase,
          error_code,
        ),
      )
      actor.continue(state)
    }

    RecoverExpiredConnectorReads(reply_to:) -> {
      process.send(reply_to, do_recover_expired_connector_reads(state.conn))
      actor.continue(state)
    }

    RegisterGoogleOAuthClientSet(reply_to:, client_set:) -> {
      process.send(
        reply_to,
        do_register_google_oauth_client_set(state.conn, client_set),
      )
      actor.continue(state)
    }

    CreateGoogleOAuthSession(reply_to:, session:) -> {
      process.send(
        reply_to,
        do_create_google_oauth_session(state.conn, session),
      )
      actor.continue(state)
    }

    ClaimGoogleOAuthSession(reply_to:, session_ref:, accept_before_ms:) -> {
      process.send(
        reply_to,
        do_claim_google_oauth_session(state.conn, session_ref, accept_before_ms),
      )
      actor.continue(state)
    }

    FinishGoogleOAuthSession(reply_to:, session_ref:, phase:, error_class:) -> {
      process.send(
        reply_to,
        do_finish_google_oauth_session(
          state.conn,
          session_ref,
          phase,
          error_class,
        ),
      )
      actor.continue(state)
    }

    RecoverGoogleOAuthSession(reply_to:, session_ref:) -> {
      process.send(
        reply_to,
        do_recover_google_oauth_session(state.conn, session_ref),
      )
      actor.continue(state)
    }

    ExpireGoogleOAuthSessions(reply_to:) -> {
      process.send(reply_to, do_expire_google_oauth_sessions(state.conn))
      actor.continue(state)
    }

    BeginGoogleExternalEffect(reply_to:, effect:) -> {
      process.send(
        reply_to,
        do_begin_google_external_effect(state.conn, effect),
      )
      actor.continue(state)
    }

    GetGoogleExternalEffect(reply_to:, effect_id:) -> {
      process.send(reply_to, load_google_external_effect(state.conn, effect_id))
      actor.continue(state)
    }
    GetGoogleExternalEffectByProof(reply_to:, proof_ref:) -> {
      process.send(reply_to, load_google_effect_by_proof(state.conn, proof_ref))
      actor.continue(state)
    }
    GetLatestGoogleExternalEffect(reply_to:, logical_effect_key:) -> {
      process.send(
        reply_to,
        load_latest_google_external_effect(state.conn, logical_effect_key),
      )
      actor.continue(state)
    }

    NextGoogleExternalEffectAttempt(
      reply_to:,
      logical_effect_key:,
      effect_kind:,
    ) -> {
      process.send(
        reply_to,
        do_next_google_external_effect_attempt(
          state.conn,
          logical_effect_key,
          effect_kind,
        ),
      )
      actor.continue(state)
    }

    FinishGoogleExternalEffect(
      reply_to:,
      effect_id:,
      phase:,
      proof_ref:,
      account_fingerprint:,
      result_hash:,
      error_class:,
    ) -> {
      process.send(
        reply_to,
        do_finish_google_external_effect(
          state.conn,
          effect_id,
          phase,
          proof_ref,
          account_fingerprint,
          result_hash,
          error_class,
        ),
      )
      actor.continue(state)
    }

    TransitionConnectorActivationSet(
      reply_to:,
      authorization_id:,
      idempotency_key:,
      actor_ref:,
      authority_grants:,
      operation:,
    ) -> {
      process.send(
        reply_to,
        do_transition_connector_activation_set(
          state.conn,
          authorization_id,
          idempotency_key,
          actor_ref,
          authority_grants,
          operation,
        ),
      )
      actor.continue(state)
    }

    EnqueueAttention(reply_to:, request:) -> {
      process.send(reply_to, do_enqueue_attention(state.conn, request, None))
      actor.continue(state)
    }

    EnqueueAuthorizedAttention(reply_to:, request:, authorization_id:) -> {
      process.send(
        reply_to,
        do_enqueue_attention(state.conn, request, Some(authorization_id)),
      )
      actor.continue(state)
    }

    GetAttention(reply_to:, queue_id:) -> {
      process.send(reply_to, do_get_attention(state.conn, queue_id))
      actor.continue(state)
    }

    ListAttention(reply_to:, delivery_owner:, state: queue_state) -> {
      process.send(
        reply_to,
        do_list_attention(state.conn, delivery_owner, queue_state),
      )
      actor.continue(state)
    }

    ClaimAttention(reply_to:, delivery_owner:, worker_id:, lease_ms:, now:) -> {
      process.send(
        reply_to,
        do_claim_attention(
          state.conn,
          delivery_owner,
          worker_id,
          lease_ms,
          now,
          None,
        ),
      )
      actor.continue(state)
    }

    ClaimAuthorizedAttention(reply_to:, worker_id:, lease_ms:, now:, route:) -> {
      process.send(
        reply_to,
        do_claim_attention(
          state.conn,
          "codex",
          worker_id,
          lease_ms,
          now,
          Some(route),
        ),
      )
      actor.continue(state)
    }

    BeginAttentionDelivery(reply_to:, lease_token:, now:) -> {
      process.send(
        reply_to,
        do_begin_attention_delivery(state.conn, lease_token, now),
      )
      actor.continue(state)
    }
    BeginAuthorizedAttentionDelivery(reply_to:, lease_token:) -> {
      process.send(
        reply_to,
        do_begin_authorized_attention_delivery(state.conn, lease_token),
      )
      actor.continue(state)
    }

    RenewAttentionLease(reply_to:, lease_token:, lease_ms:, now:) -> {
      process.send(
        reply_to,
        do_renew_attention_lease(state.conn, lease_token, lease_ms, now),
      )
      actor.continue(state)
    }

    RescheduleAttention(reply_to:, lease_token:, error:, available_at:, now:) -> {
      process.send(
        reply_to,
        do_reschedule_attention(
          state.conn,
          lease_token,
          error,
          available_at,
          now,
        ),
      )
      actor.continue(state)
    }

    ExpireAttention(reply_to:, delivery_owner:, now:) -> {
      process.send(
        reply_to,
        do_expire_attention(state.conn, delivery_owner, now),
      )
      actor.continue(state)
    }

    RecoverAttention(reply_to:, delivery_owner:, now:) -> {
      process.send(
        reply_to,
        do_recover_attention(state.conn, delivery_owner, now),
      )
      actor.continue(state)
    }

    ApplyMonitorOutcome(reply_to:, outcome:) -> {
      process.send(
        reply_to,
        do_apply_monitor_outcome(state.conn, outcome, None),
      )
      actor.continue(state)
    }

    ApplyAuthorizedMonitorOutcome(reply_to:, outcome:, route:) -> {
      process.send(
        reply_to,
        do_apply_monitor_outcome(state.conn, outcome, Some(route)),
      )
      actor.continue(state)
    }

    CompleteAttentionDelivery(
      reply_to:,
      lease_token:,
      channel_id:,
      visible_content:,
      receipts:,
      now:,
    ) -> {
      process.send(
        reply_to,
        do_finish_attention_delivery(
          state.conn,
          lease_token,
          channel_id,
          visible_content,
          receipts,
          "succeeded",
          "",
          now,
        ),
      )
      actor.continue(state)
    }

    MarkAttentionEffectUnknown(
      reply_to:,
      lease_token:,
      channel_id:,
      visible_content:,
      receipts:,
      error:,
      now:,
    ) -> {
      process.send(
        reply_to,
        do_finish_attention_delivery(
          state.conn,
          lease_token,
          channel_id,
          visible_content,
          receipts,
          "effect_unknown",
          error,
          now,
        ),
      )
      actor.continue(state)
    }

    AcknowledgeAttention(reply_to:, queue_id:, actor_id:, now:) -> {
      process.send(
        reply_to,
        do_acknowledge_attention(state.conn, queue_id, actor_id, now),
      )
      actor.continue(state)
    }

    ListAttentionAttempts(reply_to:, queue_id:) -> {
      process.send(reply_to, do_list_attention_attempts(state.conn, queue_id))
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

fn do_append_delivery_message_with_audit(
  conn: sqlight.Connection,
  platform_id: String,
  event_id: String,
  content: String,
  timestamp: Int,
) -> Result(Nil, String) {
  in_transaction(conn, "delivery history transaction", fn() {
    use conversation_id <- result.try(do_resolve_conversation(
      conn,
      "discord",
      platform_id,
      timestamp,
    ))
    use _ <- result.try(do_append_message(
      conn,
      conversation_id,
      "assistant",
      content,
      "aura",
      "Aura",
      timestamp,
    ))
    use _ <- result.try(do_update_last_active(conn, conversation_id, timestamp))
    use _ <- result.try(do_append_operational_audit(
      conn,
      operational_audit.Record(
        schema_version: 1,
        audit_id: "",
        record_type: "external_effect_outcome",
        actor: "aura",
        source: "cognitive_delivery",
        action: "delivery.history_persisted",
        target_type: "delivery",
        target_id: event_id,
        before_version: None,
        after_version: None,
        idempotency_key: None,
        evidence_refs: [event_id],
        proof_refs: [],
        authority_ref: None,
        result: "succeeded",
        error_code: None,
        occurred_at: timestamp,
      ),
    ))
    Ok(Nil)
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
    "INSERT OR REPLACE INTO flares (id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms, dispatch_id, executor_kind, capability_manifest, context_manifest, authority_boundary, final_result, final_proof, archived) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
      sqlight.text(stored.dispatch_id),
      sqlight.text(stored.executor_kind),
      sqlight.text(stored.capability_manifest),
      sqlight.text(stored.context_manifest),
      sqlight.text(stored.authority_boundary),
      sqlight.text(stored.final_result),
      sqlight.text(stored.final_proof),
      sqlight.bool(stored.archived),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to upsert flare: " <> string.inspect(err)
  })
}

fn do_upsert_flare_with_event(
  conn: sqlight.Connection,
  stored: StoredFlare,
  event: StoredFlareEvent,
) -> Result(Nil, String) {
  in_transaction(conn, "flare transaction", fn() {
    use _ <- result.try(do_upsert_flare(conn, stored))
    use audit_id <- result.try(do_append_operational_audit(
      conn,
      operational_audit.Record(
        schema_version: 1,
        audit_id: "",
        record_type: "state_transition",
        actor: "aura",
        source: "flare_manager",
        action: "flare." <> event.event_type,
        target_type: "flare",
        target_id: stored.id,
        before_version: None,
        after_version: None,
        idempotency_key: None,
        evidence_refs: [],
        proof_refs: [],
        authority_ref: None,
        result: "succeeded",
        error_code: None,
        occurred_at: event.created_at_ms,
      ),
    ))
    do_append_flare_event_with_audit_id(conn, event, Some(audit_id))
  })
}

fn do_load_flares(
  conn: sqlight.Connection,
  exclude_archived: Bool,
) -> Result(List(StoredFlare), String) {
  let sql = case exclude_archived {
    True ->
      "SELECT id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms, dispatch_id, executor_kind, capability_manifest, context_manifest, authority_boundary, final_result, final_proof, archived FROM flares WHERE archived = 0 AND status != 'archived' ORDER BY created_at_ms ASC"
    False ->
      "SELECT id, label, status, domain, thread_id, original_prompt, execution, triggers, tools, workspace, session_id, created_at_ms, updated_at_ms, dispatch_id, executor_kind, capability_manifest, context_manifest, authority_boundary, final_result, final_proof, archived FROM flares ORDER BY created_at_ms ASC"
  }
  sqlight.query(sql, on: conn, with: [], expecting: flare_decoder())
  |> result.map_error(fn(err) {
    "Failed to load flares: " <> string.inspect(err)
  })
}

fn do_append_flare_event(
  conn: sqlight.Connection,
  event: StoredFlareEvent,
) -> Result(Nil, String) {
  do_append_flare_event_with_audit_id(conn, event, None)
}

fn do_append_flare_event_with_audit_id(
  conn: sqlight.Connection,
  event: StoredFlareEvent,
  audit_id: Option(String),
) -> Result(Nil, String) {
  use sequence <- result.try(do_next_flare_event_sequence(conn, event.flare_id))
  sqlight.query(
    "INSERT INTO flare_events (flare_id, attempt_id, sequence, event_type, payload, created_at_ms, audit_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(event.flare_id),
      sqlight.int(event.attempt_id),
      sqlight.int(sequence),
      sqlight.text(event.event_type),
      sqlight.text(event.payload),
      sqlight.int(event.created_at_ms),
      sqlight.nullable(sqlight.text, audit_id),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to append flare event: " <> string.inspect(err)
  })
}

fn do_next_flare_event_sequence(
  conn: sqlight.Connection,
  flare_id: String,
) -> Result(Int, String) {
  sqlight.query(
    "SELECT COALESCE(MAX(sequence), 0) FROM flare_events WHERE flare_id = ?",
    on: conn,
    with: [sqlight.text(flare_id)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(err) {
    "Failed to compute flare event sequence: " <> string.inspect(err)
  })
  |> result.try(fn(rows) {
    case rows {
      [max] -> Ok(max + 1)
      _ -> Error("Expected one sequence row, got " <> string.inspect(rows))
    }
  })
}

fn do_list_flare_events(
  conn: sqlight.Connection,
  flare_id: String,
) -> Result(List(StoredFlareEvent), String) {
  sqlight.query(
    "SELECT id, flare_id, attempt_id, sequence, event_type, payload, created_at_ms FROM flare_events WHERE flare_id = ? ORDER BY sequence ASC, id ASC",
    on: conn,
    with: [sqlight.text(flare_id)],
    expecting: flare_event_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to load flare events: " <> string.inspect(err)
  })
}

fn do_create_flare_attempt(
  conn: sqlight.Connection,
  attempt: StoredFlareAttempt,
) -> Result(Int, String) {
  sqlight.query(
    "INSERT INTO flare_attempts (flare_id, executor_kind, status, runtime_reference, checkpoint, started_at_ms, ended_at_ms, failure) VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
    on: conn,
    with: [
      sqlight.text(attempt.flare_id),
      sqlight.text(attempt.executor_kind),
      sqlight.text(attempt.status),
      sqlight.text(attempt.runtime_reference),
      sqlight.text(attempt.checkpoint),
      sqlight.int(attempt.started_at_ms),
      sqlight.int(attempt.ended_at_ms),
      sqlight.text(attempt.failure),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(err) {
    "Failed to create flare attempt: " <> string.inspect(err)
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

fn do_create_flare_attempt_with_event(
  conn: sqlight.Connection,
  attempt: StoredFlareAttempt,
  event: StoredFlareEvent,
) -> Result(Int, String) {
  in_transaction(conn, "flare attempt transaction", fn() {
    use attempt_id <- result.try(do_create_flare_attempt(conn, attempt))
    use audit_id <- result.try(do_append_operational_audit(
      conn,
      operational_audit.Record(
        schema_version: 1,
        audit_id: "",
        record_type: "state_transition",
        actor: "aura",
        source: "flare_manager",
        action: "flare." <> event.event_type,
        target_type: "flare",
        target_id: attempt.flare_id,
        before_version: None,
        after_version: None,
        idempotency_key: None,
        evidence_refs: [],
        proof_refs: [],
        authority_ref: None,
        result: "succeeded",
        error_code: None,
        occurred_at: event.created_at_ms,
      ),
    ))
    use _ <- result.try(do_append_flare_event_with_audit_id(
      conn,
      StoredFlareEvent(..event, attempt_id: attempt_id),
      Some(audit_id),
    ))
    Ok(attempt_id)
  })
}

fn do_update_flare_attempt(
  conn: sqlight.Connection,
  attempt: StoredFlareAttempt,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE flare_attempts SET executor_kind = ?, status = ?, runtime_reference = ?, checkpoint = ?, started_at_ms = ?, ended_at_ms = ?, failure = ? WHERE id = ?",
    on: conn,
    with: [
      sqlight.text(attempt.executor_kind),
      sqlight.text(attempt.status),
      sqlight.text(attempt.runtime_reference),
      sqlight.text(attempt.checkpoint),
      sqlight.int(attempt.started_at_ms),
      sqlight.int(attempt.ended_at_ms),
      sqlight.text(attempt.failure),
      sqlight.int(attempt.id),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(err) {
    "Failed to update flare attempt: " <> string.inspect(err)
  })
}

fn do_list_flare_attempts(
  conn: sqlight.Connection,
  flare_id: String,
) -> Result(List(StoredFlareAttempt), String) {
  sqlight.query(
    "SELECT id, flare_id, executor_kind, status, runtime_reference, checkpoint, started_at_ms, ended_at_ms, failure FROM flare_attempts WHERE flare_id = ? ORDER BY id ASC",
    on: conn,
    with: [sqlight.text(flare_id)],
    expecting: flare_attempt_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to load flare attempts: " <> string.inspect(err)
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
  in_transaction(conn, "flare result transaction", fn() {
    use _ <- result.try(do_update_flare_result_row(
      conn,
      id,
      result_text,
      updated_at_ms,
    ))
    use _ <- result.try(do_append_operational_audit(
      conn,
      operational_audit.Record(
        schema_version: 1,
        audit_id: "",
        record_type: "state_transition",
        actor: "aura",
        source: "brain",
        action: "flare.result_updated",
        target_type: "flare",
        target_id: id,
        before_version: None,
        after_version: None,
        idempotency_key: None,
        evidence_refs: [],
        proof_refs: [],
        authority_ref: None,
        result: "succeeded",
        error_code: None,
        occurred_at: updated_at_ms,
      ),
    ))
    Ok(Nil)
  })
}

fn do_update_flare_result_row(
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

fn do_get_flare_result(
  conn: sqlight.Connection,
  id: String,
) -> Result(String, String) {
  let result =
    sqlight.query(
      "SELECT COALESCE(result_text, '') FROM flares WHERE id = ?",
      on: conn,
      with: [sqlight.text(id)],
      expecting: decode.at([0], decode.string),
    )
  case result {
    Ok([result_text]) -> Ok(result_text)
    Ok([]) -> Ok("")
    Ok(_) -> Ok("")
    Error(err) -> Error("Failed to get flare result: " <> string.inspect(err))
  }
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
  in_transaction(conn, "event audit transaction", fn() {
    use inserted <- result.try(do_insert_event_row(conn, e))
    case inserted {
      False -> Ok(False)
      True -> {
        use _ <- result.try(do_append_operational_audit(
          conn,
          operational_audit.Record(
            schema_version: 1,
            audit_id: "",
            record_type: "state_transition",
            actor: "aura",
            source: "event_ingest",
            action: "event.inserted",
            target_type: "event",
            target_id: e.id,
            before_version: None,
            after_version: Some(1),
            idempotency_key: None,
            evidence_refs: [e.id],
            proof_refs: [],
            authority_ref: None,
            result: "succeeded",
            error_code: None,
            occurred_at: e.time_ms,
          ),
        ))
        Ok(True)
      }
    }
  })
}

fn do_insert_normalized_evidence(
  conn: sqlight.Connection,
  envelope: operating_contracts.EvidenceEvent,
  concern_links: List(evidence.ConcernLink),
) -> Result(EvidenceInsert, String) {
  in_transaction(conn, "normalized evidence transaction", fn() {
    do_insert_normalized_evidence_in_transaction(conn, envelope, concern_links)
  })
}

fn do_insert_normalized_evidence_in_transaction(
  conn: sqlight.Connection,
  envelope: operating_contracts.EvidenceEvent,
  concern_links: List(evidence.ConcernLink),
) -> Result(EvidenceInsert, String) {
  use legacy_event <- result.try(evidence.to_legacy_event(envelope))
  use raw_ref <- result.try(case envelope.raw_ref {
    Some(value) -> Ok(value)
    None -> Error("evidence_raw_ref_required")
  })
  let resource_kind =
    result.unwrap(
      dict_structured_string(envelope.resource, "kind"),
      "external_resource",
    )
  let resource_id =
    result.unwrap(
      dict_structured_string(envelope.resource, "id"),
      legacy_event.external_id,
    )
  use inserted <- result.try(do_insert_event_row(conn, legacy_event))
  case inserted {
    False -> {
      use canonical_id <- result.try(do_get_canonical_event_id(
        conn,
        legacy_event.source,
        legacy_event.external_id,
      ))
      use stored_hash <- result.try(do_get_evidence_content_hash(
        conn,
        canonical_id,
      ))
      use _ <- result.try(case stored_hash {
        Some(hash) if hash != envelope.content_hash ->
          Error("idempotency_conflict")
        _ -> Ok(Nil)
      })
      let canonical_envelope =
        operating_contracts.EvidenceEvent(..envelope, event_id: canonical_id)
      use _ <- result.try(do_store_evidence_if_absent(
        conn,
        canonical_envelope,
        concern_links,
        raw_ref,
        resource_kind,
        resource_id,
      ))
      Ok(EvidenceInsert(event_id: canonical_id, inserted: False))
    }
    True -> {
      use _ <- result.try(do_store_evidence_if_absent(
        conn,
        envelope,
        concern_links,
        raw_ref,
        resource_kind,
        resource_id,
      ))
      Ok(EvidenceInsert(event_id: envelope.event_id, inserted: True))
    }
  }
}

fn do_submit_authorized_connector_evidence(
  conn: sqlight.Connection,
  context: operating_contracts.ConnectorSubmissionContext,
  envelope: operating_contracts.EvidenceEvent,
  concern_links: List(evidence.ConcernLink),
) -> Result(Option(EvidenceInsert), String) {
  do_submit_authorized_connector_evidence_batch(conn, context, [
    #(envelope, concern_links),
  ])
  |> result.map(fn(value) {
    case value {
      Some([inserted]) -> Some(inserted)
      Some(_) -> None
      None -> None
    }
  })
}

fn do_submit_authorized_connector_evidence_batch(
  conn: sqlight.Connection,
  context: operating_contracts.ConnectorSubmissionContext,
  evidence_items: List(
    #(operating_contracts.EvidenceEvent, List(evidence.ConcernLink)),
  ),
) -> Result(Option(List(EvidenceInsert)), String) {
  do_submit_authorized_connector_evidence_batch_with_checkpoint(
    conn,
    context,
    evidence_items,
    NoConnectorCheckpoint,
  )
}

fn do_submit_authorized_connector_evidence_batch_with_checkpoint(
  conn: sqlight.Connection,
  context: operating_contracts.ConnectorSubmissionContext,
  evidence_items: List(
    #(operating_contracts.EvidenceEvent, List(evidence.ConcernLink)),
  ),
  checkpoint: ConnectorCheckpointUpdate,
) -> Result(Option(List(EvidenceInsert)), String) {
  case
    do_submit_authorized_connector_evidence_batch_once(
      conn,
      context,
      evidence_items,
      checkpoint,
    )
  {
    Error("idempotency_conflict") ->
      case
        do_finish_connector_read(
          conn,
          context.attempt_id,
          context.worker_id,
          "failed",
          "idempotency_conflict",
        )
      {
        Ok(_) -> Error("idempotency_conflict")
        Error(error) ->
          Error("failed_to_record_idempotency_conflict: " <> error)
      }
    other -> other
  }
}

fn do_submit_authorized_connector_evidence_batch_once(
  conn: sqlight.Connection,
  context: operating_contracts.ConnectorSubmissionContext,
  evidence_items: List(
    #(operating_contracts.EvidenceEvent, List(evidence.ConcernLink)),
  ),
  checkpoint: ConnectorCheckpointUpdate,
) -> Result(Option(List(EvidenceInsert)), String) {
  let now_ms = time.now_ms()
  in_transaction(conn, "authorized connector evidence", fn() {
    use rows <- result.try(
      sqlight.query(
        "SELECT a.activation_id, a.activation_version, ca.authorization_id, ca.connector_id, ca.domain_id, ca.concern_id, ca.oauth_scope, au.canonical_json FROM connector_read_attempts a JOIN connector_activations ca ON ca.activation_id = a.activation_id JOIN canary_authorizations au ON au.authorization_id = ca.authorization_id WHERE a.attempt_id = ? AND a.worker_id = ? AND a.phase = 'request_started' AND a.lease_expires_at_ms > ? AND a.hard_expires_at_ms > ? AND ca.state = 'enabled' AND au.starts_at_ms <= ? AND au.ends_at_ms > ?",
        on: conn,
        with: [
          sqlight.text(context.attempt_id),
          sqlight.text(context.worker_id),
          sqlight.int(now_ms),
          sqlight.int(now_ms),
          sqlight.int(now_ms),
          sqlight.int(now_ms),
        ],
        expecting: {
          use activation_id <- decode.field(0, decode.string)
          use version <- decode.field(1, decode.int)
          use authorization_id <- decode.field(2, decode.string)
          use connector_id <- decode.field(3, decode.string)
          use domain_id <- decode.field(4, decode.string)
          use concern_id <- decode.field(5, decode.string)
          use oauth_scope <- decode.field(6, decode.string)
          use authorization_json <- decode.field(7, decode.string)
          decode.success(#(
            activation_id,
            version,
            authorization_id,
            connector_id,
            domain_id,
            concern_id,
            oauth_scope,
            authorization_json,
          ))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to validate connector evidence: " <> string.inspect(error)
      }),
    )
    case rows {
      [
        #(
          activation_id,
          version,
          authorization_id,
          connector_id,
          domain_id,
          concern_id,
          oauth_scope,
          authorization_json,
        ),
      ] -> {
        use _ <- result.try(validate_connector_submission_binding(
          context,
          activation_id,
          version,
          authorization_id,
          connector_id,
          domain_id,
          concern_id,
          oauth_scope,
          authorization_json,
        ))
        use inserted <- result.try(
          list.try_map(evidence_items, fn(item) {
            use _ <- result.try(case item.1 {
              [] -> Ok(Nil)
              _ -> Error("connector_concern_inference_not_allowed")
            })
            use _ <- result.try(validate_connector_evidence_binding(
              context,
              item.0,
              connector_id,
            ))
            let server_bound_envelope =
              operating_contracts.EvidenceEvent(
                ..item.0,
                provenance: item.0.provenance
                  |> dict.insert(
                    "activation_id",
                    operating_contracts.StructuredString(activation_id),
                  )
                  |> dict.insert(
                    "authorization_id",
                    operating_contracts.StructuredString(authorization_id),
                  ),
              )
            do_insert_normalized_evidence_in_transaction(
              conn,
              server_bound_envelope,
              [
                evidence.ConcernLink(
                  concern_id:,
                  confidence: 1.0,
                  provenance: "authorization:" <> authorization_id,
                  confirmed: True,
                ),
              ],
            )
          }),
        )
        use _ <- result.try(
          inserted
          |> list.filter(fn(value) { !value.inserted })
          |> list.try_each(fn(value) {
            do_append_operational_audit(
              conn,
              operational_audit.Record(
                schema_version: 1,
                audit_id: "",
                record_type: "verification",
                actor: "aura",
                source: "connector_runtime",
                action: "evidence.replayed",
                target_type: "event",
                target_id: value.event_id,
                before_version: Some(1),
                after_version: Some(1),
                idempotency_key: Some(context.attempt_id),
                evidence_refs: [value.event_id],
                proof_refs: [activation_id],
                authority_ref: Some(authorization_id),
                result: "deduped",
                error_code: None,
                occurred_at: now_ms,
              ),
            )
          }),
        )
        use _ <- result.try(apply_connector_checkpoint(
          conn,
          context,
          checkpoint,
          authorization_json,
          now_ms,
        ))
        use completed_versions <- result.try(
          sqlight.query(
            "UPDATE connector_read_attempts SET phase = 'completed', attempt_version = attempt_version + 1, finished_at_ms = ? WHERE attempt_id = ? AND worker_id = ? AND phase = 'request_started' AND lease_expires_at_ms > ? AND hard_expires_at_ms > ? RETURNING attempt_version",
            on: conn,
            with: [
              sqlight.int(now_ms),
              sqlight.text(context.attempt_id),
              sqlight.text(context.worker_id),
              sqlight.int(now_ms),
              sqlight.int(now_ms),
            ],
            expecting: decode.at([0], decode.int),
          )
          |> result.map_error(fn(error) { string.inspect(error) }),
        )
        use attempt_version <- result.try(case completed_versions {
          [value] -> Ok(value)
          _ -> Error("connector_read_not_active")
        })
        let attempt =
          ConnectorReadAttempt(
            attempt_id: context.attempt_id,
            activation_id:,
            activation_version: version,
            attempt_version:,
            worker_id: context.worker_id,
            phase: "completed",
          )
        use _ <- result.try(append_connector_read_audit(
          conn,
          attempt,
          "connector.evidence.completed",
          "",
          now_ms,
        ))
        Ok(Some(inserted))
      }
      _ -> {
        use discarded <- result.try(
          sqlight.query(
            "UPDATE connector_read_attempts SET phase = 'discarded', attempt_version = attempt_version + 1, finished_at_ms = ?, error_code = 'activation_not_effective' WHERE attempt_id = ? AND worker_id = ? AND phase IN ('reserved', 'request_started') RETURNING activation_id, activation_version, attempt_version",
            on: conn,
            with: [
              sqlight.int(now_ms),
              sqlight.text(context.attempt_id),
              sqlight.text(context.worker_id),
            ],
            expecting: {
              use activation_id <- decode.field(0, decode.string)
              use version <- decode.field(1, decode.int)
              use attempt_version <- decode.field(2, decode.int)
              decode.success(#(activation_id, version, attempt_version))
            },
          )
          |> result.map_error(fn(error) { string.inspect(error) })
          |> result.map(fn(rows) {
            case rows {
              [#(activation_id, version, attempt_version)] ->
                ConnectorReadAttempt(
                  attempt_id: context.attempt_id,
                  activation_id:,
                  activation_version: version,
                  attempt_version:,
                  worker_id: context.worker_id,
                  phase: "discarded",
                )
              _ ->
                ConnectorReadAttempt(
                  attempt_id: context.attempt_id,
                  activation_id: "",
                  activation_version: 0,
                  attempt_version: 0,
                  worker_id: context.worker_id,
                  phase: "discarded",
                )
            }
          }),
        )
        use _ <- result.try(case discarded.activation_id {
          "" -> Ok(Nil)
          _ ->
            append_connector_read_audit(
              conn,
              discarded,
              "connector.evidence.discarded",
              "activation_not_effective",
              now_ms,
            )
        })
        Ok(None)
      }
    }
  })
}

fn validate_connector_submission_binding(
  context: operating_contracts.ConnectorSubmissionContext,
  activation_id: String,
  activation_version: Int,
  authorization_id: String,
  connector_id: String,
  domain_id: String,
  concern_id: String,
  oauth_scope: String,
  authorization_json: String,
) -> Result(Nil, String) {
  use authorization <- result.try(
    operating_contracts.decode_canary_authorization(authorization_json)
    |> result.map_error(fn(_) { "invalid_connector_submission_authorization" }),
  )
  use connector <- result.try(
    list.find(authorization.connectors, fn(value) {
      value.activation_id == activation_id
    })
    |> result.map_error(fn(_) { "connector_submission_context_mismatch" }),
  )
  case
    context.activation_id == activation_id
    && context.activation_version == activation_version
    && context.authorization_id == authorization_id
    && context.connector_id == connector_id
    && context.domain_id == domain_id
    && context.concern_id == concern_id
    && context.oauth_scope == oauth_scope
    && context.configuration_hash == connector.configuration_hash
    && context.account_fingerprint == connector.account_fingerprint
  {
    True -> Ok(Nil)
    False -> Error("connector_submission_context_mismatch")
  }
}

fn apply_connector_checkpoint(
  conn: sqlight.Connection,
  context: operating_contracts.ConnectorSubmissionContext,
  checkpoint: ConnectorCheckpointUpdate,
  authorization_json: String,
  now_ms: Int,
) -> Result(Nil, String) {
  case checkpoint {
    NoConnectorCheckpoint -> Ok(Nil)
    _ -> {
      use authorization <- result.try(
        operating_contracts.decode_canary_authorization(authorization_json)
        |> result.map_error(fn(_) { "invalid_checkpoint_authorization" }),
      )
      use connector <- result.try(
        list.find(authorization.connectors, fn(value) {
          value.activation_id == context.activation_id
        })
        |> result.map_error(fn(_) { "checkpoint_binding_mismatch" }),
      )
      let #(configuration_ref, activation_id, expected_version) =
        checkpoint_identity(checkpoint)
      use _ <- result.try(
        case
          configuration_ref == connector.configuration_ref
          && activation_id == context.activation_id
          && connector.connector_id == context.connector_id
          && connector.configuration_hash == context.configuration_hash
          && connector.account_fingerprint == context.account_fingerprint
        {
          True -> Ok(Nil)
          False -> Error("checkpoint_binding_mismatch")
        },
      )
      let #(cursor_kind, cursor_value, next_due_at_ms, gap_code) = case
        checkpoint
      {
        GmailHistoryCheckpoint(history_id:, ..)
        | GmailHistoryCheckpointWithMissing(history_id:, ..) -> #(
          "gmail_history",
          history_id,
          now_ms + connector.poll_interval_ms,
          "",
        )
        // Calendar cadence belongs to the immutable authorization. Do not let
        // a worker move the next poll earlier or later with caller time.
        CalendarPollCheckpoint(next_due_at_ms: _, ..) -> #(
          "calendar_poll",
          "",
          now_ms + connector.poll_interval_ms,
          "",
        )
        GmailHistoryGap(reason_code:, prior_history_hash: _, ..) -> #(
          "gmail_history",
          "",
          now_ms,
          reason_code,
        )
        NoConnectorCheckpoint -> #("", "", now_ms, "")
      }
      use versions <- result.try(case expected_version {
        0 ->
          sqlight.query(
            "INSERT INTO connector_checkpoints (configuration_ref, connector_id, preparation_authorization_id, authorization_id, activation_id, configuration_hash, account_fingerprint, cursor_kind, cursor_value, last_success_at_ms, next_due_at_ms, retry_count, gap_code, version, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 1, ?) ON CONFLICT(configuration_ref, activation_id) DO NOTHING RETURNING version",
            on: conn,
            with: [
              sqlight.text(configuration_ref),
              sqlight.text(context.connector_id),
              sqlight.text(authorization.preparation_authorization_id),
              sqlight.text(context.authorization_id),
              sqlight.text(activation_id),
              sqlight.text(context.configuration_hash),
              sqlight.text(context.account_fingerprint),
              sqlight.text(cursor_kind),
              nullable_nonempty_text(cursor_value),
              case gap_code {
                "" -> sqlight.nullable(sqlight.int, Some(now_ms))
                _ -> sqlight.nullable(sqlight.int, None)
              },
              sqlight.int(next_due_at_ms),
              nullable_nonempty_text(gap_code),
              sqlight.int(now_ms),
            ],
            expecting: decode.at([0], decode.int),
          )
          |> result.map_error(fn(error) {
            "Failed to create connector checkpoint: " <> string.inspect(error)
          })
        _ ->
          sqlight.query(
            "UPDATE connector_checkpoints SET cursor_value = COALESCE(?, cursor_value), last_success_at_ms = CASE WHEN ? = '' THEN ? ELSE last_success_at_ms END, next_due_at_ms = ?, retry_count = 0, gap_code = ?, version = version + 1, updated_at_ms = ? WHERE configuration_ref = ? AND activation_id = ? AND authorization_id = ? AND cursor_kind = ? AND version = ? RETURNING version",
            on: conn,
            with: [
              nullable_nonempty_text(cursor_value),
              sqlight.text(gap_code),
              sqlight.int(now_ms),
              sqlight.int(next_due_at_ms),
              nullable_nonempty_text(gap_code),
              sqlight.int(now_ms),
              sqlight.text(configuration_ref),
              sqlight.text(activation_id),
              sqlight.text(context.authorization_id),
              sqlight.text(cursor_kind),
              sqlight.int(expected_version),
            ],
            expecting: decode.at([0], decode.int),
          )
          |> result.map_error(fn(error) {
            "Failed to update connector checkpoint: " <> string.inspect(error)
          })
      })
      use version <- result.try(case versions {
        [value] -> Ok(value)
        _ -> Error("connector_checkpoint_version_conflict")
      })
      use _ <- result.try(do_append_operational_audit(
        conn,
        operational_audit.Record(
          schema_version: 1,
          audit_id: "connector-checkpoint:"
            <> configuration_ref
            <> ":"
            <> activation_id
            <> ":"
            <> string.inspect(version),
          record_type: "state_transition",
          actor: "aura",
          source: "connector_runtime",
          action: case gap_code {
            "" -> "connector.checkpoint.advanced"
            _ -> "connector.checkpoint.gap_recorded"
          },
          target_type: "connector_checkpoint",
          target_id: configuration_ref <> ":" <> activation_id,
          before_version: case expected_version {
            0 -> None
            value -> Some(value)
          },
          after_version: Some(version),
          idempotency_key: Some(context.attempt_id),
          evidence_refs: [],
          proof_refs: [context.activation_id],
          authority_ref: Some(context.authorization_id),
          result: "succeeded",
          error_code: None,
          occurred_at: now_ms,
        ),
      ))
      use _ <- result.try(case checkpoint {
        GmailHistoryCheckpointWithMissing(missing_count:, ..)
          if missing_count > 0
        ->
          do_append_operational_audit(
            conn,
            operational_audit.Record(
              schema_version: 1,
              audit_id: "gmail-missing-resource:"
                <> context.attempt_id
                <> ":"
                <> string.inspect(missing_count),
              record_type: "verification",
              actor: "aura",
              source: "connector_runtime",
              action: "connector.gmail.missing_resource_observed",
              target_type: "connector_checkpoint",
              target_id: configuration_ref <> ":" <> activation_id,
              before_version: Some(version),
              after_version: Some(version),
              idempotency_key: Some(context.attempt_id),
              evidence_refs: [],
              proof_refs: [context.activation_id],
              authority_ref: Some(context.authorization_id),
              result: "succeeded",
              error_code: None,
              occurred_at: now_ms,
            ),
          )
          |> result.map(fn(_) { Nil })
        _ -> Ok(Nil)
      })
      use _ <- result.try(case checkpoint {
        GmailHistoryGap(..) ->
          begin_connector_gap_disable(
            conn,
            context,
            expected_version: context.activation_version,
            now_ms:,
          )
        _ -> Ok(Nil)
      })
      Ok(Nil)
    }
  }
}

fn checkpoint_identity(
  checkpoint: ConnectorCheckpointUpdate,
) -> #(String, String, Int) {
  case checkpoint {
    NoConnectorCheckpoint -> #("", "", 0)
    GmailHistoryCheckpoint(
      configuration_ref:,
      activation_id:,
      expected_version:,
      ..,
    )
    | GmailHistoryCheckpointWithMissing(
        configuration_ref:,
        activation_id:,
        expected_version:,
        ..,
      )
    | CalendarPollCheckpoint(
        configuration_ref:,
        activation_id:,
        expected_version:,
        ..,
      )
    | GmailHistoryGap(configuration_ref:, activation_id:, expected_version:, ..) -> #(
      configuration_ref,
      activation_id,
      expected_version,
    )
  }
}

fn begin_connector_gap_disable(
  conn: sqlight.Connection,
  context: operating_contracts.ConnectorSubmissionContext,
  expected_version expected_version: Int,
  now_ms now_ms: Int,
) -> Result(Nil, String) {
  use versions <- result.try(
    sqlight.query(
      "UPDATE connector_activations SET state = 'disabling', version = version + 1, updated_at_ms = ? WHERE activation_id = ? AND authorization_id = ? AND state = 'enabled' AND version = ? RETURNING version",
      on: conn,
      with: [
        sqlight.int(now_ms),
        sqlight.text(context.activation_id),
        sqlight.text(context.authorization_id),
        sqlight.int(expected_version),
      ],
      expecting: decode.at([0], decode.int),
    )
    |> result.map_error(fn(error) {
      "Failed to start connector safe disable: " <> string.inspect(error)
    }),
  )
  use version <- result.try(case versions {
    [value] -> Ok(value)
    _ -> Error("connector_activation_version_conflict")
  })
  do_append_operational_audit(
    conn,
    operational_audit.Record(
      schema_version: 1,
      audit_id: "connector-gap-disable:" <> context.attempt_id,
      record_type: "state_transition",
      actor: "aura",
      source: "connector_runtime",
      action: "connector.activation.safe_disable_started",
      target_type: "connector_activation",
      target_id: context.activation_id,
      before_version: Some(expected_version),
      after_version: Some(version),
      idempotency_key: Some(context.attempt_id),
      evidence_refs: [],
      proof_refs: [context.activation_id],
      authority_ref: Some(context.authorization_id),
      result: "succeeded",
      error_code: None,
      occurred_at: now_ms,
    ),
  )
  |> result.map(fn(_) { Nil })
}

fn do_get_connector_checkpoint(
  conn: sqlight.Connection,
  configuration_ref: String,
  activation_id: String,
) -> Result(Option(ConnectorCheckpoint), String) {
  sqlight.query(
    "SELECT configuration_ref, connector_id, authorization_id, activation_id, cursor_kind, cursor_value, next_due_at_ms, retry_count, gap_code, version FROM connector_checkpoints WHERE configuration_ref = ? AND activation_id = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(configuration_ref), sqlight.text(activation_id)],
    expecting: {
      use configuration_ref <- decode.field(0, decode.string)
      use connector_id <- decode.field(1, decode.string)
      use authorization_id <- decode.field(2, decode.string)
      use activation_id <- decode.field(3, decode.string)
      use cursor_kind <- decode.field(4, decode.string)
      use cursor_value <- decode.field(5, nullable_string_decoder())
      use next_due_at_ms <- decode.field(6, decode.int)
      use retry_count <- decode.field(7, decode.int)
      use gap_code <- decode.field(8, nullable_string_decoder())
      use version <- decode.field(9, decode.int)
      decode.success(ConnectorCheckpoint(
        configuration_ref:,
        connector_id:,
        authorization_id:,
        activation_id:,
        cursor_kind:,
        cursor_value:,
        next_due_at_ms:,
        retry_count:,
        gap_code:,
        version:,
      ))
    },
  )
  |> result.map_error(fn(error) {
    "Failed to load connector checkpoint: " <> string.inspect(error)
  })
  |> result.map(fn(rows) {
    case rows {
      [value, ..] -> Some(value)
      [] -> None
    }
  })
}

fn do_record_connector_read_failure(
  conn: sqlight.Connection,
  context: operating_contracts.ConnectorSubmissionContext,
  next_due_at_ms: Int,
  error_code: String,
  effect_unknown: Bool,
) -> Result(ConnectorReadAttempt, String) {
  use _ <- result.try(validate_connector_read_error_code(error_code))
  let now_ms = time.now_ms()
  use _ <- result.try(case next_due_at_ms >= now_ms {
    True -> Ok(Nil)
    False -> Error("invalid_connector_retry_time")
  })
  in_transaction(conn, "connector read failure", fn() {
    use rows <- result.try(
      sqlight.query(
        "SELECT a.activation_id, a.activation_version, a.attempt_version, ca.authorization_id, ca.connector_id, ca.domain_id, ca.concern_id, ca.oauth_scope, au.canonical_json FROM connector_read_attempts a JOIN connector_activations ca ON ca.activation_id = a.activation_id JOIN canary_authorizations au ON au.authorization_id = ca.authorization_id WHERE a.attempt_id = ? AND a.worker_id = ? AND a.phase IN ('reserved', 'request_started') AND a.lease_expires_at_ms > ? AND a.hard_expires_at_ms > ?",
        on: conn,
        with: [
          sqlight.text(context.attempt_id),
          sqlight.text(context.worker_id),
          sqlight.int(now_ms),
          sqlight.int(now_ms),
        ],
        expecting: {
          use activation_id <- decode.field(0, decode.string)
          use activation_version <- decode.field(1, decode.int)
          use attempt_version <- decode.field(2, decode.int)
          use authorization_id <- decode.field(3, decode.string)
          use connector_id <- decode.field(4, decode.string)
          use domain_id <- decode.field(5, decode.string)
          use concern_id <- decode.field(6, decode.string)
          use oauth_scope <- decode.field(7, decode.string)
          use authorization_json <- decode.field(8, decode.string)
          decode.success(#(
            activation_id,
            activation_version,
            attempt_version,
            authorization_id,
            connector_id,
            domain_id,
            concern_id,
            oauth_scope,
            authorization_json,
          ))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to load connector read for failure: " <> string.inspect(error)
      }),
    )
    use row <- result.try(case rows {
      [value] -> Ok(value)
      _ -> Error("connector_read_not_active")
    })
    use _ <- result.try(validate_connector_submission_binding(
      context,
      row.0,
      row.1,
      row.3,
      row.4,
      row.5,
      row.6,
      row.7,
      row.8,
    ))
    use authorization <- result.try(
      operating_contracts.decode_canary_authorization(row.8)
      |> result.map_error(fn(_) { "invalid_checkpoint_authorization" }),
    )
    use connector <- result.try(
      list.find(authorization.connectors, fn(value) {
        value.activation_id == context.activation_id
      })
      |> result.map_error(fn(_) { "checkpoint_binding_mismatch" }),
    )
    let cursor_kind = case context.connector_id {
      "gmail" -> "gmail_history"
      "calendar" -> "calendar_poll"
      _ -> ""
    }
    use _ <- result.try(case cursor_kind {
      "" -> Error("unsupported_connector_checkpoint")
      _ -> Ok(Nil)
    })
    use checkpoint_versions <- result.try(
      sqlight.query(
        "INSERT INTO connector_checkpoints (configuration_ref, connector_id, preparation_authorization_id, authorization_id, activation_id, configuration_hash, account_fingerprint, cursor_kind, cursor_value, last_success_at_ms, next_due_at_ms, retry_count, gap_code, version, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, 1, NULL, 1, ?) ON CONFLICT(configuration_ref, activation_id) DO UPDATE SET next_due_at_ms = excluded.next_due_at_ms, retry_count = connector_checkpoints.retry_count + 1, version = connector_checkpoints.version + 1, updated_at_ms = excluded.updated_at_ms WHERE connector_checkpoints.authorization_id = excluded.authorization_id AND connector_checkpoints.configuration_hash = excluded.configuration_hash AND connector_checkpoints.account_fingerprint = excluded.account_fingerprint RETURNING version",
        on: conn,
        with: [
          sqlight.text(connector.configuration_ref),
          sqlight.text(context.connector_id),
          sqlight.text(authorization.preparation_authorization_id),
          sqlight.text(context.authorization_id),
          sqlight.text(context.activation_id),
          sqlight.text(context.configuration_hash),
          sqlight.text(context.account_fingerprint),
          sqlight.text(cursor_kind),
          sqlight.int(next_due_at_ms),
          sqlight.int(now_ms),
        ],
        expecting: decode.at([0], decode.int),
      )
      |> result.map_error(fn(error) {
        "Failed to store connector retry checkpoint: " <> string.inspect(error)
      }),
    )
    use checkpoint_version <- result.try(case checkpoint_versions {
      [value] -> Ok(value)
      _ -> Error("checkpoint_binding_mismatch")
    })
    use _ <- result.try(do_append_operational_audit(
      conn,
      operational_audit.Record(
        schema_version: 1,
        audit_id: "connector-checkpoint:"
          <> connector.configuration_ref
          <> ":"
          <> context.activation_id
          <> ":retry:"
          <> string.inspect(checkpoint_version),
        record_type: "state_transition",
        actor: "aura",
        source: "connector_runtime",
        action: "connector.checkpoint.retry_recorded",
        target_type: "connector_checkpoint",
        target_id: connector.configuration_ref <> ":" <> context.activation_id,
        before_version: case checkpoint_version {
          1 -> None
          value -> Some(value - 1)
        },
        after_version: Some(checkpoint_version),
        idempotency_key: Some(context.attempt_id),
        evidence_refs: [],
        proof_refs: [context.activation_id],
        authority_ref: Some(context.authorization_id),
        result: "failed",
        error_code: Some(error_code),
        occurred_at: now_ms,
      ),
    ))
    let phase = case effect_unknown {
      True -> "interrupted"
      False -> "failed"
    }
    use versions <- result.try(
      sqlight.query(
        "UPDATE connector_read_attempts SET phase = ?, attempt_version = attempt_version + 1, finished_at_ms = ?, error_code = ? WHERE attempt_id = ? AND worker_id = ? AND attempt_version = ? AND phase IN ('reserved', 'request_started') RETURNING attempt_version",
        on: conn,
        with: [
          sqlight.text(phase),
          sqlight.int(now_ms),
          sqlight.text(error_code),
          sqlight.text(context.attempt_id),
          sqlight.text(context.worker_id),
          sqlight.int(row.2),
        ],
        expecting: decode.at([0], decode.int),
      )
      |> result.map_error(fn(error) {
        "Failed to finish connector read failure: " <> string.inspect(error)
      }),
    )
    use attempt_version <- result.try(case versions {
      [value] -> Ok(value)
      _ -> Error("connector_read_state_conflict")
    })
    let attempt =
      ConnectorReadAttempt(
        attempt_id: context.attempt_id,
        activation_id: context.activation_id,
        activation_version: context.activation_version,
        attempt_version:,
        worker_id: context.worker_id,
        phase:,
      )
    use _ <- result.try(append_connector_read_audit(
      conn,
      attempt,
      "connector.read." <> phase,
      error_code,
      now_ms,
    ))
    Ok(attempt)
  })
}

fn validate_connector_read_error_code(error_code: String) -> Result(Nil, String) {
  case
    list.contains(
      [
        "before_dispatch",
        "external_read_unknown",
        "provider_invalid_response",
        "provider_unauthorized",
        "provider_forbidden",
        "provider_rate_limited",
        "provider_unavailable",
        "gmail_history_gap",
        "idempotency_conflict",
        "checkpoint_version_conflict",
      ],
      error_code,
    )
  {
    True -> Ok(Nil)
    False -> Error("invalid_connector_read_error_code")
  }
}

fn validate_connector_evidence_binding(
  context: operating_contracts.ConnectorSubmissionContext,
  envelope: operating_contracts.EvidenceEvent,
  connector_id: String,
) -> Result(Nil, String) {
  case
    envelope.source == "connector:" <> connector_id
    && envelope.provenance
    |> dict.get("capability")
    |> result.unwrap(operating_contracts.StructuredString(""))
    == operating_contracts.StructuredString(context.capability)
    && envelope.provenance
    |> dict.get("scope")
    |> result.unwrap(operating_contracts.StructuredString(""))
    == operating_contracts.StructuredString(context.oauth_scope)
  {
    True -> Ok(Nil)
    False -> Error("connector_submission_context_mismatch")
  }
}

fn do_get_evidence_content_hash(
  conn: sqlight.Connection,
  event_id: String,
) -> Result(Option(String), String) {
  sqlight.query(
    "SELECT content_hash FROM evidence_records WHERE event_id = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(event_id)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(error) {
    "Failed to load canonical evidence hash: " <> string.inspect(error)
  })
  |> result.map(fn(rows) {
    case rows {
      [hash, ..] -> Some(hash)
      [] -> None
    }
  })
}

fn do_store_evidence_if_absent(
  conn: sqlight.Connection,
  envelope: operating_contracts.EvidenceEvent,
  concern_links: List(evidence.ConcernLink),
  raw_ref: String,
  resource_kind: String,
  resource_id: String,
) -> Result(Bool, String) {
  use inserted_rows <- result.try(
    sqlight.query(
      "INSERT OR IGNORE INTO evidence_records (event_id, schema_version, source_kind, resource_kind, resource_id, envelope_json, raw_ref, content_hash, verification_status, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING event_id",
      on: conn,
      with: [
        sqlight.text(envelope.event_id),
        sqlight.int(envelope.schema_version),
        sqlight.text(envelope.source_kind),
        sqlight.text(resource_kind),
        sqlight.text(resource_id),
        sqlight.text(operating_contracts.encode_evidence_event(envelope)),
        sqlight.text(raw_ref),
        sqlight.text(envelope.content_hash),
        sqlight.text(envelope.verification_status),
        sqlight.int(envelope.observed_at),
      ],
      expecting: decode.at([0], decode.string),
    )
    |> result.map_error(fn(error) {
      "Failed to store normalized evidence: " <> string.inspect(error)
    }),
  )
  case inserted_rows {
    [] -> Ok(False)
    [_] -> {
      use _ <- result.try(
        list.try_each(concern_links, fn(link) {
          sqlight.query(
            "INSERT INTO evidence_concern_links (event_id, concern_id, confidence, provenance, confirmed, created_at_ms) VALUES (?, ?, ?, ?, ?, ?)",
            on: conn,
            with: [
              sqlight.text(envelope.event_id),
              sqlight.text(link.concern_id),
              sqlight.float(link.confidence),
              sqlight.text(link.provenance),
              sqlight.int(case link.confirmed {
                True -> 1
                False -> 0
              }),
              sqlight.int(envelope.observed_at),
            ],
            expecting: decode.success(Nil),
          )
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(error) {
            "Failed to store evidence concern link: " <> string.inspect(error)
          })
        }),
      )
      use _ <- result.try(do_append_operational_audit(
        conn,
        operational_audit.Record(
          schema_version: 1,
          audit_id: "",
          record_type: "state_transition",
          actor: "aura",
          source: "evidence_ingest",
          action: "evidence.stored",
          target_type: "event",
          target_id: envelope.event_id,
          before_version: None,
          after_version: Some(1),
          idempotency_key: None,
          evidence_refs: [envelope.event_id],
          proof_refs: [],
          authority_ref: None,
          result: "succeeded",
          error_code: None,
          occurred_at: envelope.observed_at,
        ),
      ))
      Ok(True)
    }
    _ -> Error("unexpected_evidence_insert_result")
  }
}

fn do_get_canonical_event_id(
  conn: sqlight.Connection,
  source: String,
  external_id: String,
) -> Result(String, String) {
  sqlight.query(
    "SELECT id FROM events WHERE source = ? AND external_id = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(source), sqlight.text(external_id)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(error) {
    "Failed to resolve canonical event: " <> string.inspect(error)
  })
  |> result.try(fn(rows) {
    case rows {
      [id, ..] -> Ok(id)
      [] -> Error("canonical_event_not_found")
    }
  })
}

fn do_get_stored_evidence(
  conn: sqlight.Connection,
  event_id: String,
) -> Result(Option(StoredEvidence), String) {
  sqlight.query(
    "SELECT envelope_json, raw_ref FROM evidence_records WHERE event_id = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(event_id)],
    expecting: {
      use envelope_json <- decode.field(0, decode.string)
      use raw_ref <- decode.field(1, decode.string)
      decode.success(#(envelope_json, raw_ref))
    },
  )
  |> result.map_error(fn(error) {
    "Failed to load normalized evidence: " <> string.inspect(error)
  })
  |> result.try(fn(rows) {
    case rows {
      [] -> Ok(None)
      [#(raw, raw_ref), ..] ->
        operating_contracts.decode_evidence_event(raw)
        |> result.map(fn(envelope) {
          Some(StoredEvidence(event_id:, envelope:, raw_ref:))
        })
    }
  })
}

fn do_list_evidence_concern_links(
  conn: sqlight.Connection,
  event_id: String,
) -> Result(List(evidence.ConcernLink), String) {
  sqlight.query(
    "SELECT concern_id, confidence, provenance, confirmed FROM evidence_concern_links WHERE event_id = ? ORDER BY concern_id",
    on: conn,
    with: [sqlight.text(event_id)],
    expecting: {
      use concern_id <- decode.field(0, decode.string)
      use confidence <- decode.field(1, decode.float)
      use provenance <- decode.field(2, decode.string)
      use confirmed <- decode.field(3, decode.int)
      decode.success(evidence.ConcernLink(
        concern_id:,
        confidence:,
        provenance:,
        confirmed: confirmed == 1,
      ))
    },
  )
  |> result.map_error(fn(error) {
    "Failed to load evidence concern links: " <> string.inspect(error)
  })
}

fn dict_structured_string(
  fields: dict.Dict(String, operating_contracts.StructuredValue),
  key: String,
) -> Result(String, Nil) {
  case dict.get(fields, key) {
    Ok(operating_contracts.StructuredString(value)) -> Ok(value)
    _ -> Error(Nil)
  }
}

fn do_insert_event_row(
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

fn nullable_int_decoder() -> decode.Decoder(Option(Int)) {
  decode.optional(decode.int)
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
  use dispatch_id <- decode.field(13, nullable_string_decoder())
  use executor_kind <- decode.field(14, decode.string)
  use capability_manifest <- decode.field(15, decode.string)
  use context_manifest <- decode.field(16, decode.string)
  use authority_boundary <- decode.field(17, decode.string)
  use final_result <- decode.field(18, nullable_string_decoder())
  use final_proof <- decode.field(19, nullable_string_decoder())
  use archived <- decode.field(20, sqlight.decode_bool())
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
    dispatch_id: dispatch_id,
    executor_kind: executor_kind,
    capability_manifest: capability_manifest,
    context_manifest: context_manifest,
    authority_boundary: authority_boundary,
    final_result: final_result,
    final_proof: final_proof,
    archived: archived,
  ))
}

fn flare_attempt_decoder() -> decode.Decoder(StoredFlareAttempt) {
  use id <- decode.field(0, decode.int)
  use flare_id <- decode.field(1, decode.string)
  use executor_kind <- decode.field(2, decode.string)
  use status <- decode.field(3, decode.string)
  use runtime_reference <- decode.field(4, nullable_string_decoder())
  use checkpoint <- decode.field(5, nullable_string_decoder())
  use started_at_ms <- decode.field(6, decode.int)
  use ended_at_ms <- decode.field(7, decode.int)
  use failure <- decode.field(8, nullable_string_decoder())
  decode.success(StoredFlareAttempt(
    id: id,
    flare_id: flare_id,
    executor_kind: executor_kind,
    status: status,
    runtime_reference: runtime_reference,
    checkpoint: checkpoint,
    started_at_ms: started_at_ms,
    ended_at_ms: ended_at_ms,
    failure: failure,
  ))
}

fn flare_event_decoder() -> decode.Decoder(StoredFlareEvent) {
  use id <- decode.field(0, decode.int)
  use flare_id <- decode.field(1, decode.string)
  use attempt_id <- decode.field(2, decode.int)
  use sequence <- decode.field(3, decode.int)
  use event_type <- decode.field(4, decode.string)
  use payload <- decode.field(5, decode.string)
  use created_at_ms <- decode.field(6, decode.int)
  decode.success(StoredFlareEvent(
    id: id,
    flare_id: flare_id,
    attempt_id: attempt_id,
    sequence: sequence,
    event_type: event_type,
    payload: payload,
    created_at_ms: created_at_ms,
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

fn do_get_integration_health(
  conn: sqlight.Connection,
  name: String,
) -> Result(Option(IntegrationHealth), String) {
  sqlight.query(
    "SELECT name, status, message, last_success_at_ms, last_error_at_ms, updated_at_ms FROM integration_health WHERE name = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(name)],
    expecting: {
      use name <- decode.field(0, decode.string)
      use status <- decode.field(1, decode.string)
      use message <- decode.field(2, decode.string)
      use last_success_at_ms <- decode.field(3, nullable_int_decoder())
      use last_error_at_ms <- decode.field(4, nullable_int_decoder())
      use updated_at_ms <- decode.field(5, decode.int)
      decode.success(IntegrationHealth(
        name: name,
        status: status,
        message: message,
        last_success_at_ms: last_success_at_ms,
        last_error_at_ms: last_error_at_ms,
        updated_at_ms: updated_at_ms,
      ))
    },
  )
  |> result.map_error(fn(err) {
    "Failed to read integration health: " <> string.inspect(err)
  })
  |> result.map(fn(rows) {
    case rows {
      [] -> option.None
      [row, ..] -> option.Some(row)
    }
  })
}

fn do_save_integration_health(
  conn: sqlight.Connection,
  health: IntegrationHealth,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO integration_health (name, status, message, last_success_at_ms, last_error_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(name) DO UPDATE SET status = excluded.status, message = excluded.message, last_success_at_ms = excluded.last_success_at_ms, last_error_at_ms = excluded.last_error_at_ms, updated_at_ms = excluded.updated_at_ms",
    on: conn,
    with: [
      sqlight.text(health.name),
      sqlight.text(health.status),
      sqlight.text(health.message),
      nullable_int(health.last_success_at_ms),
      nullable_int(health.last_error_at_ms),
      sqlight.int(health.updated_at_ms),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map_error(fn(err) {
    "Failed to save integration health: " <> string.inspect(err)
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

fn external_ask_decoder() -> decode.Decoder(StoredExternalAsk) {
  use id <- decode.field(0, decode.string)
  use source <- decode.field(1, decode.string)
  use channel_id <- decode.field(2, decode.string)
  use message_id <- decode.field(3, decode.string)
  use text <- decode.field(4, decode.string)
  use buttons_json <- decode.field(5, decode.string)
  use status <- decode.field(6, decode.string)
  use decision <- decode.field(7, decode.string)
  use requested_at_ms <- decode.field(8, decode.int)
  use updated_at_ms <- decode.field(9, decode.int)
  decode.success(StoredExternalAsk(
    id: id,
    source: source,
    channel_id: channel_id,
    message_id: message_id,
    text: text,
    buttons_json: buttons_json,
    status: status,
    decision: decision,
    requested_at_ms: requested_at_ms,
    updated_at_ms: updated_at_ms,
  ))
}

fn do_save_external_ask(
  conn: sqlight.Connection,
  ask: StoredExternalAsk,
) -> Result(Bool, String) {
  in_transaction(conn, "external ask transaction", fn() {
    use inserted <- result.try(do_save_external_ask_row(conn, ask))
    case inserted {
      False -> Ok(False)
      True -> {
        use _ <- result.try(do_append_operational_audit(
          conn,
          operational_audit.Record(
            schema_version: 1,
            audit_id: "",
            record_type: "state_transition",
            actor: "aura",
            source: "external_asks",
            action: "ask.created",
            target_type: "ask",
            target_id: ask.id,
            before_version: None,
            after_version: Some(1),
            idempotency_key: None,
            evidence_refs: [],
            proof_refs: [],
            authority_ref: None,
            result: "succeeded",
            error_code: None,
            occurred_at: ask.requested_at_ms,
          ),
        ))
        Ok(True)
      }
    }
  })
}

fn do_save_external_ask_row(
  conn: sqlight.Connection,
  ask: StoredExternalAsk,
) -> Result(Bool, String) {
  sqlight.query(
    "INSERT OR IGNORE INTO external_asks (id, source, channel_id, message_id, text, buttons_json, status, decision, requested_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id",
    on: conn,
    with: [
      sqlight.text(ask.id),
      sqlight.text(ask.source),
      sqlight.text(ask.channel_id),
      sqlight.text(ask.message_id),
      sqlight.text(ask.text),
      sqlight.text(ask.buttons_json),
      sqlight.text(ask.status),
      sqlight.text(ask.decision),
      sqlight.int(ask.requested_at_ms),
      sqlight.int(ask.updated_at_ms),
    ],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(err) {
    "Failed to save external ask: " <> string.inspect(err)
  })
  |> result.map(fn(rows) {
    case rows {
      [_] -> True
      [] -> False
      _ -> False
    }
  })
}

fn do_update_external_ask_decision(
  conn: sqlight.Connection,
  id: String,
  status: String,
  decision: String,
  updated_at_ms: Int,
) -> Result(Bool, String) {
  in_transaction(conn, "external ask decision transaction", fn() {
    use updated <- result.try(do_update_external_ask_decision_row(
      conn,
      id,
      status,
      decision,
      updated_at_ms,
    ))
    case updated {
      False -> Ok(False)
      True -> {
        use _ <- result.try(do_append_operational_audit(
          conn,
          operational_audit.Record(
            schema_version: 1,
            audit_id: "",
            record_type: "state_transition",
            actor: "aura",
            source: "external_asks",
            action: "ask." <> status,
            target_type: "ask",
            target_id: id,
            before_version: Some(1),
            after_version: Some(2),
            idempotency_key: None,
            evidence_refs: [],
            proof_refs: [],
            authority_ref: None,
            result: "succeeded",
            error_code: None,
            occurred_at: updated_at_ms,
          ),
        ))
        Ok(True)
      }
    }
  })
}

fn do_update_external_ask_decision_row(
  conn: sqlight.Connection,
  id: String,
  status: String,
  decision: String,
  updated_at_ms: Int,
) -> Result(Bool, String) {
  sqlight.query(
    "UPDATE external_asks SET status = ?, decision = ?, updated_at_ms = ? WHERE id = ? AND status = 'pending' RETURNING id",
    on: conn,
    with: [
      sqlight.text(status),
      sqlight.text(decision),
      sqlight.int(updated_at_ms),
      sqlight.text(id),
    ],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(err) {
    "Failed to update external ask decision: " <> string.inspect(err)
  })
  |> result.map(fn(rows) {
    case rows {
      [_] -> True
      [] -> False
      _ -> False
    }
  })
}

fn do_update_external_ask_message_id(
  conn: sqlight.Connection,
  id: String,
  message_id: String,
  updated_at_ms: Int,
) -> Result(Nil, String) {
  in_transaction(conn, "external ask delivery reference transaction", fn() {
    use updated <- result.try(
      sqlight.query(
        "UPDATE external_asks SET message_id = ?, updated_at_ms = ? WHERE id = ? AND status = 'pending' RETURNING id",
        on: conn,
        with: [
          sqlight.text(message_id),
          sqlight.int(updated_at_ms),
          sqlight.text(id),
        ],
        expecting: decode.at([0], decode.string),
      )
      |> result.map_error(fn(err) {
        "Failed to update external ask message id: " <> string.inspect(err)
      }),
    )
    case updated {
      [] -> Ok(Nil)
      [_] -> {
        use _ <- result.try(do_append_operational_audit(
          conn,
          operational_audit.Record(
            schema_version: 1,
            audit_id: "",
            record_type: "external_effect_outcome",
            actor: "aura",
            source: "external_asks",
            action: "ask.delivery_reference_set",
            target_type: "ask",
            target_id: id,
            before_version: None,
            after_version: None,
            idempotency_key: None,
            evidence_refs: [],
            proof_refs: [],
            authority_ref: None,
            result: "succeeded",
            error_code: None,
            occurred_at: updated_at_ms,
          ),
        ))
        Ok(Nil)
      }
      _ -> Error("Failed to update external ask message id: too many rows")
    }
  })
}

fn do_get_external_ask(
  conn: sqlight.Connection,
  id: String,
) -> Result(Option(StoredExternalAsk), String) {
  sqlight.query(
    "SELECT id, source, channel_id, message_id, text, buttons_json, status, decision, requested_at_ms, updated_at_ms FROM external_asks WHERE id = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(id)],
    expecting: external_ask_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to load external ask: " <> string.inspect(err)
  })
  |> result.map(fn(rows) {
    case rows {
      [] -> option.None
      [row, ..] -> option.Some(row)
    }
  })
}

fn do_list_external_asks(
  conn: sqlight.Connection,
  limit: Int,
) -> Result(List(StoredExternalAsk), String) {
  sqlight.query(
    "SELECT id, source, channel_id, message_id, text, buttons_json, status, decision, requested_at_ms, updated_at_ms FROM external_asks ORDER BY requested_at_ms DESC LIMIT ?",
    on: conn,
    with: [sqlight.int(limit)],
    expecting: external_ask_decoder(),
  )
  |> result.map_error(fn(err) {
    "Failed to load external asks: " <> string.inspect(err)
  })
}

fn do_list_event_sources(
  conn: sqlight.Connection,
) -> Result(List(#(String, Int, Int)), String) {
  sqlight.query(
    "SELECT source, COUNT(*), MAX(time_ms) FROM events GROUP BY source ORDER BY COUNT(*) DESC",
    on: conn,
    with: [],
    expecting: {
      use source <- decode.field(0, decode.string)
      use count <- decode.field(1, decode.int)
      use last <- decode.field(2, decode.int)
      decode.success(#(source, count, last))
    },
  )
  |> result.map_error(fn(err) {
    "Failed to list event sources: " <> string.inspect(err)
  })
}

fn do_link_concern_idempotently(
  conn: sqlight.Connection,
  idempotency_key: String,
  concern_id: String,
  kind: String,
  linked_id: String,
  result_json: String,
  occurred_at_ms: Int,
) -> Result(MutationReceipt, String) {
  use _ <- result.try(case string.trim(idempotency_key) == "" {
    True -> Error("invalid_idempotency_key")
    False -> Ok(Nil)
  })
  let payload_hash = concern_link_payload_hash(concern_id, kind, linked_id)
  in_transaction(conn, "concern link mutation", fn() {
    use existing <- result.try(do_get_mutation_receipt(conn, idempotency_key))
    case existing {
      Some(receipt) ->
        case receipt.payload_hash == payload_hash {
          True -> Ok(receipt)
          False -> Error("idempotency_conflict")
        }
      None -> {
        let target_id = concern_id <> ":" <> kind <> ":" <> linked_id
        let receipt =
          MutationReceipt(
            idempotency_key:,
            schema_version: 1,
            payload_hash:,
            operation_type: "concern.link",
            result_target_type: "concern_link",
            result_target_id: target_id,
            result_version: 1,
            result_json:,
            created_at_ms: occurred_at_ms,
          )
        use _ <- result.try(
          sqlight.query(
            "INSERT INTO concern_links (concern_id, kind, linked_id, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?)",
            on: conn,
            with: [
              sqlight.text(concern_id),
              sqlight.text(kind),
              sqlight.text(linked_id),
              sqlight.int(occurred_at_ms),
              sqlight.int(occurred_at_ms),
            ],
            expecting: decode.success(Nil),
          )
          |> result.map_error(fn(error) {
            "Failed to insert concern link: " <> string.inspect(error)
          }),
        )
        use _ <- result.try(do_append_operational_audit(
          conn,
          operational_audit.Record(
            schema_version: 1,
            audit_id: "audit:" <> idempotency_key,
            record_type: "state_transition",
            actor: "aura",
            source: "mutation_receipt",
            action: "concern.linked",
            target_type: "concern",
            target_id: concern_id,
            before_version: None,
            after_version: Some(1),
            idempotency_key: Some(idempotency_key),
            evidence_refs: case kind == "evidence" {
              True -> [linked_id]
              False -> []
            },
            proof_refs: [],
            authority_ref: None,
            result: "succeeded",
            error_code: None,
            occurred_at: occurred_at_ms,
          ),
        ))
        use _ <- result.try(do_insert_mutation_receipt(conn, receipt))
        Ok(receipt)
      }
    }
  })
}

fn concern_link_payload_hash(
  concern_id: String,
  kind: String,
  linked_id: String,
) -> String {
  let canonical_payload =
    json.object([
      #("operation_type", json.string("concern.link")),
      #("concern_id", json.string(concern_id)),
      #("kind", json.string(kind)),
      #("linked_id", json.string(linked_id)),
    ])
    |> json.to_string
  crypto.hash(crypto.Sha256, <<canonical_payload:utf8>>)
  |> bit_array.base16_encode
}

fn operational_mutation_payload_hash(
  operation_type: String,
  payload_json: String,
) -> String {
  let canonical_payload =
    json.object([
      #("operation_type", json.string(operation_type)),
      #("payload", json.string(payload_json)),
    ])
    |> json.to_string
  crypto.hash(crypto.Sha256, <<canonical_payload:utf8>>)
  |> bit_array.base16_encode
}

fn do_check_mutation_idempotency(
  conn: sqlight.Connection,
  idempotency_key: String,
  operation_type: String,
  payload_json: String,
) -> Result(Option(MutationReceipt), String) {
  use _ <- result.try(case string.trim(idempotency_key) == "" {
    True -> Error("invalid_idempotency_key")
    False -> Ok(Nil)
  })
  use existing <- result.try(do_get_mutation_receipt(conn, idempotency_key))
  case existing {
    None -> Ok(None)
    Some(receipt) ->
      case
        receipt.payload_hash
        == operational_mutation_payload_hash(operation_type, payload_json)
      {
        True -> Ok(Some(receipt))
        False -> Error("idempotency_conflict")
      }
  }
}

fn do_claim_operational_mutation(
  conn: sqlight.Connection,
  idempotency_key: String,
  operation_type: String,
  payload_json: String,
  claimed_at_ms: Int,
) -> Result(Option(MutationReceipt), String) {
  in_transaction(conn, "operational mutation claim", fn() {
    use existing <- result.try(do_check_mutation_idempotency(
      conn,
      idempotency_key,
      operation_type,
      payload_json,
    ))
    case existing {
      Some(receipt)
        if receipt.result_version == 0
        && claimed_at_ms - receipt.created_at_ms > 30_000
      -> {
        use _ <- result.try(do_delete_pending_mutation_receipt(
          conn,
          idempotency_key,
          receipt.payload_hash,
        ))
        do_insert_mutation_claim(
          conn,
          idempotency_key,
          operation_type,
          payload_json,
          claimed_at_ms,
        )
        |> result.map(fn(_) { None })
      }
      Some(receipt) -> Ok(Some(receipt))
      None ->
        do_insert_mutation_claim(
          conn,
          idempotency_key,
          operation_type,
          payload_json,
          claimed_at_ms,
        )
        |> result.map(fn(_) { None })
    }
  })
}

fn do_insert_mutation_claim(
  conn: sqlight.Connection,
  idempotency_key: String,
  operation_type: String,
  payload_json: String,
  claimed_at_ms: Int,
) -> Result(Nil, String) {
  do_insert_mutation_receipt(
    conn,
    MutationReceipt(
      idempotency_key:,
      schema_version: 1,
      payload_hash: operational_mutation_payload_hash(
        operation_type,
        payload_json,
      ),
      operation_type:,
      result_target_type: "mutation_pending",
      result_target_id: "",
      result_version: 0,
      result_json: "{}",
      created_at_ms: claimed_at_ms,
    ),
  )
}

fn do_abandon_operational_mutation(
  conn: sqlight.Connection,
  idempotency_key: String,
  operation_type: String,
  payload_json: String,
) -> Result(Nil, String) {
  do_delete_pending_mutation_receipt(
    conn,
    idempotency_key,
    operational_mutation_payload_hash(operation_type, payload_json),
  )
}

fn do_delete_pending_mutation_receipt(
  conn: sqlight.Connection,
  idempotency_key: String,
  payload_hash: String,
) -> Result(Nil, String) {
  sqlight.query(
    "DELETE FROM mutation_receipts WHERE idempotency_key = ? AND payload_hash = ? AND result_version = 0",
    on: conn,
    with: [sqlight.text(idempotency_key), sqlight.text(payload_hash)],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    "Failed to abandon mutation claim: " <> string.inspect(error)
  })
}

fn do_complete_operational_mutation(
  conn: sqlight.Connection,
  idempotency_key: String,
  operation_type: String,
  payload_json: String,
  target_type: String,
  target_id: String,
  action: String,
  result_json: String,
  concern_domain_id: Option(String),
  occurred_at_ms: Int,
) -> Result(MutationReceipt, String) {
  let payload_hash =
    operational_mutation_payload_hash(operation_type, payload_json)
  in_transaction(conn, "operational mutation", fn() {
    use existing <- result.try(do_check_mutation_idempotency(
      conn,
      idempotency_key,
      operation_type,
      payload_json,
    ))
    case existing {
      Some(receipt) if receipt.result_version > 0 -> Ok(receipt)
      Some(_) | None -> {
        use _ <- result.try(case concern_domain_id {
          None -> Ok(Nil)
          Some(domain_id) ->
            sqlight.query(
              "INSERT OR IGNORE INTO concern_links (concern_id, kind, linked_id, created_at_ms, updated_at_ms) VALUES (?, 'domain', ?, ?, ?)",
              on: conn,
              with: [
                sqlight.text(target_id),
                sqlight.text(domain_id),
                sqlight.int(occurred_at_ms),
                sqlight.int(occurred_at_ms),
              ],
              expecting: decode.success(Nil),
            )
            |> result.map(fn(_) { Nil })
            |> result.map_error(fn(error) {
              "Failed to index concern domain: " <> string.inspect(error)
            })
        })
        use _ <- result.try(do_append_operational_audit(
          conn,
          operational_audit.Record(
            schema_version: 1,
            audit_id: "audit:" <> idempotency_key,
            record_type: "state_transition",
            actor: "aura",
            source: "command_mutation",
            action:,
            target_type:,
            target_id:,
            before_version: None,
            after_version: Some(1),
            idempotency_key: Some(idempotency_key),
            evidence_refs: [],
            proof_refs: [],
            authority_ref: None,
            result: "succeeded",
            error_code: None,
            occurred_at: occurred_at_ms,
          ),
        ))
        let receipt =
          MutationReceipt(
            idempotency_key:,
            schema_version: 1,
            payload_hash:,
            operation_type:,
            result_target_type: target_type,
            result_target_id: target_id,
            result_version: 1,
            result_json:,
            created_at_ms: occurred_at_ms,
          )
        use _ <- result.try(case existing {
          Some(_) -> do_update_pending_mutation_receipt(conn, receipt)
          None -> do_insert_mutation_receipt(conn, receipt)
        })
        Ok(receipt)
      }
    }
  })
}

fn do_update_pending_mutation_receipt(
  conn: sqlight.Connection,
  receipt: MutationReceipt,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE mutation_receipts SET result_target_type = ?, result_target_id = ?, result_version = ?, result_json = ? WHERE idempotency_key = ? AND payload_hash = ? AND result_version = 0",
    on: conn,
    with: [
      sqlight.text(receipt.result_target_type),
      sqlight.text(receipt.result_target_id),
      sqlight.int(receipt.result_version),
      sqlight.text(receipt.result_json),
      sqlight.text(receipt.idempotency_key),
      sqlight.text(receipt.payload_hash),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    "Failed to complete mutation receipt: " <> string.inspect(error)
  })
}

fn do_get_mutation_receipt(
  conn: sqlight.Connection,
  idempotency_key: String,
) -> Result(Option(MutationReceipt), String) {
  sqlight.query(
    "SELECT idempotency_key, schema_version, payload_hash, operation_type, result_target_type, result_target_id, result_version, result_json, created_at_ms FROM mutation_receipts WHERE idempotency_key = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(idempotency_key)],
    expecting: mutation_receipt_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to load mutation receipt: " <> string.inspect(error)
  })
  |> result.map(fn(rows) {
    case rows {
      [] -> None
      [receipt, ..] -> Some(receipt)
    }
  })
}

fn do_insert_mutation_receipt(
  conn: sqlight.Connection,
  receipt: MutationReceipt,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO mutation_receipts (idempotency_key, schema_version, payload_hash, operation_type, result_target_type, result_target_id, result_version, result_json, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(receipt.idempotency_key),
      sqlight.int(receipt.schema_version),
      sqlight.text(receipt.payload_hash),
      sqlight.text(receipt.operation_type),
      sqlight.text(receipt.result_target_type),
      sqlight.text(receipt.result_target_id),
      sqlight.int(receipt.result_version),
      sqlight.text(receipt.result_json),
      sqlight.int(receipt.created_at_ms),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    "Failed to insert mutation receipt: " <> string.inspect(error)
  })
}

fn mutation_receipt_decoder() -> decode.Decoder(MutationReceipt) {
  use idempotency_key <- decode.field(0, decode.string)
  use schema_version <- decode.field(1, decode.int)
  use payload_hash <- decode.field(2, decode.string)
  use operation_type <- decode.field(3, decode.string)
  use result_target_type <- decode.field(4, decode.string)
  use result_target_id <- decode.field(5, decode.string)
  use result_version <- decode.field(6, decode.int)
  use result_json <- decode.field(7, decode.string)
  use created_at_ms <- decode.field(8, decode.int)
  decode.success(MutationReceipt(
    idempotency_key:,
    schema_version:,
    payload_hash:,
    operation_type:,
    result_target_type:,
    result_target_id:,
    result_version:,
    result_json:,
    created_at_ms:,
  ))
}

fn do_list_concern_links(
  conn: sqlight.Connection,
  concern_id: String,
) -> Result(List(#(String, String)), String) {
  sqlight.query(
    "SELECT kind, linked_id FROM concern_links WHERE concern_id = ? ORDER BY created_at_ms, rowid",
    on: conn,
    with: [sqlight.text(concern_id)],
    expecting: {
      use kind <- decode.field(0, decode.string)
      use linked_id <- decode.field(1, decode.string)
      decode.success(#(kind, linked_id))
    },
  )
  |> result.map_error(fn(error) {
    "Failed to list concern links: " <> string.inspect(error)
  })
}

fn do_enqueue_attention(
  conn: sqlight.Connection,
  request: attention_queue.EnqueueRequest,
  authorization_id: Option(String),
) -> Result(operating_contracts.AttentionQueueItem, String) {
  in_transaction(conn, "attention enqueue transaction", fn() {
    use route_activation_ids <- result.try(resolve_attention_route(
      conn,
      request,
      authorization_id,
    ))
    let expected_hash = attention_queue.payload_hash(request)
    use existing <- result.try(
      sqlight.query(
        "SELECT queue_id, payload_hash FROM attention_queue WHERE delivery_owner = ? AND delivery_key = ? LIMIT 1",
        on: conn,
        with: [
          sqlight.text(request.delivery_owner),
          sqlight.text(request.delivery_key),
        ],
        expecting: {
          use queue_id <- decode.field(0, decode.string)
          use payload_hash <- decode.field(1, decode.string)
          decode.success(#(queue_id, payload_hash))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to check attention idempotency: " <> string.inspect(error)
      }),
    )
    case existing {
      [#(queue_id, stored_hash)] -> {
        use item <- result.try(do_get_attention(conn, queue_id))
        let effective_hash = case stored_hash {
          "" -> attention_queue.stored_payload_hash(item)
          value -> value
        }
        case effective_hash == expected_hash {
          True -> {
            use _ <- result.try(case stored_hash {
              "" ->
                sqlight.query(
                  "UPDATE attention_queue SET payload_hash = ? WHERE queue_id = ?",
                  on: conn,
                  with: [sqlight.text(effective_hash), sqlight.text(queue_id)],
                  expecting: decode.success(Nil),
                )
                |> result.map_error(fn(error) {
                  "Failed to backfill attention payload hash: "
                  <> string.inspect(error)
                })
              _ -> Ok([])
            })
            use _ <- result.try(case authorization_id {
              None -> Ok(Nil)
              Some(_) ->
                append_attention_audit(
                  conn,
                  item.queue_id,
                  "attention.duplicate_suppressed",
                  Some(item.version),
                  Some(item.version),
                  item.event_refs,
                  item.authority_request,
                  "deduped",
                  None,
                  time.now_ms(),
                  "cognitive_delivery",
                )
                |> result.map(fn(_) { Nil })
            })
            Ok(item)
          }
          False ->
            Error(
              "idempotency_conflict: attention delivery key payload changed",
            )
        }
      }
      [] -> {
        let event_refs_json =
          json.array(request.event_refs, of: json.string) |> json.to_string
        let citations_json =
          json.array(request.citations, of: json.string) |> json.to_string
        use _ <- result.try(
          sqlight.query(
            "INSERT INTO attention_queue (queue_id, schema_version, decision_id, domain_id, concern_id, event_refs_json, action, summary, rationale, why_now, deferral_cost, why_not_digest, authority_request, citations_json, state, delivery_owner, delivery_target, delivery_key, payload_hash, lease_owner, lease_expires_at_ms, attempt_count, available_at_ms, expires_at_ms, created_at_ms, updated_at_ms, version, route_authorization_id, route_activation_ids_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, NULL, NULL, 0, ?, ?, ?, ?, 1, ?, ?)",
            on: conn,
            with: [
              sqlight.text(request.queue_id),
              sqlight.int(case authorization_id {
                Some(_) -> 2
                None -> 1
              }),
              sqlight.text(request.decision_id),
              sqlight.text(request.domain_id),
              sqlight.nullable(sqlight.text, request.concern_id),
              sqlight.text(event_refs_json),
              sqlight.text(request.action),
              sqlight.text(request.summary),
              sqlight.text(request.rationale),
              sqlight.nullable(sqlight.text, request.why_now),
              sqlight.nullable(sqlight.text, request.deferral_cost),
              sqlight.nullable(sqlight.text, request.why_not_digest),
              sqlight.nullable(sqlight.text, request.authority_request),
              sqlight.text(citations_json),
              sqlight.text(request.delivery_owner),
              sqlight.text(request.delivery_target),
              sqlight.text(request.delivery_key),
              sqlight.text(expected_hash),
              sqlight.int(request.available_at),
              sqlight.nullable(sqlight.int, request.expires_at),
              sqlight.int(request.available_at),
              sqlight.int(request.available_at),
              sqlight.nullable(sqlight.text, authorization_id),
              sqlight.text(route_activation_ids),
            ],
            expecting: decode.success(Nil),
          )
          |> result.map_error(fn(error) {
            "Failed to enqueue attention: " <> string.inspect(error)
          }),
        )
        use _ <- result.try(append_attention_audit(
          conn,
          request.queue_id,
          "attention.enqueued",
          None,
          Some(1),
          request.event_refs,
          request.authority_request,
          "succeeded",
          None,
          request.available_at,
          "cognitive_delivery",
        ))
        do_get_attention(conn, request.queue_id)
      }
      _ ->
        Error("Failed to check attention idempotency: duplicate delivery keys")
    }
  })
}

fn resolve_attention_route(
  conn: sqlight.Connection,
  request: attention_queue.EnqueueRequest,
  authorization_id: Option(String),
) -> Result(String, String) {
  case authorization_id {
    None -> Ok("[]")
    Some(id) -> {
      use stored <- result.try(do_get_canary_authorization(conn, id))
      use authorization <- result.try(case stored {
        Some(value) -> Ok(value.authorization)
        None -> Error("canary_authorization_not_found")
      })
      let now = time.now_ms()
      let domain_slug = case
        string.starts_with(authorization.domain_id, "domain:")
      {
        True -> string.drop_start(authorization.domain_id, 7)
        False -> authorization.domain_id
      }
      let has_policy =
        list.any(authorization.policy_refs, fn(reference) {
          list.contains(request.citations, reference)
        })
      use _ <- result.try(validate_authorized_attention_evidence(
        conn,
        request.event_refs,
        request.citations,
        id,
      ))
      use _ <- result.try(
        case
          authorization.starts_at_ms <= now
          && authorization.ends_at_ms > now
          && authorization.attention_owner == "codex"
          && authorization.attention_target == "codex_monitor"
          && !authorization.discord_delivery_allowed
          && request.delivery_owner == authorization.attention_owner
          && request.delivery_target == authorization.attention_target
          && request.domain_id == domain_slug
          && request.concern_id == Some(authorization.concern_id)
          && has_policy
        {
          True -> Ok(Nil)
          False -> Error("authorized_attention_route_mismatch")
        },
      )
      use activations <- result.try(
        list.try_map(authorization.connectors, fn(connector) {
          use effective <- result.try(do_get_effective_connector_activation(
            conn,
            connector.activation_id,
            authorization.authorization_id,
          ))
          case effective {
            Some(value)
              if value.domain_id == authorization.domain_id
              && value.concern_id == authorization.concern_id
            -> Ok(value.activation_id)
            _ -> Error("authorized_attention_activation_not_effective")
          }
        }),
      )
      Ok(
        json.array(list.sort(activations, by: string.compare), of: json.string)
        |> json.to_string,
      )
    }
  }
}

fn validate_authorized_attention_evidence(
  conn: sqlight.Connection,
  event_refs: List(String),
  citations: List(String),
  authorization_id: String,
) -> Result(Nil, String) {
  use _ <- result.try(case event_refs {
    [] -> Error("authorized_attention_evidence_required")
    _ -> Ok(Nil)
  })
  let cited_event_refs =
    citations
    |> list.filter_map(fn(reference) {
      case string.starts_with(reference, "evidence:") {
        True -> Ok(string.drop_start(reference, 9))
        False -> Error(Nil)
      }
    })
  use _ <- result.try(
    case
      list.sort(cited_event_refs, by: string.compare)
      == list.sort(event_refs, by: string.compare)
    {
      True -> Ok(Nil)
      False -> Error("authorized_attention_evidence_mismatch")
    },
  )
  use _ <- result.try(
    list.try_each(event_refs, fn(event_id) {
      use rows <- result.try(
        sqlight.query(
          "SELECT json_extract(envelope_json, '$.provenance.authorization_id') FROM evidence_records WHERE event_id = ? LIMIT 1",
          on: conn,
          with: [sqlight.text(event_id)],
          expecting: decode.at([0], decode.string),
        )
        |> result.map_error(fn(error) {
          "Failed to validate authorized attention evidence: "
          <> string.inspect(error)
        }),
      )
      case rows, list.contains(citations, "evidence:" <> event_id) {
        [stored_authorization_id], True
          if stored_authorization_id == authorization_id
        -> Ok(Nil)
        _, _ -> Error("authorized_attention_evidence_mismatch")
      }
    }),
  )
  Ok(Nil)
}

fn do_get_attention(
  conn: sqlight.Connection,
  queue_id: String,
) -> Result(operating_contracts.AttentionQueueItem, String) {
  sqlight.query(
    attention_select() <> " WHERE queue_id = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(queue_id)],
    expecting: attention_item_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to load attention item: " <> string.inspect(error)
  })
  |> result.try(fn(rows) {
    case rows {
      [item] -> Ok(item)
      [] -> Error("Attention item not found: " <> queue_id)
      _ -> Error("Duplicate attention item: " <> queue_id)
    }
  })
}

fn do_list_attention(
  conn: sqlight.Connection,
  delivery_owner: String,
  queue_state: String,
) -> Result(List(operating_contracts.AttentionQueueItem), String) {
  sqlight.query(
    attention_select()
      <> " WHERE delivery_owner = ? AND state = ? ORDER BY available_at_ms, created_at_ms, queue_id",
    on: conn,
    with: [sqlight.text(delivery_owner), sqlight.text(queue_state)],
    expecting: attention_item_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to list attention items: " <> string.inspect(error)
  })
}

fn attention_select() -> String {
  "SELECT queue_id, schema_version, decision_id, domain_id, concern_id, event_refs_json, action, summary, rationale, why_now, deferral_cost, why_not_digest, authority_request, citations_json, state, delivery_owner, delivery_target, delivery_key, lease_owner, lease_expires_at_ms, attempt_count, available_at_ms, expires_at_ms, created_at_ms, updated_at_ms, version FROM attention_queue"
}

fn attention_item_decoder() -> decode.Decoder(
  operating_contracts.AttentionQueueItem,
) {
  use queue_id <- decode.field(0, decode.string)
  use schema_version <- decode.field(1, decode.int)
  use decision_id <- decode.field(2, decode.string)
  use domain_id <- decode.field(3, decode.string)
  use concern_id <- decode.field(4, decode.optional(decode.string))
  use event_refs_json <- decode.field(5, decode.string)
  use action <- decode.field(6, decode.string)
  use summary <- decode.field(7, decode.string)
  use rationale <- decode.field(8, decode.string)
  use why_now <- decode.field(9, decode.optional(decode.string))
  use deferral_cost <- decode.field(10, decode.optional(decode.string))
  use why_not_digest <- decode.field(11, decode.optional(decode.string))
  use authority_request <- decode.field(12, decode.optional(decode.string))
  use citations_json <- decode.field(13, decode.string)
  use state <- decode.field(14, decode.string)
  use delivery_owner <- decode.field(15, decode.string)
  use delivery_target <- decode.field(16, decode.string)
  use delivery_key <- decode.field(17, decode.string)
  use lease_owner <- decode.field(18, decode.optional(decode.string))
  use lease_expires_at <- decode.field(19, decode.optional(decode.int))
  use attempt_count <- decode.field(20, decode.int)
  use available_at <- decode.field(21, decode.int)
  use expires_at <- decode.field(22, decode.optional(decode.int))
  use created_at <- decode.field(23, decode.int)
  use updated_at <- decode.field(24, decode.int)
  use version <- decode.field(25, decode.int)
  case
    json.parse(event_refs_json, decode.list(decode.string)),
    json.parse(citations_json, decode.list(decode.string))
  {
    Ok(event_refs), Ok(citations) ->
      decode.success(operating_contracts.AttentionQueueItem(
        schema_version:,
        queue_id:,
        decision_id:,
        domain_id:,
        concern_id:,
        event_refs:,
        action:,
        summary:,
        rationale:,
        why_now:,
        deferral_cost:,
        why_not_digest:,
        authority_request:,
        citations:,
        state:,
        delivery_owner:,
        delivery_target:,
        delivery_key:,
        lease_owner:,
        lease_expires_at:,
        attempt_count:,
        available_at:,
        expires_at:,
        created_at:,
        updated_at:,
        version:,
      ))
    _, _ ->
      decode.failure(
        operating_contracts.AttentionQueueItem(
          schema_version: 1,
          queue_id: "",
          decision_id: "",
          domain_id: "",
          concern_id: None,
          event_refs: [],
          action: "surface_now",
          summary: "",
          rationale: "",
          why_now: None,
          deferral_cost: None,
          why_not_digest: None,
          authority_request: None,
          citations: [],
          state: "pending",
          delivery_owner: "discord_compat",
          delivery_target: "",
          delivery_key: "",
          lease_owner: None,
          lease_expires_at: None,
          attempt_count: 0,
          available_at: 0,
          expires_at: None,
          created_at: 0,
          updated_at: 0,
          version: 0,
        ),
        expected: "attention reference JSON",
      )
  }
}

fn do_claim_attention(
  conn: sqlight.Connection,
  owner: String,
  worker_id: String,
  lease_ms: Int,
  now: Int,
  route: Option(MonitorRoute),
) -> Result(Option(attention_queue.Claim), String) {
  in_transaction(conn, "attention claim transaction", fn() {
    let effective_now = case route {
      Some(_) -> time.now_ms()
      None -> now
    }
    use claim_is_new <- result.try(prepare_authorized_claim_receipt(
      conn,
      route,
      effective_now,
    ))
    case claim_is_new {
      False -> Ok(None)
      True ->
        do_claim_new_attention(
          conn,
          owner,
          worker_id,
          lease_ms,
          effective_now,
          route,
        )
    }
  })
}

fn do_claim_new_attention(
  conn: sqlight.Connection,
  owner: String,
  worker_id: String,
  lease_ms: Int,
  effective_now: Int,
  route: Option(MonitorRoute),
) -> Result(Option(attention_queue.Claim), String) {
  use rows <- result.try(select_attention_claim(
    conn,
    owner,
    effective_now,
    route,
  ))
  case rows {
    [] -> Ok(None)
    [queue_id] -> {
      use item <- result.try(do_get_attention(conn, queue_id))
      let attempt_number = item.attempt_count + 1
      let lease_expires_at = effective_now + lease_ms
      let lease_token =
        queue_id <> ":" <> string.inspect(attempt_number) <> ":" <> worker_id
      use updated <- result.try(
        sqlight.query(
          "UPDATE attention_queue SET state = 'leased', lease_owner = ?, lease_expires_at_ms = ?, attempt_count = ?, updated_at_ms = ?, version = version + 1 WHERE queue_id = ? AND state IN ('pending', 'deferred') RETURNING queue_id",
          on: conn,
          with: [
            sqlight.text(worker_id),
            sqlight.int(lease_expires_at),
            sqlight.int(attempt_number),
            sqlight.int(effective_now),
            sqlight.text(queue_id),
          ],
          expecting: decode.at([0], decode.string),
        )
        |> result.map_error(fn(error) {
          "Failed to claim attention item: " <> string.inspect(error)
        }),
      )
      case updated {
        [_] -> {
          use _ <- result.try(
            sqlight.query(
              "INSERT INTO attention_delivery_attempts (queue_id, attempt_number, lease_owner, lease_token, lease_expires_at_ms, phase, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, 'claimed', ?, ?)",
              on: conn,
              with: [
                sqlight.text(queue_id),
                sqlight.int(attempt_number),
                sqlight.text(worker_id),
                sqlight.text(lease_token),
                sqlight.int(lease_expires_at),
                sqlight.int(effective_now),
                sqlight.int(effective_now),
              ],
              expecting: decode.success(Nil),
            )
            |> result.map_error(fn(error) {
              "Failed to create attention attempt: " <> string.inspect(error)
            }),
          )
          use claimed <- result.try(do_get_attention(conn, queue_id))
          use _ <- result.try(append_attention_audit(
            conn,
            queue_id,
            "attention.claimed",
            Some(item.version),
            Some(claimed.version),
            item.event_refs,
            case route {
              Some(binding) -> Some(binding.authorization_id)
              None -> item.authority_request
            },
            "succeeded",
            None,
            effective_now,
            worker_id,
          ))
          Ok(Some(attention_queue.Claim(item: claimed, lease_token:)))
        }
        _ -> Ok(None)
      }
    }
    _ -> Error("Failed to select attention claim: unexpected rows")
  }
}

fn prepare_authorized_claim_receipt(
  conn: sqlight.Connection,
  route: Option(MonitorRoute),
  now: Int,
) -> Result(Bool, String) {
  case route {
    None -> Ok(True)
    Some(binding) -> {
      use _ <- result.try(
        case
          operating_contracts.valid_codex_reference(
            binding.claim_command_id,
            "command",
          )
          && string.length(binding.claim_payload_hash) == 64
        {
          True -> Ok(Nil)
          False -> Error("monitor_authentication_failed")
        },
      )
      let key = "monitor-claim:" <> binding.claim_command_id
      use existing <- result.try(do_get_mutation_receipt(conn, key))
      case existing {
        Some(receipt) if receipt.payload_hash == binding.claim_payload_hash ->
          Ok(False)
        Some(_) -> Error("idempotency_conflict")
        None -> {
          use _ <- result.try(do_insert_mutation_receipt(
            conn,
            MutationReceipt(
              idempotency_key: key,
              schema_version: 1,
              payload_hash: binding.claim_payload_hash,
              operation_type: "monitor.claim",
              result_target_type: "monitor_command",
              result_target_id: binding.claim_command_id,
              result_version: 1,
              result_json: "{\"accepted\":true}",
              created_at_ms: now,
            ),
          ))
          Ok(True)
        }
      }
    }
  }
}

fn select_attention_claim(
  conn: sqlight.Connection,
  owner: String,
  now: Int,
  route: Option(MonitorRoute),
) -> Result(List(String), String) {
  let #(statement, values) = case route {
    None -> #(
      "SELECT queue_id FROM attention_queue WHERE delivery_owner = ? AND state IN ('pending', 'deferred') AND action IN ('surface_now', 'ask_now') AND delivery_target <> '' AND payload_hash <> '' AND available_at_ms <= ? AND (expires_at_ms IS NULL OR expires_at_ms > ?) ORDER BY available_at_ms, created_at_ms, queue_id LIMIT 1",
      [sqlight.text(owner), sqlight.int(now), sqlight.int(now)],
    )
    Some(binding) -> #(
      "SELECT queue_id FROM attention_queue WHERE schema_version = 2 AND delivery_owner = 'codex' AND delivery_target = 'codex_monitor' AND route_authorization_id = ? AND route_activation_ids_json = ? AND domain_id = ? AND concern_id = ? AND state IN ('pending', 'deferred') AND action IN ('surface_now', 'ask_now') AND payload_hash <> '' AND available_at_ms <= ? AND (expires_at_ms IS NULL OR expires_at_ms > ?) AND EXISTS (SELECT 1 FROM canary_authorizations au WHERE au.authorization_id = attention_queue.route_authorization_id AND au.starts_at_ms <= ? AND au.ends_at_ms > ?) AND NOT EXISTS (SELECT 1 FROM json_each(attention_queue.route_activation_ids_json) ids LEFT JOIN connector_activations ca ON ca.activation_id = ids.value AND ca.authorization_id = attention_queue.route_authorization_id AND ca.domain_id = ? AND ca.concern_id = ? AND ca.state = 'enabled' WHERE ca.activation_id IS NULL) ORDER BY available_at_ms, created_at_ms, queue_id LIMIT 1",
      [
        sqlight.text(binding.authorization_id),
        sqlight.text(binding.activation_ids_json),
        sqlight.text(binding.domain_id),
        sqlight.text(binding.concern_id),
        sqlight.int(now),
        sqlight.int(now),
        sqlight.int(now),
        sqlight.int(now),
        sqlight.text("domain:" <> binding.domain_id),
        sqlight.text(binding.concern_id),
      ],
    )
  }
  sqlight.query(
    statement,
    on: conn,
    with: values,
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(error) {
    "Failed to select attention claim: " <> string.inspect(error)
  })
}

fn do_begin_attention_delivery(
  conn: sqlight.Connection,
  lease_token: String,
  now: Int,
) -> Result(Nil, String) {
  in_transaction(conn, "attention intent transaction", fn() {
    record_attention_delivery_intent(conn, lease_token, now)
  })
}

fn do_begin_authorized_attention_delivery(
  conn: sqlight.Connection,
  lease_token: String,
) -> Result(Nil, String) {
  in_transaction(conn, "authorized attention intent transaction", fn() {
    record_attention_delivery_intent(conn, lease_token, time.now_ms())
  })
}

fn record_attention_delivery_intent(
  conn: sqlight.Connection,
  lease_token: String,
  now: Int,
) -> Result(Nil, String) {
  use rows <- result.try(
    sqlight.query(
      "UPDATE attention_delivery_attempts SET phase = 'intent', updated_at_ms = ? WHERE lease_token = ? AND phase = 'claimed' AND EXISTS (SELECT 1 FROM attention_queue q WHERE q.queue_id = attention_delivery_attempts.queue_id AND q.state = 'leased' AND q.lease_owner = attention_delivery_attempts.lease_owner AND q.lease_expires_at_ms >= ?) RETURNING queue_id",
      on: conn,
      with: [sqlight.int(now), sqlight.text(lease_token), sqlight.int(now)],
      expecting: decode.at([0], decode.string),
    )
    |> result.map_error(fn(error) {
      "Failed to record attention delivery intent: " <> string.inspect(error)
    }),
  )
  case rows {
    [queue_id] -> {
      use item <- result.try(do_get_attention(conn, queue_id))
      use _ <- result.try(append_attention_audit(
        conn,
        queue_id,
        "attention.delivery_intended",
        Some(item.version),
        Some(item.version),
        item.event_refs,
        item.authority_request,
        "succeeded",
        None,
        now,
        item.lease_owner |> option.unwrap("discord_compat"),
      ))
      Ok(Nil)
    }
    [] -> Error("Attention lease is not claimable for delivery intent")
    _ -> Error("Unexpected attention delivery intent result")
  }
}

fn do_recover_attention(
  conn: sqlight.Connection,
  owner: String,
  now: Int,
) -> Result(attention_queue.RecoverySummary, String) {
  in_transaction(conn, "attention recovery transaction", fn() {
    use expired <- result.try(
      sqlight.query(
        "SELECT a.queue_id, a.lease_token, a.phase FROM attention_delivery_attempts a JOIN attention_queue q ON q.queue_id = a.queue_id WHERE q.delivery_owner = ? AND q.state = 'leased' AND q.lease_expires_at_ms < ? AND a.attempt_number = q.attempt_count AND a.phase IN ('claimed', 'intent') ORDER BY q.queue_id",
        on: conn,
        with: [sqlight.text(owner), sqlight.int(now)],
        expecting: {
          use queue_id <- decode.field(0, decode.string)
          use lease_token <- decode.field(1, decode.string)
          use phase <- decode.field(2, decode.string)
          decode.success(#(queue_id, lease_token, phase))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to load expired attention claims: " <> string.inspect(error)
      }),
    )
    recover_attention_rows(
      conn,
      expired,
      now,
      attention_queue.RecoverySummary(requeued: 0, unknown: 0),
    )
  })
}

fn do_renew_attention_lease(
  conn: sqlight.Connection,
  lease_token: String,
  lease_ms: Int,
  now: Int,
) -> Result(Nil, String) {
  in_transaction(conn, "attention lease renewal transaction", fn() {
    let expires_at = now + lease_ms
    use rows <- result.try(
      sqlight.query(
        "UPDATE attention_delivery_attempts SET lease_expires_at_ms = ?, updated_at_ms = ? WHERE lease_token = ? AND phase IN ('claimed', 'intent') AND lease_expires_at_ms >= ? RETURNING queue_id, lease_owner",
        on: conn,
        with: [
          sqlight.int(expires_at),
          sqlight.int(now),
          sqlight.text(lease_token),
          sqlight.int(now),
        ],
        expecting: {
          use queue_id <- decode.field(0, decode.string)
          use owner <- decode.field(1, decode.string)
          decode.success(#(queue_id, owner))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to renew attention lease: " <> string.inspect(error)
      }),
    )
    case rows {
      [#(queue_id, owner)] -> {
        use item <- result.try(do_get_attention(conn, queue_id))
        use updated <- result.try(
          sqlight.query(
            "UPDATE attention_queue SET lease_expires_at_ms = ?, updated_at_ms = ? WHERE queue_id = ? AND state = 'leased' AND lease_owner = ? RETURNING queue_id",
            on: conn,
            with: [
              sqlight.int(expires_at),
              sqlight.int(now),
              sqlight.text(queue_id),
              sqlight.text(owner),
            ],
            expecting: decode.at([0], decode.string),
          )
          |> result.map_error(fn(error) {
            "Failed to renew attention item lease: " <> string.inspect(error)
          }),
        )
        case updated {
          [_] ->
            append_attention_audit(
              conn,
              queue_id,
              "attention.lease_renewed",
              Some(item.version),
              Some(item.version),
              item.event_refs,
              item.authority_request,
              "succeeded",
              None,
              now,
              owner,
            )
            |> result.map(fn(_) { Nil })
          _ -> Error("Attention item lease owner changed")
        }
      }
      [] -> Error("Attention lease is expired or inactive")
      _ -> Error("Unexpected attention lease renewal result")
    }
  })
}

fn do_reschedule_attention(
  conn: sqlight.Connection,
  lease_token: String,
  error: String,
  available_at: Int,
  now: Int,
) -> Result(Nil, String) {
  in_transaction(conn, "attention reschedule transaction", fn() {
    use rows <- result.try(
      sqlight.query(
        "UPDATE attention_delivery_attempts SET phase = 'failed', error = ?, updated_at_ms = ? WHERE lease_token = ? AND phase = 'claimed' RETURNING queue_id",
        on: conn,
        with: [sqlight.text(error), sqlight.int(now), sqlight.text(lease_token)],
        expecting: decode.at([0], decode.string),
      )
      |> result.map_error(fn(problem) {
        "Failed to fail attention claim: " <> string.inspect(problem)
      }),
    )
    use queue_id <- result.try(case rows {
      [queue_id] -> Ok(queue_id)
      [] -> Error("Attention claim is not active before delivery intent")
      _ -> Error("Unexpected attention reschedule result")
    })
    use item <- result.try(do_get_attention(conn, queue_id))
    use updated <- result.try(
      sqlight.query(
        "UPDATE attention_queue SET state = 'deferred', available_at_ms = ?, lease_owner = NULL, lease_expires_at_ms = NULL, updated_at_ms = ?, version = version + 1 WHERE queue_id = ? AND state = 'leased' RETURNING queue_id",
        on: conn,
        with: [
          sqlight.int(available_at),
          sqlight.int(now),
          sqlight.text(queue_id),
        ],
        expecting: decode.at([0], decode.string),
      )
      |> result.map_error(fn(problem) {
        "Failed to reschedule attention item: " <> string.inspect(problem)
      }),
    )
    case updated {
      [_] ->
        append_attention_audit(
          conn,
          queue_id,
          "attention.rescheduled",
          Some(item.version),
          Some(item.version + 1),
          item.event_refs,
          item.authority_request,
          "failed",
          Some(error),
          now,
          "discord_compat",
        )
        |> result.map(fn(_) { Nil })
      _ -> Error("Attention item is not leased for reschedule")
    }
  })
}

fn do_expire_attention(
  conn: sqlight.Connection,
  owner: String,
  now: Int,
) -> Result(Int, String) {
  in_transaction(conn, "attention expiry transaction", fn() {
    use queue_ids <- result.try(
      sqlight.query(
        "SELECT queue_id FROM attention_queue WHERE delivery_owner = ? AND state IN ('pending', 'deferred') AND expires_at_ms IS NOT NULL AND expires_at_ms <= ? ORDER BY queue_id",
        on: conn,
        with: [sqlight.text(owner), sqlight.int(now)],
        expecting: decode.at([0], decode.string),
      )
      |> result.map_error(fn(error) {
        "Failed to load expired attention items: " <> string.inspect(error)
      }),
    )
    expire_attention_rows(conn, queue_ids, now, 0)
  })
}

fn expire_attention_rows(
  conn: sqlight.Connection,
  queue_ids: List(String),
  now: Int,
  count: Int,
) -> Result(Int, String) {
  case queue_ids {
    [] -> Ok(count)
    [queue_id, ..rest] -> {
      use item <- result.try(do_get_attention(conn, queue_id))
      use _ <- result.try(
        sqlight.query(
          "UPDATE attention_queue SET state = 'expired', updated_at_ms = ?, version = version + 1 WHERE queue_id = ? AND state IN ('pending', 'deferred')",
          on: conn,
          with: [sqlight.int(now), sqlight.text(queue_id)],
          expecting: decode.success(Nil),
        )
        |> result.map_error(fn(error) {
          "Failed to expire attention item: " <> string.inspect(error)
        }),
      )
      use _ <- result.try(append_attention_audit(
        conn,
        queue_id,
        "attention.expired",
        Some(item.version),
        Some(item.version + 1),
        item.event_refs,
        item.authority_request,
        "succeeded",
        None,
        now,
        "attention_queue",
      ))
      expire_attention_rows(conn, rest, now, count + 1)
    }
  }
}

fn recover_attention_rows(
  conn: sqlight.Connection,
  rows: List(#(String, String, String)),
  now: Int,
  summary: attention_queue.RecoverySummary,
) -> Result(attention_queue.RecoverySummary, String) {
  case rows {
    [] -> Ok(summary)
    [#(queue_id, lease_token, phase), ..rest] -> {
      use item <- result.try(do_get_attention(conn, queue_id))
      let #(attempt_phase, queue_state, action, result_value, error_code) = case
        phase
      {
        "claimed" -> #(
          "failed",
          "pending",
          "attention.claim_recovered",
          "failed",
          Some("lease_expired"),
        )
        _ -> #(
          "effect_unknown",
          "dead_letter",
          "attention.delivery_effect_unknown",
          "effect_unknown",
          Some("lease_expired_after_intent"),
        )
      }
      use _ <- result.try(
        sqlight.query(
          "UPDATE attention_delivery_attempts SET phase = ?, error = ?, updated_at_ms = ? WHERE lease_token = ? AND phase = ?",
          on: conn,
          with: [
            sqlight.text(attempt_phase),
            sqlight.text(error_code |> option.unwrap("")),
            sqlight.int(now),
            sqlight.text(lease_token),
            sqlight.text(phase),
          ],
          expecting: decode.success(Nil),
        )
        |> result.map_error(fn(error) {
          "Failed to recover attention attempt: " <> string.inspect(error)
        }),
      )
      use _ <- result.try(
        sqlight.query(
          "UPDATE attention_queue SET state = ?, lease_owner = NULL, lease_expires_at_ms = NULL, updated_at_ms = ?, version = version + 1 WHERE queue_id = ? AND state = 'leased'",
          on: conn,
          with: [
            sqlight.text(queue_state),
            sqlight.int(now),
            sqlight.text(queue_id),
          ],
          expecting: decode.success(Nil),
        )
        |> result.map_error(fn(error) {
          "Failed to recover attention item: " <> string.inspect(error)
        }),
      )
      use _ <- result.try(append_attention_audit(
        conn,
        queue_id,
        action,
        Some(item.version),
        Some(item.version + 1),
        item.event_refs,
        item.authority_request,
        result_value,
        error_code,
        now,
        "attention_recovery",
      ))
      let next = case phase {
        "claimed" ->
          attention_queue.RecoverySummary(
            ..summary,
            requeued: summary.requeued + 1,
          )
        _ ->
          attention_queue.RecoverySummary(
            ..summary,
            unknown: summary.unknown + 1,
          )
      }
      recover_attention_rows(conn, rest, now, next)
    }
  }
}

fn do_finish_attention_delivery(
  conn: sqlight.Connection,
  lease_token: String,
  channel_id: String,
  visible_content: String,
  receipts: List(String),
  outcome: String,
  error: String,
  now: Int,
) -> Result(Nil, String) {
  in_transaction(conn, "attention outcome transaction", fn() {
    use rows <- result.try(
      sqlight.query(
        "SELECT a.queue_id FROM attention_delivery_attempts a JOIN attention_queue q ON q.queue_id = a.queue_id WHERE a.lease_token = ? AND a.phase = 'intent' AND q.state = 'leased' AND q.lease_owner = a.lease_owner LIMIT 1",
        on: conn,
        with: [sqlight.text(lease_token)],
        expecting: decode.at([0], decode.string),
      )
      |> result.map_error(fn(problem) {
        "Failed to load attention delivery attempt: " <> string.inspect(problem)
      }),
    )
    use queue_id <- result.try(case rows {
      [queue_id] -> Ok(queue_id)
      [] -> Error("Attention delivery attempt is not active")
      _ -> Error("Duplicate attention delivery attempt")
    })
    use item <- result.try(do_get_attention(conn, queue_id))
    let receipts_json = json.array(receipts, of: json.string) |> json.to_string
    use _ <- result.try(
      sqlight.query(
        "UPDATE attention_delivery_attempts SET phase = ?, external_receipts_json = ?, error = ?, updated_at_ms = ? WHERE lease_token = ? AND phase = 'intent'",
        on: conn,
        with: [
          sqlight.text(outcome),
          sqlight.text(receipts_json),
          sqlight.text(error),
          sqlight.int(now),
          sqlight.text(lease_token),
        ],
        expecting: decode.success(Nil),
      )
      |> result.map_error(fn(problem) {
        "Failed to store attention delivery outcome: "
        <> string.inspect(problem)
      }),
    )
    let queue_state = case outcome {
      "succeeded" -> "delivered"
      _ -> "dead_letter"
    }
    use _ <- result.try(
      sqlight.query(
        "UPDATE attention_queue SET state = ?, lease_owner = NULL, lease_expires_at_ms = NULL, updated_at_ms = ?, version = version + 1 WHERE queue_id = ? AND state = 'leased'",
        on: conn,
        with: [
          sqlight.text(queue_state),
          sqlight.int(now),
          sqlight.text(queue_id),
        ],
        expecting: decode.success(Nil),
      )
      |> result.map_error(fn(problem) {
        "Failed to store attention item outcome: " <> string.inspect(problem)
      }),
    )
    use _ <- result.try(case visible_content {
      "" -> Ok(Nil)
      content -> {
        use conversation_id <- result.try(do_resolve_conversation(
          conn,
          "discord",
          channel_id,
          now,
        ))
        use _ <- result.try(do_append_message(
          conn,
          conversation_id,
          "assistant",
          content,
          "aura",
          "Aura",
          now,
        ))
        do_update_last_active(conn, conversation_id, now)
      }
    })
    append_attention_audit(
      conn,
      queue_id,
      case outcome {
        "succeeded" -> "attention.delivered"
        _ -> "attention.delivery_effect_unknown"
      },
      Some(item.version),
      Some(item.version + 1),
      item.event_refs,
      item.authority_request,
      outcome,
      case error {
        "" -> None
        _ -> Some(error)
      },
      now,
      "discord_compat",
    )
    |> result.map(fn(_) { Nil })
  })
}

fn do_apply_monitor_outcome(
  conn: sqlight.Connection,
  outcome: operating_contracts.MonitorOutcome,
  route: Option(MonitorRoute),
) -> Result(operating_contracts.MonitorOutcomeReceipt, String) {
  let payload = case route {
    None -> operating_contracts.encode_monitor_outcome(outcome)
    Some(binding) ->
      operating_contracts.encode_monitor_outcome(
        operating_contracts.MonitorOutcome(..outcome, occurred_at: 0),
      )
      <> "|"
      <> binding.authorization_id
      <> "|"
      <> binding.activation_ids_json
      <> "|"
      <> binding.domain_id
      <> "|"
      <> binding.concern_id
  }
  let payload_hash =
    crypto.hash(crypto.Sha256, <<payload:utf8>>) |> bit_array.base16_encode
  in_transaction(conn, "monitor outcome transaction", fn() {
    use existing <- result.try(
      sqlight.query(
        "SELECT payload_hash, result_json FROM attention_monitor_outcomes WHERE outcome_id = ?",
        on: conn,
        with: [sqlight.text(outcome.outcome_id)],
        expecting: {
          use hash <- decode.field(0, decode.string)
          use receipt <- decode.field(1, decode.string)
          decode.success(#(hash, receipt))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to load monitor outcome receipt: " <> string.inspect(error)
      }),
    )
    case existing {
      [#(hash, receipt)] if hash == payload_hash ->
        operating_contracts.decode_monitor_outcome_receipt(receipt)
      [#(_, _)] -> Error("idempotency_conflict")
      [] -> {
        let effective_outcome = case route {
          Some(_) ->
            operating_contracts.MonitorOutcome(
              ..outcome,
              occurred_at: time.now_ms(),
            )
          None -> outcome
        }
        use _ <- result.try(validate_monitor_outcome_boundary(effective_outcome))
        apply_new_monitor_outcome(conn, effective_outcome, payload_hash, route)
      }
      _ -> Error("Duplicate monitor outcome receipt")
    }
  })
}

fn validate_monitor_outcome_boundary(
  outcome: operating_contracts.MonitorOutcome,
) -> Result(Nil, String) {
  let grants = list.sort(outcome.authority_grants, by: string.compare)
  use _ <- result.try(
    case
      outcome.schema_version == 1
      && string.trim(outcome.outcome_id) != ""
      && string.trim(outcome.queue_id) != ""
      && string.trim(outcome.lease_token) != ""
      && string.trim(outcome.monitor_id) != ""
      && valid_monitor_ref(outcome.codex_task_ref, "task")
      && valid_monitor_ref(outcome.codex_conversation_ref, "conversation")
      && valid_monitor_ref(outcome.codex_turn_ref, "turn")
    {
      True -> Ok(Nil)
      False -> Error("invalid_monitor_outcome")
    },
  )
  case outcome.disposition, outcome.defer_until, grants {
    "acknowledge", None, ["attention.acknowledge"] -> Ok(Nil)
    "defer", Some(at), ["attention.defer"] if at > outcome.occurred_at ->
      Ok(Nil)
    _, _, _ -> Error("authority_denied_or_invalid_monitor_outcome")
  }
}

fn valid_monitor_ref(value: Option(String), kind: String) -> Bool {
  case value {
    None -> True
    Some(reference) ->
      operating_contracts.valid_codex_reference(reference, kind)
  }
}

fn apply_new_monitor_outcome(
  conn: sqlight.Connection,
  outcome: operating_contracts.MonitorOutcome,
  payload_hash: String,
  route: Option(MonitorRoute),
) -> Result(operating_contracts.MonitorOutcomeReceipt, String) {
  use rows <- result.try(select_monitor_outcome_lease(conn, outcome, route))
  use row <- result.try(case rows {
    [row] -> Ok(row)
    [] -> Error("lease_owner_mismatch_or_inactive")
    _ -> Error("Duplicate active monitor lease")
  })
  let #(queue_id, before_version, evidence_json, _) = row
  let #(state, action, available_at) = case outcome.disposition {
    "acknowledge" -> #(
      "acknowledged",
      "attention.monitor_acknowledged",
      outcome.occurred_at,
    )
    "defer" -> #(
      "deferred",
      "attention.monitor_deferred",
      outcome.defer_until |> option.unwrap(outcome.occurred_at),
    )
    _ -> #("", "", outcome.occurred_at)
  }
  use _ <- result.try(case state == "" {
    True -> Error("invalid_monitor_disposition")
    False -> Ok(Nil)
  })
  use _ <- result.try(
    sqlight.query(
      "UPDATE attention_delivery_attempts SET phase = 'succeeded', updated_at_ms = ? WHERE lease_token = ? AND phase = 'intent'",
      on: conn,
      with: [
        sqlight.int(outcome.occurred_at),
        sqlight.text(outcome.lease_token),
      ],
      expecting: decode.success(Nil),
    )
    |> result.map_error(fn(error) {
      "Failed to complete monitor attempt: " <> string.inspect(error)
    }),
  )
  use _ <- result.try(
    sqlight.query(
      "UPDATE attention_queue SET state = ?, available_at_ms = ?, lease_owner = NULL, lease_expires_at_ms = NULL, updated_at_ms = ?, version = version + 1 WHERE queue_id = ? AND state = 'leased'",
      on: conn,
      with: [
        sqlight.text(state),
        sqlight.int(available_at),
        sqlight.int(outcome.occurred_at),
        sqlight.text(queue_id),
      ],
      expecting: decode.success(Nil),
    )
    |> result.map_error(fn(error) {
      "Failed to apply monitor outcome: " <> string.inspect(error)
    }),
  )
  let receipt =
    operating_contracts.MonitorOutcomeReceipt(
      schema_version: 1,
      outcome_id: outcome.outcome_id,
      queue_id:,
      disposition: outcome.disposition,
      state:,
      version: before_version + 1,
      audit_action: action,
    )
  let receipt_json = operating_contracts.encode_monitor_outcome_receipt(receipt)
  let grants_json =
    json.array(outcome.authority_grants, of: json.string) |> json.to_string
  use _ <- result.try(
    sqlight.query(
      "INSERT INTO attention_monitor_outcomes (outcome_id, payload_hash, queue_id, lease_token, monitor_id, disposition, defer_until_ms, codex_task_ref, codex_conversation_ref, codex_turn_ref, authority_grants_json, result_json, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      on: conn,
      with: [
        sqlight.text(outcome.outcome_id),
        sqlight.text(payload_hash),
        sqlight.text(queue_id),
        sqlight.text(outcome.lease_token),
        sqlight.text(outcome.monitor_id),
        sqlight.text(outcome.disposition),
        sqlight.nullable(sqlight.int, outcome.defer_until),
        sqlight.nullable(sqlight.text, outcome.codex_task_ref),
        sqlight.nullable(sqlight.text, outcome.codex_conversation_ref),
        sqlight.nullable(sqlight.text, outcome.codex_turn_ref),
        sqlight.text(grants_json),
        sqlight.text(receipt_json),
        sqlight.int(outcome.occurred_at),
      ],
      expecting: decode.success(Nil),
    )
    |> result.map_error(fn(error) {
      "Failed to store monitor outcome receipt: " <> string.inspect(error)
    }),
  )
  let evidence_refs =
    json.parse(evidence_json, decode.list(decode.string)) |> result.unwrap([])
  use _ <- result.try(append_attention_audit(
    conn,
    queue_id,
    action,
    Some(before_version),
    Some(before_version + 1),
    evidence_refs,
    case route {
      Some(binding) -> Some(binding.authorization_id)
      None ->
        Some(
          "monitor:"
          <> outcome.monitor_id
          <> ":"
          <> string.join(outcome.authority_grants, ","),
        )
    },
    "succeeded",
    None,
    outcome.occurred_at,
    outcome.monitor_id,
  ))
  Ok(receipt)
}

fn select_monitor_outcome_lease(
  conn: sqlight.Connection,
  outcome: operating_contracts.MonitorOutcome,
  route: Option(MonitorRoute),
) -> Result(List(#(String, Int, String, String)), String) {
  let base_values = [
    sqlight.text(outcome.queue_id),
    sqlight.text(outcome.monitor_id),
    sqlight.int(outcome.occurred_at),
    sqlight.text(outcome.lease_token),
  ]
  let #(statement, values) = case route {
    None -> #(
      "SELECT q.queue_id, q.version, q.event_refs_json, a.lease_owner FROM attention_queue q JOIN attention_delivery_attempts a ON a.queue_id = q.queue_id WHERE q.queue_id = ? AND q.delivery_owner = 'codex' AND q.state = 'leased' AND q.lease_owner = ? AND q.lease_expires_at_ms >= ? AND a.lease_token = ? AND a.phase = 'intent' AND a.attempt_number = q.attempt_count LIMIT 1",
      base_values,
    )
    Some(binding) -> #(
      "SELECT q.queue_id, q.version, q.event_refs_json, a.lease_owner FROM attention_queue q JOIN attention_delivery_attempts a ON a.queue_id = q.queue_id WHERE q.queue_id = ? AND q.schema_version = 2 AND q.delivery_owner = 'codex' AND q.delivery_target = 'codex_monitor' AND q.state = 'leased' AND q.lease_owner = ? AND q.lease_expires_at_ms >= ? AND a.lease_token = ? AND a.phase = 'intent' AND a.attempt_number = q.attempt_count AND q.route_authorization_id = ? AND q.route_activation_ids_json = ? AND q.domain_id = ? AND q.concern_id = ? AND EXISTS (SELECT 1 FROM canary_authorizations au WHERE au.authorization_id = q.route_authorization_id AND au.starts_at_ms <= ? AND au.ends_at_ms > ?) LIMIT 1",
      list.append(base_values, [
        sqlight.text(binding.authorization_id),
        sqlight.text(binding.activation_ids_json),
        sqlight.text(binding.domain_id),
        sqlight.text(binding.concern_id),
        sqlight.int(outcome.occurred_at),
        sqlight.int(outcome.occurred_at),
      ]),
    )
  }
  sqlight.query(statement, on: conn, with: values, expecting: {
    use queue_id <- decode.field(0, decode.string)
    use version <- decode.field(1, decode.int)
    use evidence_json <- decode.field(2, decode.string)
    use lease_owner <- decode.field(3, decode.string)
    decode.success(#(queue_id, version, evidence_json, lease_owner))
  })
  |> result.map_error(fn(error) {
    "Failed to validate monitor outcome lease: " <> string.inspect(error)
  })
}

fn do_acknowledge_attention(
  conn: sqlight.Connection,
  queue_id: String,
  actor_id: String,
  now: Int,
) -> Result(Nil, String) {
  in_transaction(conn, "attention acknowledgement transaction", fn() {
    use item <- result.try(do_get_attention(conn, queue_id))
    use rows <- result.try(
      sqlight.query(
        "UPDATE attention_queue SET state = 'acknowledged', updated_at_ms = ?, version = version + 1 WHERE queue_id = ? AND state = 'delivered' RETURNING queue_id",
        on: conn,
        with: [sqlight.int(now), sqlight.text(queue_id)],
        expecting: decode.at([0], decode.string),
      )
      |> result.map_error(fn(error) {
        "Failed to acknowledge attention: " <> string.inspect(error)
      }),
    )
    case rows {
      [_] ->
        append_attention_audit(
          conn,
          queue_id,
          "attention.acknowledged",
          Some(item.version),
          Some(item.version + 1),
          item.event_refs,
          item.authority_request,
          "succeeded",
          None,
          now,
          actor_id,
        )
        |> result.map(fn(_) { Nil })
      [] -> Error("Attention item is not delivered: " <> queue_id)
      _ -> Error("Unexpected attention acknowledgement result")
    }
  })
}

fn do_list_attention_attempts(
  conn: sqlight.Connection,
  queue_id: String,
) -> Result(List(attention_queue.DeliveryAttempt), String) {
  sqlight.query(
    "SELECT attempt_id, queue_id, attempt_number, lease_owner, lease_token, lease_expires_at_ms, phase, external_receipts_json, error, created_at_ms, updated_at_ms FROM attention_delivery_attempts WHERE queue_id = ? ORDER BY attempt_number",
    on: conn,
    with: [sqlight.text(queue_id)],
    expecting: attention_attempt_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to list attention attempts: " <> string.inspect(error)
  })
}

fn attention_attempt_decoder() -> decode.Decoder(
  attention_queue.DeliveryAttempt,
) {
  use attempt_id <- decode.field(0, decode.int)
  use queue_id <- decode.field(1, decode.string)
  use attempt_number <- decode.field(2, decode.int)
  use lease_owner <- decode.field(3, decode.string)
  use lease_token <- decode.field(4, decode.string)
  use lease_expires_at <- decode.field(5, decode.int)
  use phase <- decode.field(6, decode.string)
  use receipts_json <- decode.field(7, decode.string)
  use error <- decode.field(8, decode.string)
  use created_at <- decode.field(9, decode.int)
  use updated_at <- decode.field(10, decode.int)
  case json.parse(receipts_json, decode.list(decode.string)) {
    Ok(external_receipts) ->
      decode.success(attention_queue.DeliveryAttempt(
        attempt_id:,
        queue_id:,
        attempt_number:,
        lease_owner:,
        lease_token:,
        lease_expires_at:,
        phase:,
        external_receipts:,
        error:,
        created_at:,
        updated_at:,
      ))
    Error(_) ->
      decode.failure(
        attention_queue.DeliveryAttempt(
          attempt_id: 0,
          queue_id: "",
          attempt_number: 0,
          lease_owner: "",
          lease_token: "",
          lease_expires_at: 0,
          phase: "failed",
          external_receipts: [],
          error: "",
          created_at: 0,
          updated_at: 0,
        ),
        expected: "attention receipt JSON",
      )
  }
}

fn append_attention_audit(
  conn: sqlight.Connection,
  queue_id: String,
  action: String,
  before_version: Option(Int),
  after_version: Option(Int),
  evidence_refs: List(String),
  authority_ref: Option(String),
  result_value: String,
  error_code: Option(String),
  occurred_at: Int,
  actor_id: String,
) -> Result(String, String) {
  do_append_operational_audit(
    conn,
    operational_audit.Record(
      schema_version: 1,
      audit_id: "",
      record_type: "state_transition",
      actor: actor_id,
      source: "attention_queue",
      action:,
      target_type: "attention_queue",
      target_id: queue_id,
      before_version:,
      after_version:,
      idempotency_key: Some(queue_id),
      evidence_refs:,
      proof_refs: [],
      authority_ref:,
      result: result_value,
      error_code:,
      occurred_at:,
    ),
  )
}

fn do_create_canary_preparation_authorization(
  conn: sqlight.Connection,
  authorization: operating_contracts.CanaryPreparationAuthorizationV1,
) -> Result(StoredCanaryPreparationAuthorization, String) {
  let canonical_json =
    operating_contracts.encode_canary_preparation_authorization(authorization)
  use _ <- result.try(
    operating_contracts.decode_canary_preparation_authorization(canonical_json),
  )
  let payload_hash = canary_payload_hash(canonical_json)
  let created_at_ms = time.now_ms()
  use _ <- result.try(case authorization.expires_at_ms > created_at_ms {
    True -> Ok(Nil)
    False -> Error("preparation_authorization_expired")
  })
  in_transaction(conn, "canary preparation authorization", fn() {
    use existing <- result.try(do_get_canary_preparation_authorization(
      conn,
      authorization.authorization_id,
    ))
    case existing {
      Some(stored) ->
        case stored.payload_hash == payload_hash {
          True -> Ok(stored)
          False -> Error("idempotency_conflict")
        }
      None -> {
        use _ <- result.try(
          sqlight.query(
            "INSERT INTO canary_preparation_authorizations (authorization_id, schema_version, canary_id, canonical_json, payload_hash, expires_at_ms, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?)",
            on: conn,
            with: [
              sqlight.text(authorization.authorization_id),
              sqlight.int(authorization.schema_version),
              sqlight.text(authorization.canary_id),
              sqlight.text(canonical_json),
              sqlight.text(payload_hash),
              sqlight.int(authorization.expires_at_ms),
              sqlight.int(created_at_ms),
            ],
            expecting: decode.success(Nil),
          )
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(error) {
            "Failed to store preparation authorization: "
            <> string.inspect(error)
          }),
        )
        use _ <- result.try(do_append_operational_audit(
          conn,
          operational_audit.Record(
            schema_version: 1,
            audit_id: "canary-preparation:" <> authorization.authorization_id,
            record_type: "authorization",
            actor: "aura",
            source: "canary_authorization",
            action: "canary.preparation_authorization.created",
            target_type: "canary_preparation_authorization",
            target_id: authorization.authorization_id,
            before_version: None,
            after_version: Some(1),
            idempotency_key: Some(authorization.authorization_id),
            evidence_refs: [],
            proof_refs: [authorization.oauth_client_ref],
            authority_ref: Some(authorization.authorized_by_ref),
            result: "succeeded",
            error_code: None,
            occurred_at: created_at_ms,
          ),
        ))
        Ok(StoredCanaryPreparationAuthorization(
          authorization:,
          payload_hash:,
          created_at_ms:,
        ))
      }
    }
  })
}

fn do_get_canary_preparation_authorization(
  conn: sqlight.Connection,
  authorization_id: String,
) -> Result(Option(StoredCanaryPreparationAuthorization), String) {
  sqlight.query(
    "SELECT canonical_json, payload_hash, created_at_ms FROM canary_preparation_authorizations WHERE authorization_id = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(authorization_id)],
    expecting: preparation_authorization_row_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to load preparation authorization: " <> string.inspect(error)
  })
  |> result.map(fn(rows) {
    case rows {
      [] -> None
      [stored, ..] -> Some(stored)
    }
  })
}

fn preparation_authorization_row_decoder() -> decode.Decoder(
  StoredCanaryPreparationAuthorization,
) {
  use canonical_json <- decode.field(0, decode.string)
  use payload_hash <- decode.field(1, decode.string)
  use created_at_ms <- decode.field(2, decode.int)
  case
    operating_contracts.decode_canary_preparation_authorization(canonical_json)
  {
    Ok(authorization) ->
      decode.success(StoredCanaryPreparationAuthorization(
        authorization:,
        payload_hash:,
        created_at_ms:,
      ))
    Error(_) ->
      decode.failure(
        invalid_stored_preparation_authorization(),
        expected: "valid preparation authorization",
      )
  }
}

fn do_create_canary_authorization(
  conn: sqlight.Connection,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> Result(StoredCanaryAuthorization, String) {
  let canonical_json =
    operating_contracts.encode_canary_authorization(authorization)
  use _ <- result.try(operating_contracts.decode_canary_authorization(
    canonical_json,
  ))
  let payload_hash = canary_payload_hash(canonical_json)
  let created_at_ms = time.now_ms()
  use _ <- result.try(case authorization.ends_at_ms > created_at_ms {
    True -> Ok(Nil)
    False -> Error("canary_authorization_expired")
  })
  in_transaction(conn, "canary authorization", fn() {
    use existing <- result.try(do_get_canary_authorization(
      conn,
      authorization.authorization_id,
    ))
    case existing {
      Some(stored) ->
        case stored.payload_hash == payload_hash {
          True -> Ok(stored)
          False -> Error("idempotency_conflict")
        }
      None -> {
        use preparation <- result.try(do_get_canary_preparation_authorization(
          conn,
          authorization.preparation_authorization_id,
        ))
        use stored_preparation <- result.try(case preparation {
          Some(stored) -> Ok(stored)
          None -> Error("preparation_authorization_not_found")
        })
        use _ <- result.try(
          case stored_preparation.authorization.expires_at_ms > created_at_ms {
            True -> Ok(Nil)
            False -> Error("preparation_authorization_expired")
          },
        )
        use _ <- result.try(
          case
            preparation_matches_authorization(
              stored_preparation.authorization,
              authorization,
            )
          {
            True -> Ok(Nil)
            False -> Error("preparation_authorization_mismatch")
          },
        )
        use _ <- result.try(
          authorization.connectors
          |> list.try_each(fn(connector) {
            validate_final_connector_proofs(
              conn,
              stored_preparation.authorization,
              connector,
            )
          }),
        )
        use _ <- result.try(
          sqlight.query(
            "INSERT INTO canary_authorizations (authorization_id, preparation_authorization_id, schema_version, canary_id, canonical_json, payload_hash, monitor_capability_hash, starts_at_ms, ends_at_ms, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            on: conn,
            with: [
              sqlight.text(authorization.authorization_id),
              sqlight.text(authorization.preparation_authorization_id),
              sqlight.int(authorization.schema_version),
              sqlight.text(authorization.canary_id),
              sqlight.text(canonical_json),
              sqlight.text(payload_hash),
              sqlight.text(authorization.monitor_capability_hash),
              sqlight.int(authorization.starts_at_ms),
              sqlight.int(authorization.ends_at_ms),
              sqlight.int(created_at_ms),
            ],
            expecting: decode.success(Nil),
          )
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(error) {
            "Failed to store canary authorization: " <> string.inspect(error)
          }),
        )
        use _ <- result.try(do_append_operational_audit(
          conn,
          operational_audit.Record(
            schema_version: 1,
            audit_id: "canary-authorization:" <> authorization.authorization_id,
            record_type: "authorization",
            actor: "aura",
            source: "canary_authorization",
            action: "canary.authorization.created",
            target_type: "canary_authorization",
            target_id: authorization.authorization_id,
            before_version: None,
            after_version: Some(1),
            idempotency_key: Some(authorization.authorization_id),
            evidence_refs: [],
            proof_refs: [authorization.preparation_authorization_id],
            authority_ref: Some(authorization.authorized_by_ref),
            result: "succeeded",
            error_code: None,
            occurred_at: created_at_ms,
          ),
        ))
        Ok(StoredCanaryAuthorization(
          authorization:,
          payload_hash:,
          created_at_ms:,
        ))
      }
    }
  })
}

fn validate_final_connector_proofs(
  conn: sqlight.Connection,
  preparation: operating_contracts.CanaryPreparationAuthorizationV1,
  connector: operating_contracts.AuthorizedConnectorV1,
) -> Result(Nil, String) {
  use oauth <- result.try(load_google_effect_by_proof(
    conn,
    connector.oauth_proof_ref,
  ))
  use identity <- result.try(load_google_effect_by_proof(
    conn,
    connector.identity_proof_ref,
  ))
  use preparation_connector <- result.try(
    list.find(preparation.connectors, fn(value) {
      value.connector_id == connector.connector_id
    })
    |> result.map_error(fn(_) { "canary_connector_proof_mismatch" }),
  )
  use _ <- result.try(
    validate_registered_client_binding(
      conn,
      connector.connector_id,
      oauth.oauth_client_ref,
      oauth.oauth_client_hash,
      oauth.client_set_ref,
      oauth.client_set_hash,
    )
    |> result.map_error(fn(_) { "canary_connector_proof_mismatch" }),
  )
  case
    oauth.phase == "succeeded"
    && oauth.effect_kind == "oauth_exchange"
    && identity.phase == "succeeded"
    && identity.effect_kind == "identity_read"
    && oauth.preparation_authorization_id == preparation.authorization_id
    && identity.preparation_authorization_id == preparation.authorization_id
    && oauth.connector_id == connector.connector_id
    && identity.connector_id == connector.connector_id
    && oauth.configuration_ref == connector.configuration_ref
    && identity.configuration_ref == connector.configuration_ref
    && oauth.configuration_hash == connector.configuration_hash
    && identity.configuration_hash == connector.configuration_hash
    && oauth.oauth_scope == connector.oauth_scope
    && identity.oauth_scope == connector.oauth_scope
    && oauth.oauth_client_ref == identity.oauth_client_ref
    && oauth.oauth_client_hash == identity.oauth_client_hash
    && oauth.client_set_ref == preparation.oauth_client_ref
    && identity.client_set_ref == preparation.oauth_client_ref
    && oauth.client_set_hash == preparation.oauth_client_hash
    && identity.client_set_hash == preparation.oauth_client_hash
    && identity.account_fingerprint == connector.account_fingerprint
    && preparation_connector.configuration_ref == connector.configuration_ref
    && preparation_connector.oauth_scope == connector.oauth_scope
  {
    True -> Ok(Nil)
    False -> Error("canary_connector_proof_mismatch")
  }
}

fn load_google_effect_by_proof(
  conn: sqlight.Connection,
  proof_ref: String,
) -> Result(GoogleExternalEffect, String) {
  sqlight.query(
    "SELECT effect_id, preparation_authorization_id, authorization_id, activation_id, configuration_ref, configuration_hash, connector_id, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, effect_kind, logical_effect_key, attempt_number, request_hash, phase, proof_ref, oauth_scope, account_fingerprint, result_hash, error_class FROM connector_external_effects WHERE proof_ref = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(proof_ref)],
    expecting: google_external_effect_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to resolve canary connector proof: " <> string.inspect(error)
  })
  |> result.try(fn(rows) {
    case rows {
      [effect] -> Ok(effect)
      _ -> Error("canary_connector_proof_not_found")
    }
  })
}

fn preparation_matches_authorization(
  preparation: operating_contracts.CanaryPreparationAuthorizationV1,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> Bool {
  preparation.canary_id == authorization.canary_id
  && list.length(preparation.connectors)
  == list.length(authorization.connectors)
  && list.all(preparation.connectors, fn(preparation_connector) {
    list.any(authorization.connectors, fn(authorized_connector) {
      preparation_connector.connector_id == authorized_connector.connector_id
      && preparation_connector.configuration_ref
      == authorized_connector.configuration_ref
      && preparation_connector.oauth_scope == authorized_connector.oauth_scope
    })
  })
}

fn do_get_canary_authorization(
  conn: sqlight.Connection,
  authorization_id: String,
) -> Result(Option(StoredCanaryAuthorization), String) {
  sqlight.query(
    "SELECT canonical_json, payload_hash, created_at_ms FROM canary_authorizations WHERE authorization_id = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(authorization_id)],
    expecting: canary_authorization_row_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to load canary authorization: " <> string.inspect(error)
  })
  |> result.map(fn(rows) {
    case rows {
      [] -> None
      [stored, ..] -> Some(stored)
    }
  })
}

fn canary_authorization_row_decoder() -> decode.Decoder(
  StoredCanaryAuthorization,
) {
  use canonical_json <- decode.field(0, decode.string)
  use payload_hash <- decode.field(1, decode.string)
  use created_at_ms <- decode.field(2, decode.int)
  case operating_contracts.decode_canary_authorization(canonical_json) {
    Ok(authorization) ->
      decode.success(StoredCanaryAuthorization(
        authorization:,
        payload_hash:,
        created_at_ms:,
      ))
    Error(_) ->
      decode.failure(
        invalid_stored_canary_authorization(),
        expected: "valid canary authorization",
      )
  }
}

fn invalid_stored_preparation_authorization() -> StoredCanaryPreparationAuthorization {
  StoredCanaryPreparationAuthorization(
    authorization: operating_contracts.CanaryPreparationAuthorizationV1(
      schema_version: 0,
      authorization_id: "",
      canary_id: "",
      oauth_client_ref: "",
      oauth_client_hash: "",
      connectors: [],
      grants: [],
      expires_at_ms: 0,
      authorized_by_ref: "",
    ),
    payload_hash: "",
    created_at_ms: 0,
  )
}

fn invalid_stored_canary_authorization() -> StoredCanaryAuthorization {
  StoredCanaryAuthorization(
    authorization: operating_contracts.CanaryAuthorizationV1(
      schema_version: 0,
      authorization_id: "",
      preparation_authorization_id: "",
      canary_id: "",
      domain_id: "",
      concern_id: "",
      policy_refs: [],
      connectors: [],
      activation_grants: [],
      monitor_id: "",
      monitor_capability_hash: "",
      monitor_runtime_ref: "",
      monitor_prompt_hash: "",
      monitor_interval_ms: 0,
      monitor_grants: [],
      attention_owner: "",
      attention_target: "",
      discord_delivery_allowed: False,
      starts_at_ms: 0,
      ends_at_ms: 0,
      metric_ids: [],
      metric_review_owner_ref: "",
      authorized_by_ref: "",
      rollback_owner_ref: "",
    ),
    payload_hash: "",
    created_at_ms: 0,
  )
}

fn do_get_effective_connector_activation(
  conn: sqlight.Connection,
  activation_id: String,
  authorization_id: String,
) -> Result(Option(operating_contracts.ConnectorActivationV1), String) {
  let now_ms = time.now_ms()
  sqlight.query(
    "SELECT ca.activation_id, ca.authorization_id, ca.connector_id, ca.domain_id, ca.concern_id, ca.configuration_ref, ca.oauth_scope, ca.state, ca.version, ca.updated_at_ms FROM connector_activations AS ca JOIN canary_authorizations AS a ON a.authorization_id = ca.authorization_id WHERE ca.activation_id = ? AND ca.authorization_id = ? AND ca.state = 'enabled' AND a.starts_at_ms <= ? AND a.ends_at_ms > ? LIMIT 1",
    on: conn,
    with: [
      sqlight.text(activation_id),
      sqlight.text(authorization_id),
      sqlight.int(now_ms),
      sqlight.int(now_ms),
    ],
    expecting: connector_activation_row_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to load effective connector activation: " <> string.inspect(error)
  })
  |> result.map(fn(rows) {
    case rows {
      [] -> None
      [activation, ..] -> Some(activation)
    }
  })
}

fn do_list_effective_connector_activations(
  conn: sqlight.Connection,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  let now_ms = time.now_ms()
  sqlight.query(
    "SELECT ca.activation_id, ca.authorization_id, ca.connector_id, ca.domain_id, ca.concern_id, ca.configuration_ref, ca.oauth_scope, ca.state, ca.version, ca.updated_at_ms FROM connector_activations AS ca JOIN canary_authorizations AS a ON a.authorization_id = ca.authorization_id WHERE ca.state = 'enabled' AND a.starts_at_ms <= ? AND a.ends_at_ms > ? ORDER BY ca.activation_id",
    on: conn,
    with: [sqlight.int(now_ms), sqlight.int(now_ms)],
    expecting: connector_activation_row_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to list effective connector activations: " <> string.inspect(error)
  })
}

fn do_create_google_oauth_session(
  conn: sqlight.Connection,
  session: GoogleOAuthSession,
) -> Result(GoogleOAuthSession, String) {
  let now_ms = time.now_ms()
  use _ <- result.try(validate_google_oauth_session(session, now_ms))
  in_transaction(conn, "Google OAuth session creation", fn() {
    use existing <- result.try(load_google_oauth_session(
      conn,
      session.session_ref,
    ))
    case existing {
      Some(stored) ->
        case stored == session {
          True -> Ok(stored)
          False -> Error("idempotency_conflict")
        }
      None -> {
        use preparation <- result.try(load_effective_preparation(
          conn,
          session.preparation_authorization_id,
          now_ms,
        ))
        use oauth_scope <- result.try(google_readonly_scope(
          session.connector_id,
        ))
        use _ <- result.try(validate_preparation_connector(
          preparation,
          session.connector_id,
          session.configuration_ref,
          session.client_set_ref,
          session.client_set_hash,
          oauth_scope,
        ))
        use _ <- result.try(validate_registered_client_binding(
          conn,
          session.connector_id,
          session.oauth_client_ref,
          session.oauth_client_hash,
          session.client_set_ref,
          session.client_set_hash,
        ))
        use _ <- result.try(ensure_no_enabled_connector_activation(
          conn,
          session.connector_id,
          session.configuration_ref,
        ))
        use _ <- result.try(
          sqlight.query(
            "INSERT INTO connector_oauth_sessions (session_ref, connector_id, preparation_authorization_id, configuration_ref, configuration_hash, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, state_hash, pkce_challenge, redirect_uri, phase, expires_at_ms, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'waiting', ?, ?, ?)",
            on: conn,
            with: [
              sqlight.text(session.session_ref),
              sqlight.text(session.connector_id),
              sqlight.text(session.preparation_authorization_id),
              sqlight.text(session.configuration_ref),
              sqlight.text(session.configuration_hash),
              sqlight.text(session.oauth_client_ref),
              sqlight.text(session.oauth_client_hash),
              sqlight.text(session.client_set_ref),
              sqlight.text(session.client_set_hash),
              sqlight.text(session.state_hash),
              sqlight.text(session.pkce_challenge),
              sqlight.text(session.redirect_uri),
              sqlight.int(session.expires_at_ms),
              sqlight.int(now_ms),
              sqlight.int(now_ms),
            ],
            expecting: decode.success(Nil),
          )
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(error) {
            "Failed to create Google OAuth session: " <> string.inspect(error)
          }),
        )
        use _ <- result.try(append_google_execution_audit(
          conn,
          "oauth-session:" <> session.session_ref <> ":waiting",
          "google.oauth.session.created",
          "connector_oauth_session",
          session.session_ref,
          session.preparation_authorization_id,
          None,
          now_ms,
        ))
        Ok(session)
      }
    }
  })
}

fn ensure_no_enabled_connector_activation(
  conn: sqlight.Connection,
  connector_id: String,
  configuration_ref: String,
) -> Result(Nil, String) {
  sqlight.query(
    "SELECT COUNT(*) FROM connector_activations WHERE connector_id = ? AND configuration_ref = ? AND state = 'enabled'",
    on: conn,
    with: [sqlight.text(connector_id), sqlight.text(configuration_ref)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(error) {
    "Failed to inspect connector activation state: " <> string.inspect(error)
  })
  |> result.try(fn(rows) {
    case rows {
      [0] -> Ok(Nil)
      _ -> Error("connector_activation_already_enabled")
    }
  })
}

fn do_register_google_oauth_client_set(
  conn: sqlight.Connection,
  client_set: GoogleOAuthClientSet,
) -> Result(GoogleOAuthClientSet, String) {
  use _ <- result.try(validate_google_oauth_client_set(client_set))
  let now_ms = time.now_ms()
  in_transaction(conn, "Google OAuth client-set registration", fn() {
    use rows <- result.try(
      sqlight.query(
        "SELECT client_set_ref, client_set_hash, gmail_client_ref, gmail_client_hash, calendar_client_ref, calendar_client_hash FROM connector_oauth_client_sets WHERE client_set_ref = ? LIMIT 1",
        on: conn,
        with: [sqlight.text(client_set.client_set_ref)],
        expecting: google_oauth_client_set_decoder(),
      )
      |> result.map_error(fn(error) {
        "Failed to load Google OAuth client set: " <> string.inspect(error)
      }),
    )
    case rows {
      [stored] ->
        case stored == client_set {
          True -> Ok(stored)
          False -> Error("idempotency_conflict")
        }
      [] -> {
        use _ <- result.try(
          sqlight.query(
            "INSERT INTO connector_oauth_client_sets (client_set_ref, client_set_hash, gmail_client_ref, gmail_client_hash, calendar_client_ref, calendar_client_hash, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?)",
            on: conn,
            with: [
              sqlight.text(client_set.client_set_ref),
              sqlight.text(client_set.client_set_hash),
              sqlight.text(client_set.gmail_client_ref),
              sqlight.text(client_set.gmail_client_hash),
              sqlight.text(client_set.calendar_client_ref),
              sqlight.text(client_set.calendar_client_hash),
              sqlight.int(now_ms),
            ],
            expecting: decode.success(Nil),
          )
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(error) {
            "Failed to register Google OAuth client set: "
            <> string.inspect(error)
          }),
        )
        use _ <- result.try(append_google_execution_audit(
          conn,
          "oauth-client-set:" <> client_set.client_set_ref,
          "google.oauth.client_set.registered",
          "connector_oauth_client_set",
          client_set.client_set_ref,
          client_set.client_set_ref,
          None,
          now_ms,
        ))
        Ok(client_set)
      }
      _ -> Error("google_oauth_client_set_not_unique")
    }
  })
}

fn google_oauth_client_set_decoder() -> decode.Decoder(GoogleOAuthClientSet) {
  use client_set_ref <- decode.field(0, decode.string)
  use client_set_hash <- decode.field(1, decode.string)
  use gmail_client_ref <- decode.field(2, decode.string)
  use gmail_client_hash <- decode.field(3, decode.string)
  use calendar_client_ref <- decode.field(4, decode.string)
  use calendar_client_hash <- decode.field(5, decode.string)
  decode.success(GoogleOAuthClientSet(
    client_set_ref:,
    client_set_hash:,
    gmail_client_ref:,
    gmail_client_hash:,
    calendar_client_ref:,
    calendar_client_hash:,
  ))
}

fn do_claim_google_oauth_session(
  conn: sqlight.Connection,
  session_ref: String,
  accept_before_ms: Int,
) -> Result(GoogleOAuthSession, String) {
  let now_ms = time.now_ms()
  use _ <- result.try(case accept_before_ms >= now_ms {
    True -> Ok(Nil)
    False -> Error("oauth_callback_deadline_expired")
  })
  in_transaction(conn, "Google OAuth session claim", fn() {
    use stored <- result.try(load_google_oauth_session(conn, session_ref))
    use current <- result.try(case stored {
      Some(value) -> Ok(value)
      None -> Error("oauth_session_not_found")
    })
    use preparation <- result.try(load_effective_preparation(
      conn,
      current.preparation_authorization_id,
      now_ms,
    ))
    use oauth_scope <- result.try(google_readonly_scope(current.connector_id))
    use _ <- result.try(validate_preparation_connector(
      preparation,
      current.connector_id,
      current.configuration_ref,
      current.client_set_ref,
      current.client_set_hash,
      oauth_scope,
    ))
    use _ <- result.try(validate_registered_client_binding(
      conn,
      current.connector_id,
      current.oauth_client_ref,
      current.oauth_client_hash,
      current.client_set_ref,
      current.client_set_hash,
    ))
    use rows <- result.try(
      sqlight.query(
        "UPDATE connector_oauth_sessions SET phase = 'callback_claimed', updated_at_ms = ? WHERE session_ref = ? AND phase = 'waiting' AND expires_at_ms > ? RETURNING session_ref, connector_id, preparation_authorization_id, configuration_ref, configuration_hash, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, state_hash, pkce_challenge, redirect_uri, phase, expires_at_ms",
        on: conn,
        with: [
          sqlight.int(now_ms),
          sqlight.text(session_ref),
          sqlight.int(now_ms),
        ],
        expecting: google_oauth_session_decoder(),
      )
      |> result.map_error(fn(error) {
        "Failed to claim Google OAuth session: " <> string.inspect(error)
      }),
    )
    case rows {
      [session] -> {
        use _ <- result.try(append_google_execution_audit(
          conn,
          "oauth-session:" <> session_ref <> ":callback_claimed",
          "google.oauth.session.callback_claimed",
          "connector_oauth_session",
          session_ref,
          session.preparation_authorization_id,
          None,
          now_ms,
        ))
        Ok(session)
      }
      _ -> Error("oauth_session_not_waiting")
    }
  })
}

fn do_expire_google_oauth_sessions(
  conn: sqlight.Connection,
) -> Result(Int, String) {
  let now_ms = time.now_ms()
  in_transaction(conn, "Google OAuth session expiry", fn() {
    use rows <- result.try(
      sqlight.query(
        "SELECT session_ref, connector_id, preparation_authorization_id, configuration_ref, configuration_hash, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, state_hash, pkce_challenge, redirect_uri, phase, expires_at_ms FROM connector_oauth_sessions WHERE phase IN ('waiting', 'callback_claimed') ORDER BY session_ref",
        on: conn,
        with: [],
        expecting: google_oauth_session_decoder(),
      )
      |> result.map_error(fn(error) {
        "Failed to load expired Google OAuth sessions: "
        <> string.inspect(error)
      }),
    )
    use _ <- result.try(
      rows
      |> list.try_each(fn(session) {
        case session.phase {
          "callback_claimed" ->
            recover_claimed_google_oauth_session(conn, session, now_ms)
            |> result.map(fn(_) { Nil })
          _ ->
            finish_recovered_google_oauth_session(
              conn,
              session,
              "expired",
              "session_expired",
              now_ms,
            )
            |> result.map(fn(_) { Nil })
        }
      }),
    )
    Ok(list.length(rows))
  })
}

fn do_recover_google_oauth_session(
  conn: sqlight.Connection,
  session_ref: String,
) -> Result(GoogleOAuthSession, String) {
  let now_ms = time.now_ms()
  in_transaction(conn, "Google OAuth session recovery", fn() {
    use stored <- result.try(load_google_oauth_session(conn, session_ref))
    use session <- result.try(case stored {
      Some(value) -> Ok(value)
      None -> Error("oauth_session_not_found")
    })
    case session.phase {
      "callback_claimed" ->
        recover_claimed_google_oauth_session(conn, session, now_ms)
      "succeeded" | "failed_before_effect" | "effect_unknown" | "expired" ->
        Ok(session)
      _ -> Error("oauth_session_not_claimed")
    }
  })
}

fn recover_claimed_google_oauth_session(
  conn: sqlight.Connection,
  session: GoogleOAuthSession,
  now_ms: Int,
) -> Result(GoogleOAuthSession, String) {
  use intent_count <- result.try(mark_google_oauth_intents_effect_unknown(
    conn,
    session,
    now_ms,
  ))
  let #(phase, error_class) = case intent_count > 0 {
    True -> #("effect_unknown", "callback_transport_unknown")
    False -> #("failed_before_effect", "callback_invalid")
  }
  finish_recovered_google_oauth_session(
    conn,
    session,
    phase,
    error_class,
    now_ms,
  )
}

fn mark_google_oauth_intents_effect_unknown(
  conn: sqlight.Connection,
  session: GoogleOAuthSession,
  now_ms: Int,
) -> Result(Int, String) {
  let session_hash =
    crypto.hash(crypto.Sha256, <<session.session_ref:utf8>>)
    |> bit_array.base16_encode
    |> string.lowercase
  use effects <- result.try(
    sqlight.query(
      "SELECT effect_id, preparation_authorization_id, authorization_id, activation_id, configuration_ref, configuration_hash, connector_id, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, effect_kind, logical_effect_key, attempt_number, request_hash, phase, proof_ref, oauth_scope, account_fingerprint, result_hash, error_class FROM connector_external_effects WHERE phase = 'intent' AND logical_effect_key IN (?, ?) ORDER BY effect_id",
      on: conn,
      with: [
        sqlight.text("oauth:" <> session_hash),
        sqlight.text("identity:" <> session_hash),
      ],
      expecting: google_external_effect_decoder(),
    )
    |> result.map_error(fn(error) {
      "Failed to load unresolved Google effects: " <> string.inspect(error)
    }),
  )
  use _ <- result.try(
    effects
    |> list.try_each(fn(effect) {
      use _ <- result.try(
        sqlight.query(
          "UPDATE connector_external_effects SET phase = 'effect_unknown', error_class = 'transport_after_dispatch', updated_at_ms = ? WHERE effect_id = ? AND phase = 'intent'",
          on: conn,
          with: [sqlight.int(now_ms), sqlight.text(effect.effect_id)],
          expecting: decode.success(Nil),
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(fn(error) {
          "Failed to recover unresolved Google effect: "
          <> string.inspect(error)
        }),
      )
      append_google_execution_audit(
        conn,
        "google-effect:" <> effect.effect_id <> ":effect_unknown",
        "google.external_effect.effect_unknown",
        "connector_external_effect",
        effect.effect_id,
        effect.preparation_authorization_id,
        Some("transport_after_dispatch"),
        now_ms,
      )
    }),
  )
  Ok(list.length(effects))
}

fn finish_recovered_google_oauth_session(
  conn: sqlight.Connection,
  session: GoogleOAuthSession,
  phase: String,
  error_class: String,
  now_ms: Int,
) -> Result(GoogleOAuthSession, String) {
  use rows <- result.try(
    sqlight.query(
      "UPDATE connector_oauth_sessions SET phase = ?, updated_at_ms = ? WHERE session_ref = ? AND phase = ? RETURNING session_ref, connector_id, preparation_authorization_id, configuration_ref, configuration_hash, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, state_hash, pkce_challenge, redirect_uri, phase, expires_at_ms",
      on: conn,
      with: [
        sqlight.text(phase),
        sqlight.int(now_ms),
        sqlight.text(session.session_ref),
        sqlight.text(session.phase),
      ],
      expecting: google_oauth_session_decoder(),
    )
    |> result.map_error(fn(error) {
      "Failed to recover Google OAuth session: " <> string.inspect(error)
    }),
  )
  use recovered <- result.try(case rows {
    [value] -> Ok(value)
    _ -> Error("oauth_session_state_conflict")
  })
  use _ <- result.try(append_google_execution_audit(
    conn,
    "oauth-session:" <> session.session_ref <> ":" <> phase,
    "google.oauth.session." <> phase,
    "connector_oauth_session",
    session.session_ref,
    session.preparation_authorization_id,
    Some(error_class),
    now_ms,
  ))
  Ok(recovered)
}

fn do_finish_google_oauth_session(
  conn: sqlight.Connection,
  session_ref: String,
  phase: String,
  error_class: String,
) -> Result(GoogleOAuthSession, String) {
  use _ <- result.try(
    case
      list.contains(
        ["succeeded", "failed_before_effect", "effect_unknown", "expired"],
        phase,
      )
    {
      True -> Ok(Nil)
      False -> Error("invalid_oauth_session_phase")
    },
  )
  use _ <- result.try(validate_google_oauth_session_outcome(phase, error_class))
  let now_ms = time.now_ms()
  in_transaction(conn, "Google OAuth session finish", fn() {
    use existing <- result.try(load_google_oauth_session(conn, session_ref))
    use session <- result.try(case existing {
      Some(value) -> Ok(value)
      None -> Error("oauth_session_not_found")
    })
    case session.phase == phase {
      True -> Ok(session)
      False -> {
        use _ <- result.try(
          case
            session.phase == "callback_claimed"
            || {
              session.phase == "waiting"
              && list.contains(["expired", "failed_before_effect"], phase)
            }
          {
            True -> Ok(Nil)
            False -> Error("oauth_session_not_claimed")
          },
        )
        use rows <- result.try(
          sqlight.query(
            "UPDATE connector_oauth_sessions SET phase = ?, updated_at_ms = ? WHERE session_ref = ? AND phase = ? RETURNING session_ref, connector_id, preparation_authorization_id, configuration_ref, configuration_hash, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, state_hash, pkce_challenge, redirect_uri, phase, expires_at_ms",
            on: conn,
            with: [
              sqlight.text(phase),
              sqlight.int(now_ms),
              sqlight.text(session_ref),
              sqlight.text(session.phase),
            ],
            expecting: google_oauth_session_decoder(),
          )
          |> result.map_error(fn(error) {
            "Failed to finish Google OAuth session: " <> string.inspect(error)
          }),
        )
        use finished <- result.try(case rows {
          [value] -> Ok(value)
          _ -> Error("oauth_session_state_conflict")
        })
        use _ <- result.try(append_google_execution_audit(
          conn,
          "oauth-session:" <> session_ref <> ":" <> phase,
          "google.oauth.session." <> phase,
          "connector_oauth_session",
          session_ref,
          session.preparation_authorization_id,
          case error_class {
            "" -> None
            value -> Some(value)
          },
          now_ms,
        ))
        Ok(finished)
      }
    }
  })
}

fn validate_google_oauth_session_outcome(
  phase: String,
  error_class: String,
) -> Result(Nil, String) {
  case phase {
    "succeeded" ->
      case error_class == "" {
        True -> Ok(Nil)
        False -> Error("invalid_oauth_session_error_class")
      }
    "expired" ->
      case error_class == "session_expired" {
        True -> Ok(Nil)
        False -> Error("invalid_oauth_session_error_class")
      }
    "failed_before_effect" | "effect_unknown" ->
      case
        list.contains(
          [
            "authorization_denied",
            "callback_invalid",
            "state_mismatch",
            "pkce_mismatch",
            "scope_mismatch",
            "callback_transport_unknown",
          ],
          error_class,
        )
      {
        True -> Ok(Nil)
        False -> Error("invalid_oauth_session_error_class")
      }
    _ -> Error("invalid_oauth_session_error_class")
  }
}

fn do_begin_google_external_effect(
  conn: sqlight.Connection,
  effect: GoogleExternalEffect,
) -> Result(GoogleExternalEffect, String) {
  let now_ms = time.now_ms()
  use _ <- result.try(validate_google_external_effect_intent(effect))
  in_transaction(conn, "Google external effect intent", fn() {
    use existing <- result.try(load_google_external_effect(
      conn,
      effect.effect_id,
    ))
    case existing {
      Some(stored) ->
        case stored == effect {
          True -> Ok(stored)
          False -> Error("idempotency_conflict")
        }
      None -> {
        use preparation <- result.try(load_effective_preparation(
          conn,
          effect.preparation_authorization_id,
          now_ms,
        ))
        use _ <- result.try(validate_preparation_connector(
          preparation,
          effect.connector_id,
          effect.configuration_ref,
          effect.client_set_ref,
          effect.client_set_hash,
          effect.oauth_scope,
        ))
        use _ <- result.try(validate_registered_client_binding(
          conn,
          effect.connector_id,
          effect.oauth_client_ref,
          effect.oauth_client_hash,
          effect.client_set_ref,
          effect.client_set_hash,
        ))
        use _ <- result.try(validate_google_effect_attempt(conn, effect))
        use _ <- result.try(
          sqlight.query(
            "INSERT INTO connector_external_effects (effect_id, preparation_authorization_id, authorization_id, activation_id, configuration_ref, configuration_hash, connector_id, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, effect_kind, logical_effect_key, attempt_number, request_hash, phase, proof_ref, oauth_scope, account_fingerprint, result_hash, error_class, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'intent', NULL, ?, NULL, NULL, NULL, ?, ?)",
            on: conn,
            with: [
              sqlight.text(effect.effect_id),
              sqlight.text(effect.preparation_authorization_id),
              nullable_nonempty_text(effect.authorization_id),
              nullable_nonempty_text(effect.activation_id),
              sqlight.text(effect.configuration_ref),
              sqlight.text(effect.configuration_hash),
              sqlight.text(effect.connector_id),
              sqlight.text(effect.oauth_client_ref),
              sqlight.text(effect.oauth_client_hash),
              sqlight.text(effect.client_set_ref),
              sqlight.text(effect.client_set_hash),
              sqlight.text(effect.effect_kind),
              sqlight.text(effect.logical_effect_key),
              sqlight.int(effect.attempt_number),
              sqlight.text(effect.request_hash),
              sqlight.text(effect.oauth_scope),
              sqlight.int(now_ms),
              sqlight.int(now_ms),
            ],
            expecting: decode.success(Nil),
          )
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(error) {
            "Failed to store Google external effect intent: "
            <> string.inspect(error)
          }),
        )
        use _ <- result.try(append_google_execution_audit(
          conn,
          "google-effect:" <> effect.effect_id <> ":intent",
          "google.external_effect.intent",
          "connector_external_effect",
          effect.effect_id,
          effect.preparation_authorization_id,
          None,
          now_ms,
        ))
        Ok(effect)
      }
    }
  })
}

fn do_finish_google_external_effect(
  conn: sqlight.Connection,
  effect_id: String,
  phase: String,
  proof_ref: String,
  account_fingerprint: String,
  result_hash: String,
  error_class: String,
) -> Result(GoogleExternalEffect, String) {
  use _ <- result.try(validate_google_external_effect_outcome(
    phase,
    proof_ref,
    account_fingerprint,
    result_hash,
    error_class,
  ))
  let now_ms = time.now_ms()
  in_transaction(conn, "Google external effect outcome", fn() {
    use existing <- result.try(load_google_external_effect(conn, effect_id))
    use effect <- result.try(case existing {
      Some(value) -> Ok(value)
      None -> Error("google_external_effect_not_found")
    })
    use _ <- result.try(
      case
        phase == "succeeded"
        && effect.effect_kind == "identity_read"
        && account_fingerprint == ""
      {
        True -> Error("identity_account_fingerprint_required")
        False -> Ok(Nil)
      },
    )
    let requested =
      GoogleExternalEffect(
        ..effect,
        phase:,
        proof_ref:,
        account_fingerprint:,
        result_hash:,
        error_class:,
      )
    case effect.phase == phase {
      True ->
        case effect == requested {
          True -> Ok(effect)
          False -> Error("idempotency_conflict")
        }
      False -> {
        use _ <- result.try(case effect.phase == "intent" {
          True -> Ok(Nil)
          False -> Error("google_external_effect_already_finished")
        })
        use rows <- result.try(
          sqlight.query(
            "UPDATE connector_external_effects SET phase = ?, proof_ref = ?, account_fingerprint = ?, result_hash = ?, error_class = ?, updated_at_ms = ? WHERE effect_id = ? AND phase = 'intent' RETURNING effect_id, preparation_authorization_id, authorization_id, activation_id, configuration_ref, configuration_hash, connector_id, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, effect_kind, logical_effect_key, attempt_number, request_hash, phase, proof_ref, oauth_scope, account_fingerprint, result_hash, error_class",
            on: conn,
            with: [
              sqlight.text(phase),
              nullable_nonempty_text(proof_ref),
              nullable_nonempty_text(account_fingerprint),
              nullable_nonempty_text(result_hash),
              nullable_nonempty_text(error_class),
              sqlight.int(now_ms),
              sqlight.text(effect_id),
            ],
            expecting: google_external_effect_decoder(),
          )
          |> result.map_error(fn(error) {
            "Failed to finish Google external effect: " <> string.inspect(error)
          }),
        )
        use finished <- result.try(case rows {
          [value] -> Ok(value)
          _ -> Error("google_external_effect_state_conflict")
        })
        use _ <- result.try(append_google_execution_audit(
          conn,
          "google-effect:" <> effect_id <> ":" <> phase,
          "google.external_effect." <> phase,
          "connector_external_effect",
          effect_id,
          effect.preparation_authorization_id,
          case error_class {
            "" -> None
            value -> Some(value)
          },
          now_ms,
        ))
        Ok(finished)
      }
    }
  })
}

fn validate_google_effect_attempt(
  conn: sqlight.Connection,
  effect: GoogleExternalEffect,
) -> Result(Nil, String) {
  use attempts <- result.try(
    sqlight.query(
      "SELECT attempt_number, phase, effect_kind FROM connector_external_effects WHERE logical_effect_key = ? ORDER BY attempt_number",
      on: conn,
      with: [sqlight.text(effect.logical_effect_key)],
      expecting: {
        use attempt_number <- decode.field(0, decode.int)
        use phase <- decode.field(1, decode.string)
        use effect_kind <- decode.field(2, decode.string)
        decode.success(#(attempt_number, phase, effect_kind))
      },
    )
    |> result.map_error(fn(error) {
      "Failed to validate Google external effect attempt: "
      <> string.inspect(error)
    }),
  )
  case effect.effect_kind {
    "oauth_exchange" ->
      case effect.attempt_number == 1 && attempts == [] {
        True -> Ok(Nil)
        False -> Error("oauth_exchange_attempt_rejected")
      }
    _ ->
      case attempts {
        [] ->
          case effect.attempt_number == 1 {
            True -> Ok(Nil)
            False -> Error("google_effect_attempt_sequence_conflict")
          }
        _ -> {
          let assert Ok(#(last_number, last_phase, last_kind)) =
            list.last(attempts)
          case
            effect.attempt_number == last_number + 1
            && effect.effect_kind == last_kind
            && last_phase != "intent"
            && {
              last_phase != "succeeded" || effect.effect_kind == "oauth_refresh"
            }
          {
            True -> Ok(Nil)
            False -> Error("google_effect_attempt_sequence_conflict")
          }
        }
      }
  }
}

fn do_next_google_external_effect_attempt(
  conn: sqlight.Connection,
  logical_effect_key: String,
  effect_kind: String,
) -> Result(Int, String) {
  case
    safe_opaque_ref(logical_effect_key, 128)
    && list.contains(["oauth_refresh", "identity_read"], effect_kind)
  {
    False -> Error("google_effect_attempt_request_invalid")
    True ->
      sqlight.query(
        "SELECT attempt_number, phase, effect_kind FROM connector_external_effects WHERE logical_effect_key = ? ORDER BY attempt_number DESC LIMIT 1",
        on: conn,
        with: [sqlight.text(logical_effect_key)],
        expecting: {
          use attempt_number <- decode.field(0, decode.int)
          use phase <- decode.field(1, decode.string)
          use stored_kind <- decode.field(2, decode.string)
          decode.success(#(attempt_number, phase, stored_kind))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to resolve Google effect attempt: " <> string.inspect(error)
      })
      |> result.try(fn(rows) {
        case rows {
          [] -> Ok(1)
          [#(attempt_number, phase, stored_kind)] ->
            case stored_kind == effect_kind, phase {
              False, _ -> Error("google_effect_attempt_kind_conflict")
              True, "succeeded" if effect_kind == "identity_read" ->
                Error("google_effect_already_succeeded")
              True, "succeeded" -> Ok(attempt_number + 1)
              True, "intent" -> Error("google_effect_attempt_in_progress")
              True, _ -> Ok(attempt_number + 1)
            }
          _ -> Error("google_effect_attempt_state_invalid")
        }
      })
  }
}

fn load_google_oauth_session(
  conn: sqlight.Connection,
  session_ref: String,
) -> Result(Option(GoogleOAuthSession), String) {
  sqlight.query(
    "SELECT session_ref, connector_id, preparation_authorization_id, configuration_ref, configuration_hash, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, state_hash, pkce_challenge, redirect_uri, phase, expires_at_ms FROM connector_oauth_sessions WHERE session_ref = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(session_ref)],
    expecting: google_oauth_session_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to load Google OAuth session: " <> string.inspect(error)
  })
  |> result.map(fn(rows) {
    case rows {
      [value, ..] -> Some(value)
      [] -> None
    }
  })
}

fn google_oauth_session_decoder() -> decode.Decoder(GoogleOAuthSession) {
  use session_ref <- decode.field(0, decode.string)
  use connector_id <- decode.field(1, decode.string)
  use preparation_authorization_id <- decode.field(2, decode.string)
  use configuration_ref <- decode.field(3, decode.string)
  use configuration_hash <- decode.field(4, decode.string)
  use oauth_client_ref <- decode.field(5, decode.string)
  use oauth_client_hash <- decode.field(6, decode.string)
  use client_set_ref <- decode.field(7, decode.string)
  use client_set_hash <- decode.field(8, decode.string)
  use state_hash <- decode.field(9, decode.string)
  use pkce_challenge <- decode.field(10, decode.string)
  use redirect_uri <- decode.field(11, decode.string)
  use phase <- decode.field(12, decode.string)
  use expires_at_ms <- decode.field(13, decode.int)
  decode.success(GoogleOAuthSession(
    session_ref:,
    connector_id:,
    preparation_authorization_id:,
    configuration_ref:,
    configuration_hash:,
    oauth_client_ref:,
    oauth_client_hash:,
    client_set_ref:,
    client_set_hash:,
    state_hash:,
    pkce_challenge:,
    redirect_uri:,
    phase:,
    expires_at_ms:,
  ))
}

fn load_google_external_effect(
  conn: sqlight.Connection,
  effect_id: String,
) -> Result(Option(GoogleExternalEffect), String) {
  sqlight.query(
    "SELECT effect_id, preparation_authorization_id, authorization_id, activation_id, configuration_ref, configuration_hash, connector_id, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, effect_kind, logical_effect_key, attempt_number, request_hash, phase, proof_ref, oauth_scope, account_fingerprint, result_hash, error_class FROM connector_external_effects WHERE effect_id = ? LIMIT 1",
    on: conn,
    with: [sqlight.text(effect_id)],
    expecting: google_external_effect_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to load Google external effect: " <> string.inspect(error)
  })
  |> result.map(fn(rows) {
    case rows {
      [value, ..] -> Some(value)
      [] -> None
    }
  })
}

fn load_latest_google_external_effect(
  conn: sqlight.Connection,
  logical_effect_key: String,
) -> Result(Option(GoogleExternalEffect), String) {
  case safe_opaque_ref(logical_effect_key, 128) {
    False -> Error("google_effect_logical_key_invalid")
    True ->
      sqlight.query(
        "SELECT effect_id, preparation_authorization_id, authorization_id, activation_id, configuration_ref, configuration_hash, connector_id, oauth_client_ref, oauth_client_hash, client_set_ref, client_set_hash, effect_kind, logical_effect_key, attempt_number, request_hash, phase, proof_ref, oauth_scope, account_fingerprint, result_hash, error_class FROM connector_external_effects WHERE logical_effect_key = ? ORDER BY attempt_number DESC LIMIT 1",
        on: conn,
        with: [sqlight.text(logical_effect_key)],
        expecting: google_external_effect_decoder(),
      )
      |> result.map_error(fn(error) {
        "Failed to load latest Google external effect: "
        <> string.inspect(error)
      })
      |> result.map(fn(rows) {
        case rows {
          [value, ..] -> Some(value)
          [] -> None
        }
      })
  }
}

fn google_external_effect_decoder() -> decode.Decoder(GoogleExternalEffect) {
  use effect_id <- decode.field(0, decode.string)
  use preparation_authorization_id <- decode.field(1, decode.string)
  use authorization_id <- decode.field(2, nullable_string_decoder())
  use activation_id <- decode.field(3, nullable_string_decoder())
  use configuration_ref <- decode.field(4, decode.string)
  use configuration_hash <- decode.field(5, decode.string)
  use connector_id <- decode.field(6, decode.string)
  use oauth_client_ref <- decode.field(7, decode.string)
  use oauth_client_hash <- decode.field(8, decode.string)
  use client_set_ref <- decode.field(9, decode.string)
  use client_set_hash <- decode.field(10, decode.string)
  use effect_kind <- decode.field(11, decode.string)
  use logical_effect_key <- decode.field(12, decode.string)
  use attempt_number <- decode.field(13, decode.int)
  use request_hash <- decode.field(14, decode.string)
  use phase <- decode.field(15, decode.string)
  use proof_ref <- decode.field(16, nullable_string_decoder())
  use oauth_scope <- decode.field(17, decode.string)
  use account_fingerprint <- decode.field(18, nullable_string_decoder())
  use result_hash <- decode.field(19, nullable_string_decoder())
  use error_class <- decode.field(20, nullable_string_decoder())
  decode.success(GoogleExternalEffect(
    effect_id:,
    preparation_authorization_id:,
    authorization_id:,
    activation_id:,
    configuration_ref:,
    configuration_hash:,
    connector_id:,
    oauth_client_ref:,
    oauth_client_hash:,
    client_set_ref:,
    client_set_hash:,
    effect_kind:,
    logical_effect_key:,
    attempt_number:,
    request_hash:,
    phase:,
    proof_ref:,
    oauth_scope:,
    account_fingerprint:,
    result_hash:,
    error_class:,
  ))
}

fn validate_google_oauth_session(
  session: GoogleOAuthSession,
  now_ms: Int,
) -> Result(Nil, String) {
  case
    session.phase == "waiting"
    && session.expires_at_ms > now_ms
    && string.starts_with(session.redirect_uri, "http://127.0.0.1:")
    && string.ends_with(session.redirect_uri, "/callback")
    && string.length(session.redirect_uri) <= 64
    && !string.contains(session.redirect_uri, "?")
    && !string.contains(session.redirect_uri, "#")
    && safe_opaque_ref(session.session_ref, 128)
    && safe_opaque_ref(session.preparation_authorization_id, 128)
    && safe_opaque_ref(session.configuration_ref, 128)
    && safe_opaque_ref(session.oauth_client_ref, 128)
    && safe_opaque_ref(session.client_set_ref, 128)
    && lower_sha256(session.state_hash)
    && string.length(session.pkce_challenge) == 43
    && safe_base64url(session.pkce_challenge)
    && lower_sha256(session.configuration_hash)
    && lower_sha256(session.oauth_client_hash)
    && lower_sha256(session.client_set_hash)
    && list.contains(["gmail", "calendar"], session.connector_id)
  {
    True -> Ok(Nil)
    False -> Error("invalid_google_oauth_session")
  }
}

fn validate_google_external_effect_intent(
  effect: GoogleExternalEffect,
) -> Result(Nil, String) {
  case
    effect.phase == "intent"
    && safe_opaque_ref(effect.effect_id, 128)
    && safe_opaque_ref(effect.preparation_authorization_id, 128)
    && {
      effect.authorization_id == ""
      || safe_opaque_ref(effect.authorization_id, 128)
    }
    && {
      effect.activation_id == "" || safe_opaque_ref(effect.activation_id, 128)
    }
    && safe_opaque_ref(effect.configuration_ref, 128)
    && safe_opaque_ref(effect.oauth_client_ref, 128)
    && safe_opaque_ref(effect.client_set_ref, 128)
    && safe_opaque_ref(effect.logical_effect_key, 128)
    && effect.attempt_number > 0
    && lower_sha256(effect.configuration_hash)
    && lower_sha256(effect.oauth_client_hash)
    && lower_sha256(effect.client_set_hash)
    && lower_sha256(effect.request_hash)
    && effect.proof_ref == ""
    && effect.account_fingerprint == ""
    && effect.result_hash == ""
    && effect.error_class == ""
    && list.contains(
      ["oauth_exchange", "oauth_refresh", "identity_read"],
      effect.effect_kind,
    )
    && exact_google_scope(effect.connector_id, effect.oauth_scope)
  {
    True -> Ok(Nil)
    False -> Error("invalid_google_external_effect_intent")
  }
}

fn validate_google_external_effect_outcome(
  phase: String,
  proof_ref: String,
  account_fingerprint: String,
  result_hash: String,
  error_class: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    case
      string.length(account_fingerprint) <= 128
      && { account_fingerprint == "" || lower_sha256(account_fingerprint) }
    {
      True -> Ok(Nil)
      False -> Error("invalid_google_external_effect_outcome")
    },
  )
  case phase {
    "succeeded" ->
      case
        safe_opaque_ref(proof_ref, 128)
        && lower_sha256(result_hash)
        && error_class == ""
      {
        True -> Ok(Nil)
        False -> Error("invalid_google_external_effect_outcome")
      }
    "failed_before_effect" | "effect_unknown" ->
      case
        proof_ref == ""
        && result_hash == ""
        && google_effect_error_class(error_class)
      {
        True -> Ok(Nil)
        False -> Error("invalid_google_external_effect_outcome")
      }
    _ -> Error("invalid_google_external_effect_outcome")
  }
}

fn validate_google_oauth_client_set(
  client_set: GoogleOAuthClientSet,
) -> Result(Nil, String) {
  case
    safe_opaque_ref(client_set.client_set_ref, 128)
    && lower_sha256(client_set.client_set_hash)
    && safe_opaque_ref(client_set.gmail_client_ref, 128)
    && lower_sha256(client_set.gmail_client_hash)
    && safe_opaque_ref(client_set.calendar_client_ref, 128)
    && lower_sha256(client_set.calendar_client_hash)
    && client_set.gmail_client_ref != client_set.calendar_client_ref
  {
    True -> Ok(Nil)
    False -> Error("invalid_google_oauth_client_set")
  }
}

fn exact_google_scope(connector_id: String, scope: String) -> Bool {
  case connector_id {
    "gmail" -> scope == "https://www.googleapis.com/auth/gmail.readonly"
    "calendar" -> scope == "https://www.googleapis.com/auth/calendar.readonly"
    _ -> False
  }
}

fn lower_sha256(value: String) -> Bool {
  string.length(value) == 64
  && {
    value
    |> string.to_graphemes
    |> list.all(fn(character) { string.contains("0123456789abcdef", character) })
  }
}

fn safe_opaque_ref(value: String, max_length: Int) -> Bool {
  string.length(value) > 0
  && string.length(value) <= max_length
  && {
    value
    |> string.to_graphemes
    |> list.all(fn(character) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:._-/",
        character,
      )
    })
  }
}

fn safe_base64url(value: String) -> Bool {
  value
  |> string.to_graphemes
  |> list.all(fn(character) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_",
      character,
    )
  })
}

fn google_effect_error_class(value: String) -> Bool {
  list.contains(
    [
      "transport_after_dispatch",
      "before_dispatch",
      "invalid_grant",
      "scope_mismatch",
      "identity_mismatch",
      "authorization_mismatch",
      "provider_invalid_response",
      "provider_unauthorized",
      "provider_forbidden",
      "provider_rate_limited",
      "provider_unavailable",
      "response_too_large",
      "timeout_after_dispatch",
      "tls_after_dispatch",
      "connection_after_dispatch",
    ],
    value,
  )
}

fn load_effective_preparation(
  conn: sqlight.Connection,
  authorization_id: String,
  now_ms: Int,
) -> Result(operating_contracts.CanaryPreparationAuthorizationV1, String) {
  use stored <- result.try(do_get_canary_preparation_authorization(
    conn,
    authorization_id,
  ))
  use value <- result.try(case stored {
    Some(preparation) -> Ok(preparation.authorization)
    None -> Error("preparation_authorization_not_found")
  })
  case value.expires_at_ms > now_ms {
    True -> Ok(value)
    False -> Error("preparation_authorization_expired")
  }
}

fn validate_preparation_connector(
  preparation: operating_contracts.CanaryPreparationAuthorizationV1,
  connector_id: String,
  configuration_ref: String,
  client_set_ref: String,
  client_set_hash: String,
  oauth_scope: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    case
      preparation.oauth_client_ref == client_set_ref
      && preparation.oauth_client_hash == client_set_hash
      && list.contains(preparation.grants, "oauth.authorize")
    {
      True -> Ok(Nil)
      False -> Error("preparation_authorization_mismatch")
    },
  )
  use connector <- result.try(
    list.find(preparation.connectors, fn(value) {
      value.connector_id == connector_id
    })
    |> result.map_error(fn(_) { "preparation_connector_not_authorized" }),
  )
  case
    connector.configuration_ref == configuration_ref
    && { oauth_scope == "" || connector.oauth_scope == oauth_scope }
  {
    True -> Ok(Nil)
    False -> Error("preparation_connector_mismatch")
  }
}

fn google_readonly_scope(connector_id: String) -> Result(String, String) {
  case connector_id {
    "gmail" -> Ok("https://www.googleapis.com/auth/gmail.readonly")
    "calendar" -> Ok("https://www.googleapis.com/auth/calendar.readonly")
    _ -> Error("unsupported_google_connector")
  }
}

fn validate_registered_client_binding(
  conn: sqlight.Connection,
  connector_id: String,
  oauth_client_ref: String,
  oauth_client_hash: String,
  client_set_ref: String,
  client_set_hash: String,
) -> Result(Nil, String) {
  sqlight.query(
    "SELECT 1 FROM connector_oauth_client_sets WHERE client_set_ref = ? AND client_set_hash = ? AND ((? = 'gmail' AND gmail_client_ref = ? AND gmail_client_hash = ?) OR (? = 'calendar' AND calendar_client_ref = ? AND calendar_client_hash = ?)) LIMIT 1",
    on: conn,
    with: [
      sqlight.text(client_set_ref),
      sqlight.text(client_set_hash),
      sqlight.text(connector_id),
      sqlight.text(oauth_client_ref),
      sqlight.text(oauth_client_hash),
      sqlight.text(connector_id),
      sqlight.text(oauth_client_ref),
      sqlight.text(oauth_client_hash),
    ],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(error) {
    "Failed to validate Google OAuth client binding: " <> string.inspect(error)
  })
  |> result.try(fn(rows) {
    case rows {
      [1] -> Ok(Nil)
      _ -> Error("oauth_client_binding_mismatch")
    }
  })
}

fn nullable_nonempty_text(value: String) -> sqlight.Value {
  case value {
    "" -> sqlight.nullable(sqlight.text, None)
    _ -> sqlight.nullable(sqlight.text, Some(value))
  }
}

fn append_google_execution_audit(
  conn: sqlight.Connection,
  audit_id: String,
  action: String,
  target_type: String,
  target_id: String,
  authority_ref: String,
  error_code: Option(String),
  occurred_at: Int,
) -> Result(Nil, String) {
  do_append_operational_audit(
    conn,
    operational_audit.Record(
      schema_version: 1,
      audit_id:,
      record_type: "state_transition",
      actor: "aura",
      source: "google_readonly_execution",
      action:,
      target_type:,
      target_id:,
      before_version: None,
      after_version: None,
      idempotency_key: Some(target_id),
      evidence_refs: [],
      proof_refs: [],
      authority_ref: Some(authority_ref),
      result: case error_code {
        Some(_) -> "failed"
        None -> "succeeded"
      },
      error_code:,
      occurred_at:,
    ),
  )
  |> result.map(fn(_) { Nil })
}

fn do_reserve_connector_read(
  conn: sqlight.Connection,
  attempt_id: String,
  activation_id: String,
  authorization_id: String,
  worker_id: String,
  lease_ms: Int,
) -> Result(ConnectorReadAttempt, String) {
  use _ <- result.try(case lease_ms > 0 && lease_ms <= 300_000 {
    True -> Ok(Nil)
    False -> Error("invalid_connector_read_lease")
  })
  let now_ms = time.now_ms()
  use _ <- result.try(
    case
      validate_connector_execution_eligibility(
        conn,
        authorization_id,
        activation_id,
      )
    {
      Ok(_) -> Ok(Nil)
      Error(_) -> {
        use _ <- result.try(append_execution_ineligible_audit_once(
          conn,
          "connector-execution-ineligible:" <> attempt_id,
          "connector.read.execution_ineligible",
          "connector_activation",
          activation_id,
          attempt_id,
          authorization_id,
          now_ms,
        ))
        Error("connector_execution_ineligible")
      }
    },
  )
  in_transaction(conn, "connector read reservation", fn() {
    use activation <- result.try(do_get_effective_connector_activation(
      conn,
      activation_id,
      authorization_id,
    ))
    use effective <- result.try(case activation {
      Some(value) -> Ok(value)
      None -> Error("connector_activation_not_effective")
    })
    use _ <- result.try(no_active_connector_read_for_activation(
      conn,
      activation_id,
    ))
    use _ <- result.try(
      sqlight.query(
        "INSERT INTO connector_read_attempts (attempt_id, activation_id, activation_version, attempt_version, worker_id, phase, reserved_at_ms, lease_expires_at_ms, hard_expires_at_ms) VALUES (?, ?, ?, 1, ?, 'reserved', ?, ?, ?)",
        on: conn,
        with: [
          sqlight.text(attempt_id),
          sqlight.text(activation_id),
          sqlight.int(effective.version),
          sqlight.text(worker_id),
          sqlight.int(now_ms),
          sqlight.int(now_ms + lease_ms),
          sqlight.int(now_ms + 300_000),
        ],
        expecting: decode.success(Nil),
      )
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(_) { "connector_read_attempt_conflict" }),
    )
    let result =
      ConnectorReadAttempt(
        attempt_id:,
        activation_id:,
        activation_version: effective.version,
        attempt_version: 1,
        worker_id:,
        phase: "reserved",
      )
    use _ <- result.try(append_connector_read_audit(
      conn,
      result,
      "connector.read.reserved",
      "",
      now_ms,
    ))
    Ok(result)
  })
}

fn no_active_connector_read_for_activation(
  conn: sqlight.Connection,
  activation_id: String,
) -> Result(Nil, String) {
  sqlight.query(
    "SELECT count(*) FROM connector_read_attempts WHERE activation_id = ? AND phase IN ('reserved', 'request_started')",
    on: conn,
    with: [sqlight.text(activation_id)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(error) {
    "Failed to inspect active connector read: " <> string.inspect(error)
  })
  |> result.try(fn(rows) {
    case rows {
      [0] -> Ok(Nil)
      _ -> Error("connector_read_attempt_active")
    }
  })
}

fn validate_connector_execution_eligibility(
  conn: sqlight.Connection,
  authorization_id: String,
  activation_id: String,
) -> Result(Nil, String) {
  use stored <- result.try(do_get_canary_authorization(conn, authorization_id))
  use authorization <- result.try(case stored {
    Some(value) -> Ok(value.authorization)
    None -> Error("canary_authorization_not_found")
  })
  use connector <- result.try(
    list.find(authorization.connectors, fn(value) {
      value.activation_id == activation_id
    })
    |> result.map_error(fn(_) { "canary_connector_not_found" }),
  )
  use preparation <- result.try(do_get_canary_preparation_authorization(
    conn,
    authorization.preparation_authorization_id,
  ))
  use value <- result.try(case preparation {
    Some(stored) -> Ok(stored.authorization)
    None -> Error("preparation_authorization_not_found")
  })
  validate_final_connector_proofs(conn, value, connector)
}

fn do_begin_connector_read(
  conn: sqlight.Connection,
  attempt_id: String,
  worker_id: String,
) -> Result(Nil, String) {
  let now_ms = time.now_ms()
  in_transaction(conn, "connector read start", fn() {
    use rows <- result.try(
      sqlight.query(
        "UPDATE connector_read_attempts SET phase = 'request_started', attempt_version = attempt_version + 1, request_started_at_ms = ? WHERE attempt_id = ? AND worker_id = ? AND phase = 'reserved' AND lease_expires_at_ms > ? AND hard_expires_at_ms > ? AND EXISTS (SELECT 1 FROM connector_activations ca JOIN canary_authorizations a ON a.authorization_id = ca.authorization_id WHERE ca.activation_id = connector_read_attempts.activation_id AND ca.state = 'enabled' AND a.starts_at_ms <= ? AND a.ends_at_ms > ?) RETURNING activation_id, activation_version, attempt_version",
        on: conn,
        with: [
          sqlight.int(now_ms),
          sqlight.text(attempt_id),
          sqlight.text(worker_id),
          sqlight.int(now_ms),
          sqlight.int(now_ms),
          sqlight.int(now_ms),
          sqlight.int(now_ms),
        ],
        expecting: {
          use activation_id <- decode.field(0, decode.string)
          use version <- decode.field(1, decode.int)
          use attempt_version <- decode.field(2, decode.int)
          decode.success(#(activation_id, version, attempt_version))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to begin connector read: " <> string.inspect(error)
      }),
    )
    case rows {
      [#(activation_id, version, attempt_version)] -> {
        let attempt =
          ConnectorReadAttempt(
            attempt_id:,
            activation_id:,
            activation_version: version,
            attempt_version:,
            worker_id:,
            phase: "request_started",
          )
        use _ <- result.try(append_connector_read_audit(
          conn,
          attempt,
          "connector.read.request_started",
          "",
          now_ms,
        ))
        Ok(Nil)
      }
      _ -> Error("connector_read_not_reservable")
    }
  })
}

fn do_renew_connector_read(
  conn: sqlight.Connection,
  attempt_id: String,
  worker_id: String,
  expected_attempt_version: Int,
  lease_ms: Int,
) -> Result(ConnectorReadAttempt, String) {
  use _ <- result.try(case lease_ms > 0 && lease_ms <= 300_000 {
    True -> Ok(Nil)
    False -> Error("invalid_connector_read_lease")
  })
  let now_ms = time.now_ms()
  in_transaction(conn, "connector read lease renewal", fn() {
    use rows <- result.try(
      sqlight.query(
        "UPDATE connector_read_attempts SET attempt_version = attempt_version + 1, lease_expires_at_ms = MIN(?, hard_expires_at_ms) WHERE attempt_id = ? AND worker_id = ? AND attempt_version = ? AND phase IN ('reserved', 'request_started') AND lease_expires_at_ms > ? AND hard_expires_at_ms > ? AND EXISTS (SELECT 1 FROM connector_activations ca JOIN canary_authorizations a ON a.authorization_id = ca.authorization_id WHERE ca.activation_id = connector_read_attempts.activation_id AND ca.state = 'enabled' AND a.starts_at_ms <= ? AND a.ends_at_ms > ?) RETURNING activation_id, activation_version, attempt_version, phase",
        on: conn,
        with: [
          sqlight.int(now_ms + lease_ms),
          sqlight.text(attempt_id),
          sqlight.text(worker_id),
          sqlight.int(expected_attempt_version),
          sqlight.int(now_ms),
          sqlight.int(now_ms),
          sqlight.int(now_ms),
          sqlight.int(now_ms),
        ],
        expecting: {
          use activation_id <- decode.field(0, decode.string)
          use activation_version <- decode.field(1, decode.int)
          use attempt_version <- decode.field(2, decode.int)
          use phase <- decode.field(3, decode.string)
          decode.success(#(
            activation_id,
            activation_version,
            attempt_version,
            phase,
          ))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to renew connector read: " <> string.inspect(error)
      }),
    )
    use row <- result.try(case rows {
      [value] -> Ok(value)
      _ -> Error("connector_read_lease_conflict")
    })
    let attempt =
      ConnectorReadAttempt(
        attempt_id:,
        activation_id: row.0,
        activation_version: row.1,
        attempt_version: row.2,
        worker_id:,
        phase: row.3,
      )
    use _ <- result.try(append_connector_read_audit(
      conn,
      attempt,
      "connector.read.lease_renewed",
      "",
      now_ms,
    ))
    Ok(attempt)
  })
}

fn do_finish_connector_read(
  conn: sqlight.Connection,
  attempt_id: String,
  worker_id: String,
  phase: String,
  error_code: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    case
      list.contains(["completed", "discarded", "failed", "interrupted"], phase)
    {
      True -> Ok(Nil)
      False -> Error("invalid_connector_read_phase")
    },
  )
  let now_ms = time.now_ms()
  in_transaction(conn, "connector read finish", fn() {
    use rows <- result.try(
      sqlight.query(
        "UPDATE connector_read_attempts SET phase = ?, attempt_version = attempt_version + 1, finished_at_ms = ?, error_code = ? WHERE attempt_id = ? AND worker_id = ? AND phase IN ('reserved', 'request_started') RETURNING activation_id, activation_version, attempt_version",
        on: conn,
        with: [
          sqlight.text(phase),
          sqlight.int(now_ms),
          sqlight.text(error_code),
          sqlight.text(attempt_id),
          sqlight.text(worker_id),
        ],
        expecting: {
          use activation_id <- decode.field(0, decode.string)
          use version <- decode.field(1, decode.int)
          use attempt_version <- decode.field(2, decode.int)
          decode.success(#(activation_id, version, attempt_version))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to finish connector read: " <> string.inspect(error)
      }),
    )
    case rows {
      [#(activation_id, version, attempt_version)] -> {
        let attempt =
          ConnectorReadAttempt(
            attempt_id:,
            activation_id:,
            activation_version: version,
            attempt_version:,
            worker_id:,
            phase:,
          )
        use _ <- result.try(append_connector_read_audit(
          conn,
          attempt,
          "connector.read." <> phase,
          error_code,
          now_ms,
        ))
        Ok(Nil)
      }
      _ -> Error("connector_read_not_active")
    }
  })
}

fn do_recover_expired_connector_reads(
  conn: sqlight.Connection,
) -> Result(Int, String) {
  let now_ms = time.now_ms()
  in_transaction(conn, "connector read recovery", fn() {
    use recovered <- result.try(
      sqlight.query(
        "UPDATE connector_read_attempts SET phase = 'interrupted', attempt_version = attempt_version + 1, finished_at_ms = ?, error_code = CASE phase WHEN 'request_started' THEN 'external_read_unknown' ELSE 'worker_interrupted' END WHERE phase IN ('reserved', 'request_started') AND lease_expires_at_ms <= ? RETURNING attempt_id, activation_id, activation_version, attempt_version, worker_id, error_code",
        on: conn,
        with: [sqlight.int(now_ms), sqlight.int(now_ms)],
        expecting: {
          use attempt_id <- decode.field(0, decode.string)
          use activation_id <- decode.field(1, decode.string)
          use activation_version <- decode.field(2, decode.int)
          use attempt_version <- decode.field(3, decode.int)
          use worker_id <- decode.field(4, decode.string)
          use error_code <- decode.field(5, decode.string)
          decode.success(#(
            attempt_id,
            activation_id,
            activation_version,
            attempt_version,
            worker_id,
            error_code,
          ))
        },
      )
      |> result.map_error(fn(error) {
        "Failed to recover connector reads: " <> string.inspect(error)
      }),
    )
    use _ <- result.try(
      recovered
      |> list.try_each(fn(row) {
        let #(
          attempt_id,
          activation_id,
          activation_version,
          attempt_version,
          worker_id,
          error_code,
        ) = row
        append_connector_read_audit(
          conn,
          ConnectorReadAttempt(
            attempt_id:,
            activation_id:,
            activation_version:,
            attempt_version:,
            worker_id:,
            phase: "interrupted",
          ),
          "connector.read.interrupted",
          error_code,
          now_ms,
        )
      }),
    )
    Ok(list.length(recovered))
  })
}

fn append_connector_read_audit(
  conn: sqlight.Connection,
  attempt: ConnectorReadAttempt,
  action: String,
  error_code: String,
  now_ms: Int,
) -> Result(Nil, String) {
  do_append_operational_audit(
    conn,
    operational_audit.Record(
      schema_version: 1,
      audit_id: "connector-read:"
        <> attempt.attempt_id
        <> ":"
        <> string.inspect(attempt.attempt_version)
        <> ":"
        <> action,
      record_type: "state_transition",
      actor: "aura",
      source: "connector_runtime",
      action:,
      target_type: "connector_read_attempt",
      target_id: attempt.attempt_id,
      before_version: None,
      after_version: Some(attempt.attempt_version),
      idempotency_key: Some(attempt.attempt_id),
      evidence_refs: [],
      proof_refs: [attempt.activation_id],
      authority_ref: Some(attempt.worker_id),
      result: "succeeded",
      error_code: case error_code {
        "" -> None
        _ -> Some(error_code)
      },
      occurred_at: now_ms,
    ),
  )
  |> result.map(fn(_) { Nil })
}

fn do_transition_connector_activation_set(
  conn: sqlight.Connection,
  authorization_id: String,
  idempotency_key: String,
  actor_ref: String,
  authority_grants: List(String),
  operation: String,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  use _ <- result.try(validate_connector_activation_operation(operation))
  use _ <- result.try(case string.trim(idempotency_key) == "" {
    True -> Error("invalid_idempotency_key")
    False -> Ok(Nil)
  })
  let now_ms = time.now_ms()
  use _ <- result.try(case operation {
    "enable" ->
      case
        validate_authorization_execution_eligibility(conn, authorization_id)
      {
        Ok(_) -> Ok(Nil)
        Error(_) -> {
          use _ <- result.try(append_execution_ineligible_audit_once(
            conn,
            "connector-enable-ineligible:" <> idempotency_key,
            "connector.activation.execution_ineligible",
            "canary_authorization",
            authorization_id,
            idempotency_key,
            actor_ref,
            now_ms,
          ))
          Error("connector_execution_ineligible")
        }
      }
    _ -> Ok(Nil)
  })
  let payload_json =
    json.object([
      #("authorization_id", json.string(authorization_id)),
      #("actor_ref", json.string(actor_ref)),
      #(
        "authority_grants",
        json.array(
          list.sort(authority_grants, by: string.compare),
          of: json.string,
        ),
      ),
      #("operation", json.string(operation)),
    ])
    |> json.to_string
  let operation_type = "connector.activation." <> operation
  let payload_hash =
    operational_mutation_payload_hash(operation_type, payload_json)
  in_transaction(conn, "connector activation transition", fn() {
    use existing <- result.try(do_get_mutation_receipt(conn, idempotency_key))
    case existing {
      Some(receipt) ->
        case receipt.payload_hash == payload_hash {
          True -> decode_connector_activation_receipt(receipt.result_json)
          False -> Error("idempotency_conflict")
        }
      None -> {
        use stored_authorization <- result.try(do_get_canary_authorization(
          conn,
          authorization_id,
        ))
        use authorization <- result.try(case stored_authorization {
          Some(stored) -> Ok(stored.authorization)
          None -> Error("canary_authorization_not_found")
        })
        use _ <- result.try(validate_activation_transition_authority(
          authorization,
          operation,
          actor_ref,
          authority_grants,
          now_ms,
        ))
        use current <- result.try(do_list_connector_activation_set(
          conn,
          authorization_id,
        ))
        use next <- result.try(case operation {
          "prepare" ->
            do_prepare_connector_activation_set(
              conn,
              authorization,
              current,
              now_ms,
            )
          "enable" ->
            do_update_connector_activation_set(
              conn,
              authorization,
              current,
              "disabled",
              "enabled",
              now_ms,
            )
          "begin_disable" ->
            do_update_connector_activation_set(
              conn,
              authorization,
              current,
              "enabled",
              "disabling",
              now_ms,
            )
          "finalize_disable" -> {
            use _ <- result.try(no_active_connector_read_attempts(
              conn,
              authorization,
            ))
            do_update_connector_activation_set(
              conn,
              authorization,
              current,
              "disabling",
              "disabled",
              now_ms,
            )
          }
          "expire" ->
            do_update_connector_activation_set(
              conn,
              authorization,
              current,
              "enabled",
              "disabling",
              now_ms,
            )
          _ -> Error("invalid_connector_activation_operation")
        })
        use _ <- result.try(append_connector_activation_audits(
          conn,
          authorization,
          current,
          next,
          operation,
          idempotency_key,
          actor_ref,
          now_ms,
        ))
        use _ <- result.try(do_insert_mutation_receipt(
          conn,
          MutationReceipt(
            idempotency_key:,
            schema_version: 1,
            payload_hash:,
            operation_type:,
            result_target_type: "connector_activation_set",
            result_target_id: authorization_id,
            result_version: 1,
            result_json: connector_activation_receipt_json(next),
            created_at_ms: now_ms,
          ),
        ))
        Ok(next)
      }
    }
  })
}

fn validate_authorization_execution_eligibility(
  conn: sqlight.Connection,
  authorization_id: String,
) -> Result(Nil, String) {
  use stored <- result.try(do_get_canary_authorization(conn, authorization_id))
  use authorization <- result.try(case stored {
    Some(value) -> Ok(value.authorization)
    None -> Error("canary_authorization_not_found")
  })
  use preparation <- result.try(do_get_canary_preparation_authorization(
    conn,
    authorization.preparation_authorization_id,
  ))
  use value <- result.try(case preparation {
    Some(stored) -> Ok(stored.authorization)
    None -> Error("preparation_authorization_not_found")
  })
  authorization.connectors
  |> list.try_each(fn(connector) {
    validate_final_connector_proofs(conn, value, connector)
  })
}

fn append_execution_ineligible_audit_once(
  conn: sqlight.Connection,
  audit_id: String,
  action: String,
  target_type: String,
  target_id: String,
  idempotency_key: String,
  authority_ref: String,
  occurred_at_ms: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT OR IGNORE INTO operational_audit (audit_id, schema_version, record_type, actor, source, action, target_type, target_id, idempotency_key, evidence_refs_json, proof_refs_json, authority_ref, result, error_code, occurred_at_ms) VALUES (?, 1, 'verification', 'aura', 'connector_runtime', ?, ?, ?, ?, '[]', '[]', ?, 'rejected', 'missing_v17_execution_proof', ?)",
    on: conn,
    with: [
      sqlight.text(audit_id),
      sqlight.text(action),
      sqlight.text(target_type),
      sqlight.text(target_id),
      sqlight.text(idempotency_key),
      sqlight.text(authority_ref),
      sqlight.int(occurred_at_ms),
    ],
    expecting: decode.success(Nil),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    "Failed to record execution ineligibility: " <> string.inspect(error)
  })
}

fn validate_connector_activation_operation(
  operation: String,
) -> Result(Nil, String) {
  case
    list.contains(
      ["prepare", "enable", "begin_disable", "finalize_disable", "expire"],
      operation,
    )
  {
    True -> Ok(Nil)
    False -> Error("invalid_connector_activation_operation")
  }
}

fn validate_activation_transition_authority(
  authorization: operating_contracts.CanaryAuthorizationV1,
  operation: String,
  actor_ref: String,
  authority_grants: List(String),
  now_ms: Int,
) -> Result(Nil, String) {
  use _ <- result.try(case operation {
    "prepare" | "enable" ->
      case authorization.authorized_by_ref == actor_ref {
        True -> Ok(Nil)
        False -> Error("invalid_activation_authority")
      }
    "begin_disable" | "finalize_disable" ->
      case authorization.rollback_owner_ref == actor_ref {
        True -> Ok(Nil)
        False -> Error("invalid_rollback_authority")
      }
    "expire" ->
      case actor_ref == "aura" {
        True -> Ok(Nil)
        False -> Error("invalid_expiry_authority")
      }
    _ -> Error("invalid_connector_activation_operation")
  })
  use _ <- result.try(case operation {
    "enable" ->
      case
        authorization.starts_at_ms <= now_ms
        && authorization.ends_at_ms > now_ms
      {
        True -> Ok(Nil)
        False -> Error("canary_authorization_expired")
      }
    "expire" ->
      case authorization.ends_at_ms <= now_ms {
        True -> Ok(Nil)
        False -> Error("canary_authorization_not_expired")
      }
    _ -> Ok(Nil)
  })
  let required_grant = case operation {
    "enable" -> Some("connector.enable")
    "begin_disable" -> Some("connector.disable")
    _ -> None
  }
  use _ <- result.try(case required_grant {
    Some(grant) ->
      case
        list.contains(authority_grants, grant)
        && list.contains(authorization.activation_grants, grant)
      {
        True -> Ok(Nil)
        False -> Error("missing_connector_activation_grant")
      }
    None -> Ok(Nil)
  })
  case
    list.all(authority_grants, fn(grant) {
      list.contains(authorization.activation_grants, grant)
    })
  {
    True -> Ok(Nil)
    False -> Error("invalid_connector_activation_grant")
  }
}

fn do_prepare_connector_activation_set(
  conn: sqlight.Connection,
  authorization: operating_contracts.CanaryAuthorizationV1,
  current: List(operating_contracts.ConnectorActivationV1),
  now_ms: Int,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  case current {
    [] -> {
      use _ <- result.try(
        list.try_each(authorization.connectors, fn(connector) {
          sqlight.query(
            "INSERT INTO connector_activations (activation_id, authorization_id, connector_id, domain_id, concern_id, configuration_ref, oauth_scope, state, version, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, 'disabled', 1, ?)",
            on: conn,
            with: [
              sqlight.text(connector.activation_id),
              sqlight.text(authorization.authorization_id),
              sqlight.text(connector.connector_id),
              sqlight.text(authorization.domain_id),
              sqlight.text(authorization.concern_id),
              sqlight.text(connector.configuration_ref),
              sqlight.text(connector.oauth_scope),
              sqlight.int(now_ms),
            ],
            expecting: decode.success(Nil),
          )
          |> result.map(fn(_) { Nil })
          |> result.map_error(fn(error) {
            "Failed to create disabled connector activation: "
            <> string.inspect(error)
          })
        }),
      )
      do_list_connector_activation_set(conn, authorization.authorization_id)
    }
    _ -> Error("connector_activation_set_already_prepared")
  }
}

fn do_update_connector_activation_set(
  conn: sqlight.Connection,
  authorization: operating_contracts.CanaryAuthorizationV1,
  current: List(operating_contracts.ConnectorActivationV1),
  expected_state: String,
  next_state: String,
  now_ms: Int,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  use _ <- result.try(
    case
      activation_set_matches_authorization(
        current,
        authorization,
        expected_state,
      )
    {
      True -> Ok(Nil)
      False -> Error("invalid_connector_activation_state")
    },
  )
  use _ <- result.try(
    sqlight.query(
      "UPDATE connector_activations SET state = ?, version = version + 1, updated_at_ms = ? WHERE authorization_id = ? AND state = ?",
      on: conn,
      with: [
        sqlight.text(next_state),
        sqlight.int(now_ms),
        sqlight.text(authorization.authorization_id),
        sqlight.text(expected_state),
      ],
      expecting: decode.success(Nil),
    )
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(error) {
      "Failed to update connector activation set: " <> string.inspect(error)
    }),
  )
  do_list_connector_activation_set(conn, authorization.authorization_id)
}

fn activation_set_matches_authorization(
  current: List(operating_contracts.ConnectorActivationV1),
  authorization: operating_contracts.CanaryAuthorizationV1,
  state: String,
) -> Bool {
  list.length(current) == list.length(authorization.connectors)
  && list.all(current, fn(activation) {
    activation.state == state
    && list.any(authorization.connectors, fn(connector) {
      activation.activation_id == connector.activation_id
      && activation.connector_id == connector.connector_id
      && activation.configuration_ref == connector.configuration_ref
      && activation.oauth_scope == connector.oauth_scope
    })
  })
}

fn no_active_connector_read_attempts(
  conn: sqlight.Connection,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> Result(Nil, String) {
  sqlight.query(
    "SELECT count(*) FROM connector_read_attempts WHERE activation_id IN (SELECT activation_id FROM connector_activations WHERE authorization_id = ?) AND phase IN ('reserved', 'request_started')",
    on: conn,
    with: [sqlight.text(authorization.authorization_id)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(fn(error) {
    "Failed to inspect connector read attempts: " <> string.inspect(error)
  })
  |> result.try(fn(rows) {
    case rows {
      [0] -> Ok(Nil)
      _ -> Error("connector_read_attempts_active")
    }
  })
}

fn append_connector_activation_audits(
  conn: sqlight.Connection,
  authorization: operating_contracts.CanaryAuthorizationV1,
  before: List(operating_contracts.ConnectorActivationV1),
  activations: List(operating_contracts.ConnectorActivationV1),
  operation: String,
  idempotency_key: String,
  actor_ref: String,
  now_ms: Int,
) -> Result(Nil, String) {
  list.try_each(activations, fn(activation) {
    do_append_operational_audit(
      conn,
      operational_audit.Record(
        schema_version: 1,
        audit_id: "connector-activation:"
          <> idempotency_key
          <> ":"
          <> activation.activation_id,
        record_type: "state_transition",
        actor: "aura",
        source: "connector_activation",
        action: "connector.activation." <> operation,
        target_type: "connector_activation",
        target_id: activation.activation_id,
        before_version: case
          list.find(before, fn(previous) {
            previous.activation_id == activation.activation_id
          })
        {
          Ok(previous) -> Some(previous.version)
          Error(_) -> None
        },
        after_version: Some(activation.version),
        idempotency_key: Some(idempotency_key),
        evidence_refs: [],
        proof_refs: [
          authorization.authorization_id,
          activation.configuration_ref,
        ],
        authority_ref: Some(actor_ref),
        result: "succeeded",
        error_code: None,
        occurred_at: now_ms,
      ),
    )
    |> result.map(fn(_) { Nil })
  })
}

fn connector_activation_receipt_json(
  activations: List(operating_contracts.ConnectorActivationV1),
) -> String {
  activations
  |> list.map(operating_contracts.encode_connector_activation)
  |> json.array(of: json.string)
  |> json.to_string
}

fn decode_connector_activation_receipt(
  raw: String,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  use encoded <- result.try(
    json.parse(raw, decode.list(decode.string))
    |> result.map_error(fn(_) { "invalid_connector_activation_receipt" }),
  )
  encoded
  |> list.try_map(operating_contracts.decode_connector_activation)
}

fn do_list_connector_activation_set(
  conn: sqlight.Connection,
  authorization_id: String,
) -> Result(List(operating_contracts.ConnectorActivationV1), String) {
  sqlight.query(
    "SELECT activation_id, authorization_id, connector_id, domain_id, concern_id, configuration_ref, oauth_scope, state, version, updated_at_ms FROM connector_activations WHERE authorization_id = ? ORDER BY connector_id",
    on: conn,
    with: [sqlight.text(authorization_id)],
    expecting: connector_activation_row_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to load connector activation set: " <> string.inspect(error)
  })
}

fn connector_activation_row_decoder() -> decode.Decoder(
  operating_contracts.ConnectorActivationV1,
) {
  use activation_id <- decode.field(0, decode.string)
  use authorization_id <- decode.field(1, decode.string)
  use connector_id <- decode.field(2, decode.string)
  use domain_id <- decode.field(3, decode.string)
  use concern_id <- decode.field(4, decode.string)
  use configuration_ref <- decode.field(5, decode.string)
  use oauth_scope <- decode.field(6, decode.string)
  use state <- decode.field(7, decode.string)
  use version <- decode.field(8, decode.int)
  use updated_at_ms <- decode.field(9, decode.int)
  decode.success(operating_contracts.ConnectorActivationV1(
    schema_version: 1,
    activation_id:,
    authorization_id:,
    connector_id:,
    domain_id:,
    concern_id:,
    configuration_ref:,
    oauth_scope:,
    state:,
    version:,
    updated_at_ms:,
  ))
}

fn canary_payload_hash(canonical_json: String) -> String {
  crypto.hash(crypto.Sha256, <<canonical_json:utf8>>)
  |> bit_array.base16_encode
}

fn do_append_operational_audit(
  conn: sqlight.Connection,
  record: operational_audit.Record,
) -> Result(String, String) {
  let evidence_json =
    json.array(record.evidence_refs, of: json.string) |> json.to_string
  let proof_json =
    json.array(record.proof_refs, of: json.string) |> json.to_string
  sqlight.query(
    "INSERT INTO operational_audit (audit_id, schema_version, record_type, actor, source, action, target_type, target_id, before_version, after_version, idempotency_key, evidence_refs_json, proof_refs_json, authority_ref, result, error_code, occurred_at_ms) VALUES (CASE WHEN ? = '' THEN lower(hex(randomblob(16))) ELSE ? END, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING audit_id",
    on: conn,
    with: [
      sqlight.text(record.audit_id),
      sqlight.text(record.audit_id),
      sqlight.int(record.schema_version),
      sqlight.text(record.record_type),
      sqlight.text(record.actor),
      sqlight.text(record.source),
      sqlight.text(record.action),
      sqlight.text(record.target_type),
      sqlight.text(record.target_id),
      nullable_int(record.before_version),
      nullable_int(record.after_version),
      sqlight.nullable(sqlight.text, record.idempotency_key),
      sqlight.text(evidence_json),
      sqlight.text(proof_json),
      sqlight.nullable(sqlight.text, record.authority_ref),
      sqlight.text(record.result),
      sqlight.nullable(sqlight.text, record.error_code),
      sqlight.int(record.occurred_at),
    ],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(fn(error) {
    "Failed to append operational audit: " <> string.inspect(error)
  })
  |> result.try(fn(rows) {
    case rows {
      [audit_id] -> Ok(audit_id)
      _ -> Error("Failed to append operational audit: no audit id returned")
    }
  })
}

fn do_list_operational_audit(
  conn: sqlight.Connection,
  target_type: String,
  target_id: String,
) -> Result(List(operational_audit.Record), String) {
  sqlight.query(
    "SELECT audit_id, schema_version, record_type, actor, source, action, target_type, target_id, before_version, after_version, idempotency_key, evidence_refs_json, proof_refs_json, authority_ref, result, error_code, occurred_at_ms FROM operational_audit WHERE target_type = ? AND target_id = ? ORDER BY occurred_at_ms, rowid",
    on: conn,
    with: [sqlight.text(target_type), sqlight.text(target_id)],
    expecting: operational_audit_row_decoder(),
  )
  |> result.map_error(fn(error) {
    "Failed to list operational audit: " <> string.inspect(error)
  })
}

fn do_collect_canary_metrics(
  conn: sqlight.Connection,
  authorization_id: String,
  metric_ids: List(String),
) -> Result(List(CanaryMetricCount), String) {
  use stored <- result.try(do_get_canary_authorization(conn, authorization_id))
  use authorization <- result.try(case stored {
    Some(value) -> Ok(value.authorization)
    None -> Error("canary_authorization_not_found")
  })
  use _ <- result.try(
    case
      list.sort(metric_ids, by: string.compare)
      == list.sort(authorization.metric_ids, by: string.compare)
    {
      True -> Ok(Nil)
      False -> Error("unauthorized_canary_metric_set")
    },
  )
  metric_ids
  |> list.try_map(fn(metric_id) {
    use statement <- result.try(canary_metric_statement(metric_id))
    use rows <- result.try(
      sqlight.query(
        statement,
        on: conn,
        with: [sqlight.text(authorization_id)],
        expecting: decode.at([0], decode.int),
      )
      |> result.map_error(fn(error) {
        "Failed to collect canary metric: " <> string.inspect(error)
      }),
    )
    case rows {
      [value] -> Ok(CanaryMetricCount(metric_id:, value:))
      _ -> Error("Failed to collect canary metric: unexpected count")
    }
  })
}

fn canary_metric_statement(metric_id: String) -> Result(String, String) {
  case metric_id {
    "metric:gmail.read_attempts" ->
      Ok(
        "SELECT COUNT(*) FROM connector_read_attempts r JOIN connector_activations a ON a.activation_id = r.activation_id WHERE a.authorization_id = ? AND a.connector_id = 'gmail'",
      )
    "metric:calendar.read_attempts" ->
      Ok(
        "SELECT COUNT(*) FROM connector_read_attempts r JOIN connector_activations a ON a.activation_id = r.activation_id WHERE a.authorization_id = ? AND a.connector_id = 'calendar'",
      )
    "metric:evidence.accepted" ->
      Ok(
        "SELECT COUNT(*) FROM evidence_records WHERE json_extract(envelope_json, '$.provenance.authorization_id') = ?",
      )
    "metric:evidence.gaps" ->
      Ok(
        "SELECT COUNT(*) FROM connector_read_attempts r JOIN connector_activations a ON a.activation_id = r.activation_id WHERE a.authorization_id = ? AND r.phase IN ('discarded', 'failed', 'interrupted')",
      )
    "metric:evidence.unknown_reads" ->
      Ok(
        "SELECT COUNT(*) FROM connector_read_attempts r JOIN connector_activations a ON a.activation_id = r.activation_id WHERE a.authorization_id = ? AND r.error_code = 'external_read_unknown'",
      )
    "metric:evidence.replays" ->
      Ok(
        "SELECT COUNT(*) FROM operational_audit WHERE authority_ref = ? AND action = 'evidence.replayed'",
      )
    "metric:evidence.conflicts" ->
      Ok(
        "SELECT COUNT(*) FROM connector_read_attempts r JOIN connector_activations a ON a.activation_id = r.activation_id WHERE a.authorization_id = ? AND r.error_code = 'idempotency_conflict'",
      )
    "metric:policy.surface_now" ->
      Ok(
        "SELECT COUNT(*) FROM attention_queue WHERE route_authorization_id = ? AND action = 'surface_now'",
      )
    "metric:policy.ask_now" ->
      Ok(
        "SELECT COUNT(*) FROM attention_queue WHERE route_authorization_id = ? AND action = 'ask_now'",
      )
    "metric:attention.queued" ->
      Ok(
        "SELECT COUNT(*) FROM attention_queue WHERE route_authorization_id = ?",
      )
    "metric:attention.duplicates" ->
      Ok(
        "SELECT COUNT(*) FROM operational_audit WHERE authority_ref = ? AND action = 'attention.duplicate_suppressed'",
      )
    "metric:discord.deliveries" ->
      Ok(
        "SELECT COUNT(*) FROM attention_queue WHERE route_authorization_id = ? AND delivery_owner = 'discord_compat'",
      )
    "metric:monitor.claims" ->
      Ok(
        "SELECT COUNT(*) FROM operational_audit a JOIN attention_queue q ON q.queue_id = a.target_id WHERE q.route_authorization_id = ? AND a.action = 'attention.claimed'",
      )
    "metric:monitor.outcomes" ->
      Ok(
        "SELECT COUNT(*) FROM operational_audit a JOIN attention_queue q ON q.queue_id = a.target_id WHERE q.route_authorization_id = ? AND a.action IN ('attention.monitor_acknowledged', 'attention.monitor_deferred')",
      )
    "metric:recovery.effect_unknown" ->
      Ok(
        "SELECT COUNT(*) FROM operational_audit a JOIN attention_queue q ON q.queue_id = a.target_id WHERE q.route_authorization_id = ? AND a.action = 'attention.delivery_effect_unknown'",
      )
    "metric:actions.unapproved" ->
      Ok(
        "SELECT COUNT(*) FROM attention_queue WHERE route_authorization_id = ? AND authority_request IS NULL",
      )
    "metric:transcript.violations" ->
      Ok(
        "SELECT COUNT(DISTINCT e.event_id) FROM evidence_records e, json_tree(e.envelope_json) j WHERE json_extract(e.envelope_json, '$.provenance.authorization_id') = ? AND lower(COALESCE(j.key, '')) IN ('transcript', 'transcript_text', 'conversation', 'conversation_text', 'message_body', 'body', 'raw', 'attachment', 'attachments')",
      )
    _ -> Error("unsupported_canary_metric")
  }
}

fn operational_audit_row_decoder() -> decode.Decoder(operational_audit.Record) {
  use audit_id <- decode.field(0, decode.string)
  use schema_version <- decode.field(1, decode.int)
  use record_type <- decode.field(2, decode.string)
  use actor <- decode.field(3, decode.string)
  use source <- decode.field(4, decode.string)
  use action <- decode.field(5, decode.string)
  use target_type <- decode.field(6, decode.string)
  use target_id <- decode.field(7, decode.string)
  use before_version <- decode.field(8, nullable_int_decoder())
  use after_version <- decode.field(9, nullable_int_decoder())
  use idempotency_key <- decode.field(10, decode.optional(decode.string))
  use evidence_json <- decode.field(11, decode.string)
  use proof_json <- decode.field(12, decode.string)
  use authority_ref <- decode.field(13, decode.optional(decode.string))
  use result_value <- decode.field(14, decode.string)
  use error_code <- decode.field(15, decode.optional(decode.string))
  use occurred_at <- decode.field(16, decode.int)
  case
    json.parse(evidence_json, decode.list(decode.string)),
    json.parse(proof_json, decode.list(decode.string))
  {
    Ok(evidence_refs), Ok(proof_refs) ->
      decode.success(operational_audit.Record(
        schema_version:,
        audit_id:,
        record_type:,
        actor:,
        source:,
        action:,
        target_type:,
        target_id:,
        before_version:,
        after_version:,
        idempotency_key:,
        evidence_refs:,
        proof_refs:,
        authority_ref:,
        result: result_value,
        error_code:,
        occurred_at:,
      ))
    _, _ ->
      decode.failure(
        operational_audit.Record(
          schema_version:,
          audit_id:,
          record_type:,
          actor:,
          source:,
          action:,
          target_type:,
          target_id:,
          before_version:,
          after_version:,
          idempotency_key:,
          evidence_refs: [],
          proof_refs: [],
          authority_ref:,
          result: result_value,
          error_code:,
          occurred_at:,
        ),
        expected: "audit reference JSON",
      )
  }
}

fn in_transaction(
  conn: sqlight.Connection,
  label: String,
  write: fn() -> Result(value, String),
) -> Result(value, String) {
  use _ <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", on: conn)
    |> result.map_error(fn(error) {
      "Failed to start " <> label <> ": " <> string.inspect(error)
    }),
  )
  case write() {
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", on: conn)
      Error(error)
    }
    Ok(value) ->
      case sqlight.exec("COMMIT", on: conn) {
        Ok(_) -> Ok(value)
        Error(error) -> {
          let _ = sqlight.exec("ROLLBACK", on: conn)
          Error("Failed to commit " <> label <> ": " <> string.inspect(error))
        }
      }
  }
}
