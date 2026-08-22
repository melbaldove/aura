//// Versioned wire contracts for Aura operational state.
////
//// These contracts contain compact operational data and references. They do
//// not contain a Codex or Voice conversation transcript.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const schema_version = 1

/// Test one typed Codex reference against the opaque identifier grammar.
pub fn valid_codex_reference(value: String, kind: String) -> Bool {
  case string.split(value, ":") {
    ["codex", found_kind, identifier] ->
      found_kind == kind
      && identifier != ""
      && string.length(identifier) <= 128
      && {
        identifier
        |> string.to_graphemes
        |> list.all(fn(character) {
          string.contains(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.",
            character,
          )
        })
      }
    _ -> False
  }
}

/// A JSON value used in structured operational payloads.
pub type StructuredValue {
  StructuredString(String)
  StructuredInt(Int)
  StructuredFloat(Float)
  StructuredBool(Bool)
  StructuredNull
  StructuredArray(List(StructuredValue))
  StructuredObject(Dict(String, StructuredValue))
}

pub type Domain {
  Domain(
    schema_version: Int,
    domain_id: String,
    slug: String,
    display_name: String,
    aliases: List(String),
    purpose: String,
    status: String,
    context_refs: List(String),
    default_authority_policy_ref: Option(String),
    cwd: Option(String),
    compatibility_transports: List(String),
    version: Int,
    created_at: Int,
    updated_at: Int,
  )
}

pub type Concern {
  Concern(
    schema_version: Int,
    concern_id: String,
    domain_id: String,
    slug: String,
    title: String,
    status: String,
    summary: String,
    why: String,
    current_state: String,
    watch_conditions: List(String),
    authority_boundary: Dict(String, StructuredValue),
    gaps: List(String),
    evidence_refs: List(String),
    work_refs: List(String),
    policy_refs: List(String),
    version: Int,
    created_at: Int,
    updated_at: Int,
  )
}

pub type EvidenceEvent {
  EvidenceEvent(
    schema_version: Int,
    event_id: String,
    source: String,
    source_kind: String,
    event_type: String,
    external_id: Option(String),
    resource: Dict(String, StructuredValue),
    observed_at: Int,
    summary: String,
    normalized_data: Dict(String, StructuredValue),
    raw_ref: Option(String),
    content_hash: String,
    provenance: Dict(String, StructuredValue),
    candidate_domain_refs: List(String),
    candidate_concern_refs: List(String),
    verification_status: String,
  )
}

/// One versioned result from a connector adapter or tool adapter.
///
/// The result contains compact operational data and opaque source references.
/// It cannot contain a copied conversation transcript.
pub type ConnectorResult {
  ConnectorResult(
    schema_version: Int,
    connector_id: String,
    source_kind: String,
    capability: String,
    scope: String,
    operation: String,
    source_event_id: String,
    event_type: String,
    resource: Dict(String, StructuredValue),
    observed_at: Int,
    summary: String,
    normalized_data: Dict(String, StructuredValue),
    raw_ref: String,
    content_hash: String,
    provenance: Dict(String, StructuredValue),
    candidate_domain_refs: List(String),
    candidate_concern_refs: List(String),
    verification_status: String,
    authority_grants: List(String),
  )
}

/// An immutable authorization for OAuth and connector identity preparation.
pub type CanaryPreparationAuthorizationV1 {
  CanaryPreparationAuthorizationV1(
    schema_version: Int,
    authorization_id: String,
    canary_id: String,
    oauth_client_ref: String,
    oauth_client_hash: String,
    connectors: List(PreparationConnectorV1),
    grants: List(String),
    expires_at_ms: Int,
    authorized_by_ref: String,
  )
}

/// One connector that an authorization permits during preparation only.
pub type PreparationConnectorV1 {
  PreparationConnectorV1(
    connector_id: String,
    configuration_ref: String,
    oauth_scope: String,
    identity_endpoint_id: String,
  )
}

/// An immutable authorization for one bounded read-only canary trial.
pub type CanaryAuthorizationV1 {
  CanaryAuthorizationV1(
    schema_version: Int,
    authorization_id: String,
    preparation_authorization_id: String,
    canary_id: String,
    domain_id: String,
    concern_id: String,
    policy_refs: List(String),
    connectors: List(AuthorizedConnectorV1),
    activation_grants: List(String),
    monitor_id: String,
    monitor_capability_hash: String,
    monitor_runtime_ref: String,
    monitor_prompt_hash: String,
    monitor_interval_ms: Int,
    monitor_grants: List(String),
    attention_owner: String,
    attention_target: String,
    discord_delivery_allowed: Bool,
    starts_at_ms: Int,
    ends_at_ms: Int,
    metric_ids: List(String),
    metric_review_owner_ref: String,
    authorized_by_ref: String,
    rollback_owner_ref: String,
  )
}

/// The fixed configuration and read limits for one authorized connector.
pub type AuthorizedConnectorV1 {
  AuthorizedConnectorV1(
    connector_id: String,
    activation_id: String,
    configuration_ref: String,
    configuration_hash: String,
    account_fingerprint: String,
    oauth_proof_ref: String,
    identity_proof_ref: String,
    oauth_scope: String,
    capability: String,
    retention_policy_ref: String,
    poll_interval_ms: Int,
    max_pages_per_poll: Int,
    max_items_per_poll: Int,
    max_response_bytes: Int,
  )
}

/// A server-generated mutable activation record for one authorized connector.
pub type ConnectorActivationV1 {
  ConnectorActivationV1(
    schema_version: Int,
    activation_id: String,
    authorization_id: String,
    connector_id: String,
    domain_id: String,
    concern_id: String,
    configuration_ref: String,
    oauth_scope: String,
    state: String,
    version: Int,
    updated_at_ms: Int,
  )
}

/// Exact, bounded identity for a connector response accepted by Aura.
///
/// This context is checked again by SQLite. It contains no provider token,
/// request URL, response body, or user-facing transcript.
pub type ConnectorSubmissionContext {
  ConnectorSubmissionContext(
    activation_id: String,
    activation_version: Int,
    authorization_id: String,
    attempt_id: String,
    worker_id: String,
    connector_id: String,
    capability: String,
    oauth_scope: String,
    configuration_hash: String,
    account_fingerprint: String,
    domain_id: String,
    concern_id: String,
  )
}

pub type AttentionQueueItem {
  AttentionQueueItem(
    schema_version: Int,
    queue_id: String,
    decision_id: String,
    domain_id: String,
    concern_id: Option(String),
    event_refs: List(String),
    action: String,
    summary: String,
    rationale: String,
    why_now: Option(String),
    deferral_cost: Option(String),
    why_not_digest: Option(String),
    authority_request: Option(String),
    citations: List(String),
    state: String,
    delivery_owner: String,
    delivery_target: String,
    delivery_key: String,
    lease_owner: Option(String),
    lease_expires_at: Option(Int),
    attempt_count: Int,
    available_at: Int,
    expires_at: Option(Int),
    created_at: Int,
    updated_at: Int,
    version: Int,
  )
}

pub type MonitorClaimRequest {
  MonitorClaimRequest(
    schema_version: Int,
    monitor_id: String,
    authority_grants: List(String),
    lease_ms: Int,
    requested_at: Int,
  )
}

/// A caller-supplied monitor claim command. Aura supplies all clock values.
pub type AuthorizedMonitorClaimCommand {
  AuthorizedMonitorClaimCommand(
    schema_version: Int,
    command_id: String,
    authorization_id: String,
    monitor_runtime_ref: String,
    monitor_id: String,
    authority_grants: List(String),
    lease_ms: Int,
    capability_proof: String,
  )
}

pub type MonitorDomainContext {
  MonitorDomainContext(
    domain_id: String,
    source_ref: String,
    display_name: String,
    purpose: String,
    status: String,
  )
}

pub type MonitorConcernContext {
  MonitorConcernContext(
    concern_id: String,
    source_ref: String,
    status: String,
    summary: String,
  )
}

pub type MonitorAttentionEnvelope {
  MonitorAttentionEnvelope(
    schema_version: Int,
    queue_id: String,
    lease_token: String,
    lease_expires_at: Int,
    queue_version: Int,
    monitor_id: String,
    action: String,
    summary: String,
    rationale: String,
    why_now: Option(String),
    deferral_cost: Option(String),
    why_not_digest: Option(String),
    authority_request: Option(String),
    evidence_refs: List(String),
    policy_refs: List(String),
    domain_context: MonitorDomainContext,
    concern_context: Option(MonitorConcernContext),
    allowed_outcomes: List(String),
  )
}

pub type MonitorOutcome {
  MonitorOutcome(
    schema_version: Int,
    outcome_id: String,
    queue_id: String,
    lease_token: String,
    monitor_id: String,
    disposition: String,
    defer_until: Option(Int),
    codex_task_ref: Option(String),
    codex_conversation_ref: Option(String),
    codex_turn_ref: Option(String),
    authority_grants: List(String),
    occurred_at: Int,
  )
}

pub type MonitorOutcomeReceipt {
  MonitorOutcomeReceipt(
    schema_version: Int,
    outcome_id: String,
    queue_id: String,
    disposition: String,
    state: String,
    version: Int,
    audit_action: String,
  )
}

/// A caller-supplied monitor outcome command. Aura supplies the outcome time.
pub type AuthorizedMonitorOutcomeCommand {
  AuthorizedMonitorOutcomeCommand(
    schema_version: Int,
    command_id: String,
    authorization_id: String,
    monitor_runtime_ref: String,
    outcome_id: String,
    queue_id: String,
    lease_token: String,
    monitor_id: String,
    disposition: String,
    defer_until: Option(Int),
    codex_task_ref: Option(String),
    codex_conversation_ref: Option(String),
    codex_turn_ref: Option(String),
    authority_grants: List(String),
    capability_proof: String,
  )
}

pub type CommandMutation {
  CommandMutation(
    schema_version: Int,
    command_id: String,
    idempotency_key: String,
    origin: String,
    codex_task_ref: Option(String),
    codex_conversation_ref: Option(String),
    codex_turn_ref: Option(String),
    intent_kind: String,
    structured_payload: Dict(String, StructuredValue),
    creation_basis: String,
    issued_at: Int,
  )
}

pub type CodexWorkRequest {
  CodexWorkRequest(
    schema_version: Int,
    request_id: String,
    flare_id: String,
    domain_id: String,
    concern_id: String,
    objective: String,
    completion_requirements: List(String),
    evidence_refs: List(String),
    input_refs: List(String),
    capability_manifest: Dict(String, StructuredValue),
    authority_boundary: Dict(String, StructuredValue),
    codex_task_ref: Option(String),
    codex_conversation_ref: Option(String),
    codex_turn_ref: Option(String),
    idempotency_key: String,
    requested_at: Int,
  )
}

pub type CodexHandback {
  CodexHandback(
    schema_version: Int,
    request_id: String,
    flare_id: String,
    attempt_id: String,
    status: String,
    compact_outcome: String,
    proof_refs: List(String),
    check_results: List(String),
    artifact_refs: List(String),
    external_effect_receipts: List(String),
    open_gaps: List(String),
    codex_task_ref: Option(String),
    codex_conversation_ref: Option(String),
    completed_at: Int,
  )
}

/// Encode one domain contract as compact JSON.
pub fn encode_domain(value: Domain) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("domain_id", json.string(value.domain_id)),
    #("slug", json.string(value.slug)),
    #("display_name", json.string(value.display_name)),
    #("aliases", strings_json(value.aliases)),
    #("purpose", json.string(value.purpose)),
    #("status", json.string(value.status)),
    #("context_refs", strings_json(value.context_refs)),
    #(
      "default_authority_policy_ref",
      json.nullable(value.default_authority_policy_ref, of: json.string),
    ),
    #("cwd", json.nullable(value.cwd, of: json.string)),
    #("compatibility_transports", strings_json(value.compatibility_transports)),
    #("version", json.int(value.version)),
    #("created_at", json.int(value.created_at)),
    #("updated_at", json.int(value.updated_at)),
  ])
  |> json.to_string
}

/// Decode and validate one version-1 domain contract.
pub fn decode_domain(raw: String) -> Result(Domain, String) {
  parse_contract(raw, domain_decoder(), False)
}

fn domain_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use domain_id <- decode.field("domain_id", decode.string)
  use slug <- decode.field("slug", decode.string)
  use display_name <- decode.field("display_name", decode.string)
  use aliases <- decode.field("aliases", strings_decoder())
  use purpose <- decode.field("purpose", decode.string)
  use status <- decode.field(
    "status",
    enum_decoder(["active", "paused", "archived"], "domain status"),
  )
  use context_refs <- decode.field("context_refs", strings_decoder())
  use default_authority_policy_ref <- optional_string_field(
    "default_authority_policy_ref",
  )
  use cwd <- optional_string_field("cwd")
  use compatibility_transports <- decode.field(
    "compatibility_transports",
    strings_decoder(),
  )
  use version <- decode.field("version", decode.int)
  use created_at <- decode.field("created_at", decode.int)
  use updated_at <- decode.field("updated_at", decode.int)
  decode.success(Domain(
    schema_version:,
    domain_id:,
    slug:,
    display_name:,
    aliases:,
    purpose:,
    status:,
    context_refs:,
    default_authority_policy_ref:,
    cwd:,
    compatibility_transports:,
    version:,
    created_at:,
    updated_at:,
  ))
}

/// Encode one concern contract as compact JSON.
pub fn encode_concern(value: Concern) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("concern_id", json.string(value.concern_id)),
    #("domain_id", json.string(value.domain_id)),
    #("slug", json.string(value.slug)),
    #("title", json.string(value.title)),
    #("status", json.string(value.status)),
    #("summary", json.string(value.summary)),
    #("why", json.string(value.why)),
    #("current_state", json.string(value.current_state)),
    #("watch_conditions", strings_json(value.watch_conditions)),
    #("authority_boundary", structured_dict_json(value.authority_boundary)),
    #("gaps", strings_json(value.gaps)),
    #("evidence_refs", strings_json(value.evidence_refs)),
    #("work_refs", strings_json(value.work_refs)),
    #("policy_refs", strings_json(value.policy_refs)),
    #("version", json.int(value.version)),
    #("created_at", json.int(value.created_at)),
    #("updated_at", json.int(value.updated_at)),
  ])
  |> json.to_string
}

/// Decode and validate one version-1 concern contract.
pub fn decode_concern(raw: String) -> Result(Concern, String) {
  parse_contract(raw, concern_decoder(), False)
}

fn concern_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use concern_id <- decode.field("concern_id", decode.string)
  use domain_id <- decode.field("domain_id", decode.string)
  use slug <- decode.field("slug", decode.string)
  use title <- decode.field("title", decode.string)
  use status <- decode.field(
    "status",
    enum_decoder(["active", "paused", "closed"], "concern status"),
  )
  use summary <- decode.field("summary", decode.string)
  use why <- decode.field("why", decode.string)
  use current_state <- decode.field("current_state", decode.string)
  use watch_conditions <- decode.field("watch_conditions", strings_decoder())
  use authority_boundary <- decode.field(
    "authority_boundary",
    structured_dict_decoder(),
  )
  use gaps <- decode.field("gaps", strings_decoder())
  use evidence_refs <- decode.field("evidence_refs", strings_decoder())
  use work_refs <- decode.field("work_refs", strings_decoder())
  use policy_refs <- decode.field("policy_refs", strings_decoder())
  use version <- decode.field("version", decode.int)
  use created_at <- decode.field("created_at", decode.int)
  use updated_at <- decode.field("updated_at", decode.int)
  decode.success(Concern(
    schema_version:,
    concern_id:,
    domain_id:,
    slug:,
    title:,
    status:,
    summary:,
    why:,
    current_state:,
    watch_conditions:,
    authority_boundary:,
    gaps:,
    evidence_refs:,
    work_refs:,
    policy_refs:,
    version:,
    created_at:,
    updated_at:,
  ))
}

/// Encode one normalized evidence event as compact JSON.
pub fn encode_evidence_event(value: EvidenceEvent) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("event_id", json.string(value.event_id)),
    #("source", json.string(value.source)),
    #("source_kind", json.string(value.source_kind)),
    #("event_type", json.string(value.event_type)),
    #("external_id", json.nullable(value.external_id, of: json.string)),
    #("resource", structured_dict_json(value.resource)),
    #("observed_at", json.int(value.observed_at)),
    #("summary", json.string(value.summary)),
    #("normalized_data", structured_dict_json(value.normalized_data)),
    #("raw_ref", json.nullable(value.raw_ref, of: json.string)),
    #("content_hash", json.string(value.content_hash)),
    #("provenance", structured_dict_json(value.provenance)),
    #("candidate_domain_refs", strings_json(value.candidate_domain_refs)),
    #("candidate_concern_refs", strings_json(value.candidate_concern_refs)),
    #("verification_status", json.string(value.verification_status)),
  ])
  |> json.to_string
}

/// Decode and validate one version-1 normalized evidence event.
pub fn decode_evidence_event(raw: String) -> Result(EvidenceEvent, String) {
  parse_contract(raw, evidence_event_decoder(), True)
}

/// Encode one connector result as compact JSON.
pub fn encode_connector_result(value: ConnectorResult) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("connector_id", json.string(value.connector_id)),
    #("source_kind", json.string(value.source_kind)),
    #("capability", json.string(value.capability)),
    #("scope", json.string(value.scope)),
    #("operation", json.string(value.operation)),
    #("source_event_id", json.string(value.source_event_id)),
    #("event_type", json.string(value.event_type)),
    #("resource", structured_dict_json(value.resource)),
    #("observed_at", json.int(value.observed_at)),
    #("summary", json.string(value.summary)),
    #("normalized_data", structured_dict_json(value.normalized_data)),
    #("raw_ref", json.string(value.raw_ref)),
    #("content_hash", json.string(value.content_hash)),
    #("provenance", structured_dict_json(value.provenance)),
    #("candidate_domain_refs", strings_json(value.candidate_domain_refs)),
    #("candidate_concern_refs", strings_json(value.candidate_concern_refs)),
    #("verification_status", json.string(value.verification_status)),
    #("authority_grants", strings_json(value.authority_grants)),
  ])
  |> json.to_string
}

/// Decode and validate one version-1 connector result without transcript data.
pub fn decode_connector_result(raw: String) -> Result(ConnectorResult, String) {
  parse_contract(raw, connector_result_decoder(), True)
}

fn connector_result_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use connector_id <- decode.field("connector_id", decode.string)
  use source_kind <- decode.field(
    "source_kind",
    enum_decoder(
      ["connector", "mcp_tool", "codex", "claude"],
      "connector source kind",
    ),
  )
  use capability <- decode.field("capability", decode.string)
  use scope <- decode.field("scope", decode.string)
  use operation <- decode.field(
    "operation",
    enum_decoder(["read", "write"], "connector operation"),
  )
  use source_event_id <- decode.field("source_event_id", decode.string)
  use event_type <- decode.field("event_type", decode.string)
  use resource <- decode.field("resource", structured_dict_decoder())
  use observed_at <- decode.field("observed_at", decode.int)
  use summary <- decode.field("summary", decode.string)
  use normalized_data <- decode.field(
    "normalized_data",
    structured_dict_decoder(),
  )
  use raw_ref <- decode.field("raw_ref", decode.string)
  use content_hash <- decode.field("content_hash", decode.string)
  use provenance <- decode.field("provenance", structured_dict_decoder())
  use candidate_domain_refs <- decode.field(
    "candidate_domain_refs",
    strings_decoder(),
  )
  use candidate_concern_refs <- decode.field(
    "candidate_concern_refs",
    strings_decoder(),
  )
  use verification_status <- decode.field(
    "verification_status",
    enum_decoder(
      ["verified", "unverified", "conflicting"],
      "connector verification status",
    ),
  )
  use authority_grants <- decode.field("authority_grants", strings_decoder())
  decode.success(ConnectorResult(
    schema_version:,
    connector_id:,
    source_kind:,
    capability:,
    scope:,
    operation:,
    source_event_id:,
    event_type:,
    resource:,
    observed_at:,
    summary:,
    normalized_data:,
    raw_ref:,
    content_hash:,
    provenance:,
    candidate_domain_refs:,
    candidate_concern_refs:,
    verification_status:,
    authority_grants:,
  ))
}

/// Encode one preparation authorization as canonical compact JSON.
pub fn encode_canary_preparation_authorization(
  value: CanaryPreparationAuthorizationV1,
) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("authorization_id", json.string(value.authorization_id)),
    #("canary_id", json.string(value.canary_id)),
    #("oauth_client_ref", json.string(value.oauth_client_ref)),
    #("oauth_client_hash", json.string(value.oauth_client_hash)),
    #("connectors", preparation_connectors_json(value.connectors)),
    #("grants", sorted_strings_json(value.grants)),
    #("expires_at_ms", json.int(value.expires_at_ms)),
    #("authorized_by_ref", json.string(value.authorized_by_ref)),
  ])
  |> json.to_string
}

/// Decode and validate one version-1 preparation authorization.
pub fn decode_canary_preparation_authorization(
  raw: String,
) -> Result(CanaryPreparationAuthorizationV1, String) {
  use value <- result.try(parse_canary_request_contract(
    raw,
    preparation_authorization_decoder(),
  ))
  use _ <- result.try(validate_preparation_authorization(value))
  Ok(value)
}

fn preparation_authorization_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use authorization_id <- decode.field("authorization_id", decode.string)
  use canary_id <- decode.field("canary_id", decode.string)
  use oauth_client_ref <- decode.field("oauth_client_ref", decode.string)
  use oauth_client_hash <- decode.field("oauth_client_hash", decode.string)
  use connectors <- decode.field(
    "connectors",
    decode.list(preparation_connector_decoder()),
  )
  use grants <- decode.field("grants", strings_decoder())
  use expires_at_ms <- decode.field("expires_at_ms", decode.int)
  use authorized_by_ref <- decode.field("authorized_by_ref", decode.string)
  decode.success(CanaryPreparationAuthorizationV1(
    schema_version:,
    authorization_id:,
    canary_id:,
    oauth_client_ref:,
    oauth_client_hash:,
    connectors:,
    grants:,
    expires_at_ms:,
    authorized_by_ref:,
  ))
}

fn preparation_connector_decoder() {
  use connector_id <- decode.field("connector_id", decode.string)
  use configuration_ref <- decode.field("configuration_ref", decode.string)
  use oauth_scope <- decode.field("oauth_scope", decode.string)
  use identity_endpoint_id <- decode.field(
    "identity_endpoint_id",
    decode.string,
  )
  decode.success(PreparationConnectorV1(
    connector_id:,
    configuration_ref:,
    oauth_scope:,
    identity_endpoint_id:,
  ))
}

fn preparation_connectors_json(values: List(PreparationConnectorV1)) {
  values
  |> list.sort(fn(a, b) { string.compare(a.connector_id, b.connector_id) })
  |> json.array(of: preparation_connector_json)
}

fn preparation_connector_json(value: PreparationConnectorV1) {
  json.object([
    #("connector_id", json.string(value.connector_id)),
    #("configuration_ref", json.string(value.configuration_ref)),
    #("oauth_scope", json.string(value.oauth_scope)),
    #("identity_endpoint_id", json.string(value.identity_endpoint_id)),
  ])
}

/// Encode one final canary authorization as canonical compact JSON.
pub fn encode_canary_authorization(value: CanaryAuthorizationV1) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("authorization_id", json.string(value.authorization_id)),
    #(
      "preparation_authorization_id",
      json.string(value.preparation_authorization_id),
    ),
    #("canary_id", json.string(value.canary_id)),
    #("domain_id", json.string(value.domain_id)),
    #("concern_id", json.string(value.concern_id)),
    #("policy_refs", sorted_strings_json(value.policy_refs)),
    #("connectors", authorized_connectors_json(value.connectors)),
    #("activation_grants", sorted_strings_json(value.activation_grants)),
    #("monitor_id", json.string(value.monitor_id)),
    #("monitor_capability_hash", json.string(value.monitor_capability_hash)),
    #("monitor_runtime_ref", json.string(value.monitor_runtime_ref)),
    #("monitor_prompt_hash", json.string(value.monitor_prompt_hash)),
    #("monitor_interval_ms", json.int(value.monitor_interval_ms)),
    #("monitor_grants", sorted_strings_json(value.monitor_grants)),
    #("attention_owner", json.string(value.attention_owner)),
    #("attention_target", json.string(value.attention_target)),
    #("discord_delivery_allowed", json.bool(value.discord_delivery_allowed)),
    #("starts_at_ms", json.int(value.starts_at_ms)),
    #("ends_at_ms", json.int(value.ends_at_ms)),
    #("metric_ids", sorted_strings_json(value.metric_ids)),
    #("metric_review_owner_ref", json.string(value.metric_review_owner_ref)),
    #("authorized_by_ref", json.string(value.authorized_by_ref)),
    #("rollback_owner_ref", json.string(value.rollback_owner_ref)),
  ])
  |> json.to_string
}

/// Decode and validate one version-1 final canary authorization.
pub fn decode_canary_authorization(
  raw: String,
) -> Result(CanaryAuthorizationV1, String) {
  use value <- result.try(parse_canary_request_contract(
    raw,
    canary_authorization_decoder(),
  ))
  use _ <- result.try(validate_canary_authorization(value))
  Ok(value)
}

fn canary_authorization_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use authorization_id <- decode.field("authorization_id", decode.string)
  use preparation_authorization_id <- decode.field(
    "preparation_authorization_id",
    decode.string,
  )
  use canary_id <- decode.field("canary_id", decode.string)
  use domain_id <- decode.field("domain_id", decode.string)
  use concern_id <- decode.field("concern_id", decode.string)
  use policy_refs <- decode.field("policy_refs", strings_decoder())
  use connectors <- decode.field(
    "connectors",
    decode.list(authorized_connector_decoder()),
  )
  use activation_grants <- decode.field("activation_grants", strings_decoder())
  use monitor_id <- decode.field("monitor_id", decode.string)
  use monitor_capability_hash <- decode.field(
    "monitor_capability_hash",
    decode.string,
  )
  use monitor_runtime_ref <- decode.field("monitor_runtime_ref", decode.string)
  use monitor_prompt_hash <- decode.field("monitor_prompt_hash", decode.string)
  use monitor_interval_ms <- decode.field("monitor_interval_ms", decode.int)
  use monitor_grants <- decode.field("monitor_grants", strings_decoder())
  use attention_owner <- decode.field("attention_owner", decode.string)
  use attention_target <- decode.field("attention_target", decode.string)
  use discord_delivery_allowed <- decode.field(
    "discord_delivery_allowed",
    decode.bool,
  )
  use starts_at_ms <- decode.field("starts_at_ms", decode.int)
  use ends_at_ms <- decode.field("ends_at_ms", decode.int)
  use metric_ids <- decode.field("metric_ids", strings_decoder())
  use metric_review_owner_ref <- decode.field(
    "metric_review_owner_ref",
    decode.string,
  )
  use authorized_by_ref <- decode.field("authorized_by_ref", decode.string)
  use rollback_owner_ref <- decode.field("rollback_owner_ref", decode.string)
  decode.success(CanaryAuthorizationV1(
    schema_version:,
    authorization_id:,
    preparation_authorization_id:,
    canary_id:,
    domain_id:,
    concern_id:,
    policy_refs:,
    connectors:,
    activation_grants:,
    monitor_id:,
    monitor_capability_hash:,
    monitor_runtime_ref:,
    monitor_prompt_hash:,
    monitor_interval_ms:,
    monitor_grants:,
    attention_owner:,
    attention_target:,
    discord_delivery_allowed:,
    starts_at_ms:,
    ends_at_ms:,
    metric_ids:,
    metric_review_owner_ref:,
    authorized_by_ref:,
    rollback_owner_ref:,
  ))
}

fn authorized_connector_decoder() {
  use connector_id <- decode.field("connector_id", decode.string)
  use activation_id <- decode.field("activation_id", decode.string)
  use configuration_ref <- decode.field("configuration_ref", decode.string)
  use configuration_hash <- decode.field("configuration_hash", decode.string)
  use account_fingerprint <- decode.field("account_fingerprint", decode.string)
  use oauth_proof_ref <- decode.field("oauth_proof_ref", decode.string)
  use identity_proof_ref <- decode.field("identity_proof_ref", decode.string)
  use oauth_scope <- decode.field("oauth_scope", decode.string)
  use capability <- decode.field("capability", decode.string)
  use retention_policy_ref <- decode.field(
    "retention_policy_ref",
    decode.string,
  )
  use poll_interval_ms <- decode.field("poll_interval_ms", decode.int)
  use max_pages_per_poll <- decode.field("max_pages_per_poll", decode.int)
  use max_items_per_poll <- decode.field("max_items_per_poll", decode.int)
  use max_response_bytes <- decode.field("max_response_bytes", decode.int)
  decode.success(AuthorizedConnectorV1(
    connector_id:,
    activation_id:,
    configuration_ref:,
    configuration_hash:,
    account_fingerprint:,
    oauth_proof_ref:,
    identity_proof_ref:,
    oauth_scope:,
    capability:,
    retention_policy_ref:,
    poll_interval_ms:,
    max_pages_per_poll:,
    max_items_per_poll:,
    max_response_bytes:,
  ))
}

fn authorized_connectors_json(values: List(AuthorizedConnectorV1)) {
  values
  |> list.sort(fn(a, b) { string.compare(a.connector_id, b.connector_id) })
  |> json.array(of: authorized_connector_json)
}

fn authorized_connector_json(value: AuthorizedConnectorV1) {
  json.object([
    #("connector_id", json.string(value.connector_id)),
    #("activation_id", json.string(value.activation_id)),
    #("configuration_ref", json.string(value.configuration_ref)),
    #("configuration_hash", json.string(value.configuration_hash)),
    #("account_fingerprint", json.string(value.account_fingerprint)),
    #("oauth_proof_ref", json.string(value.oauth_proof_ref)),
    #("identity_proof_ref", json.string(value.identity_proof_ref)),
    #("oauth_scope", json.string(value.oauth_scope)),
    #("capability", json.string(value.capability)),
    #("retention_policy_ref", json.string(value.retention_policy_ref)),
    #("poll_interval_ms", json.int(value.poll_interval_ms)),
    #("max_pages_per_poll", json.int(value.max_pages_per_poll)),
    #("max_items_per_poll", json.int(value.max_items_per_poll)),
    #("max_response_bytes", json.int(value.max_response_bytes)),
  ])
}

/// Encode one server-generated activation record as compact JSON.
pub fn encode_connector_activation(value: ConnectorActivationV1) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("activation_id", json.string(value.activation_id)),
    #("authorization_id", json.string(value.authorization_id)),
    #("connector_id", json.string(value.connector_id)),
    #("domain_id", json.string(value.domain_id)),
    #("concern_id", json.string(value.concern_id)),
    #("configuration_ref", json.string(value.configuration_ref)),
    #("oauth_scope", json.string(value.oauth_scope)),
    #("state", json.string(value.state)),
    #("version", json.int(value.version)),
    #("updated_at_ms", json.int(value.updated_at_ms)),
  ])
  |> json.to_string
}

/// Decode and validate one server-generated version-1 activation record.
pub fn decode_connector_activation(
  raw: String,
) -> Result(ConnectorActivationV1, String) {
  use value <- result.try(parse_contract(
    raw,
    connector_activation_decoder(),
    True,
  ))
  use _ <- result.try(validate_connector_activation(value))
  Ok(value)
}

fn connector_activation_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use activation_id <- decode.field("activation_id", decode.string)
  use authorization_id <- decode.field("authorization_id", decode.string)
  use connector_id <- decode.field("connector_id", decode.string)
  use domain_id <- decode.field("domain_id", decode.string)
  use concern_id <- decode.field("concern_id", decode.string)
  use configuration_ref <- decode.field("configuration_ref", decode.string)
  use oauth_scope <- decode.field("oauth_scope", decode.string)
  use state <- decode.field("state", decode.string)
  use version <- decode.field("version", decode.int)
  use updated_at_ms <- decode.field("updated_at_ms", decode.int)
  decode.success(ConnectorActivationV1(
    schema_version:,
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

fn evidence_event_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use event_id <- decode.field("event_id", decode.string)
  use source <- decode.field("source", decode.string)
  use source_kind <- decode.field(
    "source_kind",
    enum_decoder(
      ["connector", "mcp_tool", "codex", "claude", "hook", "schedule", "system"],
      "evidence source kind",
    ),
  )
  use event_type <- decode.field("event_type", decode.string)
  use external_id <- optional_string_field("external_id")
  use resource <- decode.field("resource", structured_dict_decoder())
  use observed_at <- decode.field("observed_at", decode.int)
  use summary <- decode.field("summary", decode.string)
  use normalized_data <- decode.field(
    "normalized_data",
    structured_dict_decoder(),
  )
  use raw_ref <- optional_string_field("raw_ref")
  use content_hash <- decode.field("content_hash", decode.string)
  use provenance <- decode.field("provenance", structured_dict_decoder())
  use candidate_domain_refs <- decode.field(
    "candidate_domain_refs",
    strings_decoder(),
  )
  use candidate_concern_refs <- decode.field(
    "candidate_concern_refs",
    strings_decoder(),
  )
  use verification_status <- decode.field(
    "verification_status",
    enum_decoder(
      ["verified", "unverified", "conflicting"],
      "evidence verification status",
    ),
  )
  decode.success(EvidenceEvent(
    schema_version:,
    event_id:,
    source:,
    source_kind:,
    event_type:,
    external_id:,
    resource:,
    observed_at:,
    summary:,
    normalized_data:,
    raw_ref:,
    content_hash:,
    provenance:,
    candidate_domain_refs:,
    candidate_concern_refs:,
    verification_status:,
  ))
}

/// Encode one attention queue item as compact JSON.
pub fn encode_attention_queue_item(value: AttentionQueueItem) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("queue_id", json.string(value.queue_id)),
    #("decision_id", json.string(value.decision_id)),
    #("domain_id", json.string(value.domain_id)),
    #("concern_id", json.nullable(value.concern_id, of: json.string)),
    #("event_refs", strings_json(value.event_refs)),
    #("action", json.string(value.action)),
    #("summary", json.string(value.summary)),
    #("rationale", json.string(value.rationale)),
    #("why_now", json.nullable(value.why_now, of: json.string)),
    #("deferral_cost", json.nullable(value.deferral_cost, of: json.string)),
    #("why_not_digest", json.nullable(value.why_not_digest, of: json.string)),
    #(
      "authority_request",
      json.nullable(value.authority_request, of: json.string),
    ),
    #("citations", strings_json(value.citations)),
    #("state", json.string(value.state)),
    #("delivery_owner", json.string(value.delivery_owner)),
    #("delivery_target", json.string(value.delivery_target)),
    #("delivery_key", json.string(value.delivery_key)),
    #("lease_owner", json.nullable(value.lease_owner, of: json.string)),
    #("lease_expires_at", json.nullable(value.lease_expires_at, of: json.int)),
    #("attempt_count", json.int(value.attempt_count)),
    #("available_at", json.int(value.available_at)),
    #("expires_at", json.nullable(value.expires_at, of: json.int)),
    #("created_at", json.int(value.created_at)),
    #("updated_at", json.int(value.updated_at)),
    #("version", json.int(value.version)),
  ])
  |> json.to_string
}

/// Decode and validate one version-1 attention queue item.
pub fn decode_attention_queue_item(
  raw: String,
) -> Result(AttentionQueueItem, String) {
  parse_contract(raw, attention_queue_item_decoder(), False)
}

/// Encode one Codex monitor claim request as compact JSON.
pub fn encode_monitor_claim_request(value: MonitorClaimRequest) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("monitor_id", json.string(value.monitor_id)),
    #("authority_grants", strings_json(value.authority_grants)),
    #("lease_ms", json.int(value.lease_ms)),
    #("requested_at", json.int(value.requested_at)),
  ])
  |> json.to_string
}

/// Decode a version-1 Codex monitor claim request without transcript data.
pub fn decode_monitor_claim_request(
  raw: String,
) -> Result(MonitorClaimRequest, String) {
  let decoder = {
    use schema_version <- decode.field("schema_version", version_decoder())
    use monitor_id <- decode.field("monitor_id", decode.string)
    use authority_grants <- decode.field("authority_grants", strings_decoder())
    use lease_ms <- decode.field("lease_ms", decode.int)
    use requested_at <- decode.field("requested_at", decode.int)
    decode.success(MonitorClaimRequest(
      schema_version:,
      monitor_id:,
      authority_grants:,
      lease_ms:,
      requested_at:,
    ))
  }
  parse_contract(raw, decoder, True)
}

/// Decode a claim command and reject caller-controlled clock or transcript data.
pub fn decode_authorized_monitor_claim_command(
  raw: String,
) -> Result(AuthorizedMonitorClaimCommand, String) {
  let decoder = {
    use schema_version <- decode.field("schema_version", version_decoder())
    use command_id <- decode.field("command_id", decode.string)
    use authorization_id <- decode.field("authorization_id", decode.string)
    use monitor_runtime_ref <- decode.field(
      "monitor_runtime_ref",
      decode.string,
    )
    use monitor_id <- decode.field("monitor_id", decode.string)
    use authority_grants <- decode.field("authority_grants", strings_decoder())
    use lease_ms <- decode.field("lease_ms", decode.int)
    use capability_proof <- decode.field("capability_proof", decode.string)
    decode.success(AuthorizedMonitorClaimCommand(
      schema_version:,
      command_id:,
      authorization_id:,
      monitor_runtime_ref:,
      monitor_id:,
      authority_grants:,
      lease_ms:,
      capability_proof:,
    ))
  }
  parse_monitor_command(raw, decoder)
}

/// Encode one caller-time-free authorized monitor claim command.
pub fn encode_authorized_monitor_claim_command(
  value: AuthorizedMonitorClaimCommand,
) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("command_id", json.string(value.command_id)),
    #("authorization_id", json.string(value.authorization_id)),
    #("monitor_runtime_ref", json.string(value.monitor_runtime_ref)),
    #("monitor_id", json.string(value.monitor_id)),
    #("authority_grants", sorted_strings_json(value.authority_grants)),
    #("lease_ms", json.int(value.lease_ms)),
    #("capability_proof", json.string(value.capability_proof)),
  ])
  |> json.to_string
}

/// Encode the complete claim mutation without its capability proof.
pub fn authorized_monitor_claim_proof_payload(
  value: AuthorizedMonitorClaimCommand,
) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("command_id", json.string(value.command_id)),
    #("authorization_id", json.string(value.authorization_id)),
    #("monitor_runtime_ref", json.string(value.monitor_runtime_ref)),
    #("monitor_id", json.string(value.monitor_id)),
    #("authority_grants", sorted_strings_json(value.authority_grants)),
    #("lease_ms", json.int(value.lease_ms)),
  ])
  |> json.to_string
}

/// Encode one compact Codex monitor attention envelope.
pub fn encode_monitor_attention_envelope(
  value: MonitorAttentionEnvelope,
) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("queue_id", json.string(value.queue_id)),
    #("lease_token", json.string(value.lease_token)),
    #("lease_expires_at", json.int(value.lease_expires_at)),
    #("queue_version", json.int(value.queue_version)),
    #("monitor_id", json.string(value.monitor_id)),
    #("action", json.string(value.action)),
    #("summary", json.string(value.summary)),
    #("rationale", json.string(value.rationale)),
    #("why_now", json.nullable(value.why_now, of: json.string)),
    #("deferral_cost", json.nullable(value.deferral_cost, of: json.string)),
    #("why_not_digest", json.nullable(value.why_not_digest, of: json.string)),
    #(
      "authority_request",
      json.nullable(value.authority_request, of: json.string),
    ),
    #("evidence_refs", strings_json(value.evidence_refs)),
    #("policy_refs", strings_json(value.policy_refs)),
    #("domain_context", monitor_domain_context_json(value.domain_context)),
    #(
      "concern_context",
      json.nullable(value.concern_context, of: monitor_concern_context_json),
    ),
    #("allowed_outcomes", strings_json(value.allowed_outcomes)),
  ])
  |> json.to_string
}

/// Decode one version-1 compact Codex monitor attention envelope.
pub fn decode_monitor_attention_envelope(
  raw: String,
) -> Result(MonitorAttentionEnvelope, String) {
  let decoder = {
    use schema_version <- decode.field("schema_version", version_decoder())
    use queue_id <- decode.field("queue_id", decode.string)
    use lease_token <- decode.field("lease_token", decode.string)
    use lease_expires_at <- decode.field("lease_expires_at", decode.int)
    use queue_version <- decode.field("queue_version", decode.int)
    use monitor_id <- decode.field("monitor_id", decode.string)
    use action <- decode.field(
      "action",
      enum_decoder(["surface_now", "ask_now"], "monitor action"),
    )
    use summary <- decode.field("summary", decode.string)
    use rationale <- decode.field("rationale", decode.string)
    use why_now <- optional_string_field("why_now")
    use deferral_cost <- optional_string_field("deferral_cost")
    use why_not_digest <- optional_string_field("why_not_digest")
    use authority_request <- optional_string_field("authority_request")
    use evidence_refs <- decode.field("evidence_refs", strings_decoder())
    use policy_refs <- decode.field("policy_refs", strings_decoder())
    use domain_context <- decode.field(
      "domain_context",
      monitor_domain_context_decoder(),
    )
    use concern_context <- decode.field(
      "concern_context",
      decode.optional(monitor_concern_context_decoder()),
    )
    use allowed_outcomes <- decode.field("allowed_outcomes", strings_decoder())
    decode.success(MonitorAttentionEnvelope(
      schema_version:,
      queue_id:,
      lease_token:,
      lease_expires_at:,
      queue_version:,
      monitor_id:,
      action:,
      summary:,
      rationale:,
      why_now:,
      deferral_cost:,
      why_not_digest:,
      authority_request:,
      evidence_refs:,
      policy_refs:,
      domain_context:,
      concern_context:,
      allowed_outcomes:,
    ))
  }
  parse_contract(raw, decoder, True)
}

fn monitor_domain_context_json(value: MonitorDomainContext) {
  json.object([
    #("domain_id", json.string(value.domain_id)),
    #("source_ref", json.string(value.source_ref)),
    #("display_name", json.string(value.display_name)),
    #("purpose", json.string(value.purpose)),
    #("status", json.string(value.status)),
  ])
}

fn monitor_concern_context_json(value: MonitorConcernContext) {
  json.object([
    #("concern_id", json.string(value.concern_id)),
    #("source_ref", json.string(value.source_ref)),
    #("status", json.string(value.status)),
    #("summary", json.string(value.summary)),
  ])
}

fn monitor_domain_context_decoder() {
  use domain_id <- decode.field("domain_id", decode.string)
  use source_ref <- decode.field("source_ref", decode.string)
  use display_name <- decode.field("display_name", decode.string)
  use purpose <- decode.field("purpose", decode.string)
  use status <- decode.field("status", decode.string)
  decode.success(MonitorDomainContext(
    domain_id:,
    source_ref:,
    display_name:,
    purpose:,
    status:,
  ))
}

fn monitor_concern_context_decoder() {
  use concern_id <- decode.field("concern_id", decode.string)
  use source_ref <- decode.field("source_ref", decode.string)
  use status <- decode.field("status", decode.string)
  use summary <- decode.field("summary", decode.string)
  decode.success(MonitorConcernContext(
    concern_id:,
    source_ref:,
    status:,
    summary:,
  ))
}

/// Encode one Codex monitor outcome as canonical compact JSON.
pub fn encode_monitor_outcome(value: MonitorOutcome) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("outcome_id", json.string(value.outcome_id)),
    #("queue_id", json.string(value.queue_id)),
    #("lease_token", json.string(value.lease_token)),
    #("monitor_id", json.string(value.monitor_id)),
    #("disposition", json.string(value.disposition)),
    #("defer_until", json.nullable(value.defer_until, of: json.int)),
    #("codex_task_ref", json.nullable(value.codex_task_ref, of: json.string)),
    #(
      "codex_conversation_ref",
      json.nullable(value.codex_conversation_ref, of: json.string),
    ),
    #("codex_turn_ref", json.nullable(value.codex_turn_ref, of: json.string)),
    #("authority_grants", strings_json(value.authority_grants)),
    #("occurred_at", json.int(value.occurred_at)),
  ])
  |> json.to_string
}

/// Decode a version-1 Codex monitor outcome without transcript data.
pub fn decode_monitor_outcome(raw: String) -> Result(MonitorOutcome, String) {
  let decoder = {
    use schema_version <- decode.field("schema_version", version_decoder())
    use outcome_id <- decode.field("outcome_id", decode.string)
    use queue_id <- decode.field("queue_id", decode.string)
    use lease_token <- decode.field("lease_token", decode.string)
    use monitor_id <- decode.field("monitor_id", decode.string)
    use disposition <- decode.field(
      "disposition",
      enum_decoder(["acknowledge", "defer"], "monitor disposition"),
    )
    use defer_until <- optional_int_field("defer_until")
    use codex_task_ref <- optional_string_field("codex_task_ref")
    use codex_conversation_ref <- optional_string_field(
      "codex_conversation_ref",
    )
    use codex_turn_ref <- optional_string_field("codex_turn_ref")
    use authority_grants <- decode.field("authority_grants", strings_decoder())
    use occurred_at <- decode.field("occurred_at", decode.int)
    decode.success(MonitorOutcome(
      schema_version:,
      outcome_id:,
      queue_id:,
      lease_token:,
      monitor_id:,
      disposition:,
      defer_until:,
      codex_task_ref:,
      codex_conversation_ref:,
      codex_turn_ref:,
      authority_grants:,
      occurred_at:,
    ))
  }
  parse_contract(raw, decoder, True)
}

/// Decode an outcome command and reject caller-controlled clock or transcript data.
pub fn decode_authorized_monitor_outcome_command(
  raw: String,
) -> Result(AuthorizedMonitorOutcomeCommand, String) {
  let decoder = {
    use schema_version <- decode.field("schema_version", version_decoder())
    use command_id <- decode.field("command_id", decode.string)
    use authorization_id <- decode.field("authorization_id", decode.string)
    use monitor_runtime_ref <- decode.field(
      "monitor_runtime_ref",
      decode.string,
    )
    use outcome_id <- decode.field("outcome_id", decode.string)
    use queue_id <- decode.field("queue_id", decode.string)
    use lease_token <- decode.field("lease_token", decode.string)
    use monitor_id <- decode.field("monitor_id", decode.string)
    use disposition <- decode.field(
      "disposition",
      enum_decoder(["acknowledge", "defer"], "monitor disposition"),
    )
    use defer_until <- optional_int_field("defer_until")
    use codex_task_ref <- optional_string_field("codex_task_ref")
    use codex_conversation_ref <- optional_string_field(
      "codex_conversation_ref",
    )
    use codex_turn_ref <- optional_string_field("codex_turn_ref")
    use authority_grants <- decode.field("authority_grants", strings_decoder())
    use capability_proof <- decode.field("capability_proof", decode.string)
    decode.success(AuthorizedMonitorOutcomeCommand(
      schema_version:,
      command_id:,
      authorization_id:,
      monitor_runtime_ref:,
      outcome_id:,
      queue_id:,
      lease_token:,
      monitor_id:,
      disposition:,
      defer_until:,
      codex_task_ref:,
      codex_conversation_ref:,
      codex_turn_ref:,
      authority_grants:,
      capability_proof:,
    ))
  }
  parse_monitor_command(raw, decoder)
}

/// Encode one caller-time-free authorized monitor outcome command.
pub fn encode_authorized_monitor_outcome_command(
  value: AuthorizedMonitorOutcomeCommand,
) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("command_id", json.string(value.command_id)),
    #("authorization_id", json.string(value.authorization_id)),
    #("monitor_runtime_ref", json.string(value.monitor_runtime_ref)),
    #("outcome_id", json.string(value.outcome_id)),
    #("queue_id", json.string(value.queue_id)),
    #("lease_token", json.string(value.lease_token)),
    #("monitor_id", json.string(value.monitor_id)),
    #("disposition", json.string(value.disposition)),
    #("defer_until", json.nullable(value.defer_until, of: json.int)),
    #("codex_task_ref", json.nullable(value.codex_task_ref, of: json.string)),
    #(
      "codex_conversation_ref",
      json.nullable(value.codex_conversation_ref, of: json.string),
    ),
    #("codex_turn_ref", json.nullable(value.codex_turn_ref, of: json.string)),
    #("authority_grants", sorted_strings_json(value.authority_grants)),
    #("capability_proof", json.string(value.capability_proof)),
  ])
  |> json.to_string
}

/// Encode the complete outcome mutation without its capability proof.
pub fn authorized_monitor_outcome_proof_payload(
  value: AuthorizedMonitorOutcomeCommand,
) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("command_id", json.string(value.command_id)),
    #("authorization_id", json.string(value.authorization_id)),
    #("monitor_runtime_ref", json.string(value.monitor_runtime_ref)),
    #("outcome_id", json.string(value.outcome_id)),
    #("queue_id", json.string(value.queue_id)),
    #("lease_token", json.string(value.lease_token)),
    #("monitor_id", json.string(value.monitor_id)),
    #("disposition", json.string(value.disposition)),
    #("defer_until", json.nullable(value.defer_until, of: json.int)),
    #("codex_task_ref", json.nullable(value.codex_task_ref, of: json.string)),
    #(
      "codex_conversation_ref",
      json.nullable(value.codex_conversation_ref, of: json.string),
    ),
    #("codex_turn_ref", json.nullable(value.codex_turn_ref, of: json.string)),
    #("authority_grants", sorted_strings_json(value.authority_grants)),
  ])
  |> json.to_string
}

/// Encode one server-generated monitor outcome receipt.
pub fn encode_monitor_outcome_receipt(value: MonitorOutcomeReceipt) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("outcome_id", json.string(value.outcome_id)),
    #("queue_id", json.string(value.queue_id)),
    #("disposition", json.string(value.disposition)),
    #("state", json.string(value.state)),
    #("version", json.int(value.version)),
    #("audit_action", json.string(value.audit_action)),
  ])
  |> json.to_string
}

/// Decode one server-generated monitor outcome receipt.
pub fn decode_monitor_outcome_receipt(
  raw: String,
) -> Result(MonitorOutcomeReceipt, String) {
  let decoder = {
    use schema_version <- decode.field("schema_version", version_decoder())
    use outcome_id <- decode.field("outcome_id", decode.string)
    use queue_id <- decode.field("queue_id", decode.string)
    use disposition <- decode.field("disposition", decode.string)
    use state <- decode.field("state", decode.string)
    use version <- decode.field("version", decode.int)
    use audit_action <- decode.field("audit_action", decode.string)
    decode.success(MonitorOutcomeReceipt(
      schema_version:,
      outcome_id:,
      queue_id:,
      disposition:,
      state:,
      version:,
      audit_action:,
    ))
  }
  parse_contract(raw, decoder, True)
}

fn attention_queue_item_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use queue_id <- decode.field("queue_id", decode.string)
  use decision_id <- decode.field("decision_id", decode.string)
  use domain_id <- decode.field("domain_id", decode.string)
  use concern_id <- optional_string_field("concern_id")
  use event_refs <- decode.field("event_refs", strings_decoder())
  use action <- decode.field(
    "action",
    enum_decoder(["digest", "surface_now", "ask_now"], "attention action"),
  )
  use summary <- decode.field("summary", decode.string)
  use rationale <- decode.field("rationale", decode.string)
  use why_now <- optional_string_field("why_now")
  use deferral_cost <- optional_string_field("deferral_cost")
  use why_not_digest <- optional_string_field("why_not_digest")
  use authority_request <- optional_string_field("authority_request")
  use citations <- decode.field("citations", strings_decoder())
  use state <- decode.field(
    "state",
    enum_decoder(
      [
        "pending", "leased", "delivered", "acknowledged", "deferred", "expired",
        "dead_letter",
      ],
      "attention queue state",
    ),
  )
  use delivery_owner <- decode.field(
    "delivery_owner",
    enum_decoder(["codex", "discord_compat"], "delivery owner"),
  )
  use delivery_target <- optional_plain_string_field("delivery_target")
  use delivery_key <- decode.field("delivery_key", decode.string)
  use lease_owner <- optional_string_field("lease_owner")
  use lease_expires_at <- optional_int_field("lease_expires_at")
  use attempt_count <- decode.field("attempt_count", decode.int)
  use available_at <- decode.field("available_at", decode.int)
  use expires_at <- optional_int_field("expires_at")
  use created_at <- decode.field("created_at", decode.int)
  use updated_at <- decode.field("updated_at", decode.int)
  use version <- decode.field("version", decode.int)
  decode.success(AttentionQueueItem(
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
}

/// Encode one Voice-originated structured command mutation as compact JSON.
pub fn encode_command_mutation(value: CommandMutation) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("command_id", json.string(value.command_id)),
    #("idempotency_key", json.string(value.idempotency_key)),
    #("origin", json.string(value.origin)),
    #("codex_task_ref", json.nullable(value.codex_task_ref, of: json.string)),
    #(
      "codex_conversation_ref",
      json.nullable(value.codex_conversation_ref, of: json.string),
    ),
    #("codex_turn_ref", json.nullable(value.codex_turn_ref, of: json.string)),
    #("intent_kind", json.string(value.intent_kind)),
    #("structured_payload", structured_dict_json(value.structured_payload)),
    #("creation_basis", json.string(value.creation_basis)),
    #("issued_at", json.int(value.issued_at)),
  ])
  |> json.to_string
}

/// Decode a version-1 Voice command. Transcript-shaped fields are invalid.
pub fn decode_command_mutation(raw: String) -> Result(CommandMutation, String) {
  parse_contract(raw, command_mutation_decoder(), True)
}

fn command_mutation_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use command_id <- decode.field("command_id", decode.string)
  use idempotency_key <- decode.field("idempotency_key", decode.string)
  use origin <- decode.field(
    "origin",
    enum_decoder(["codex_voice"], "command origin"),
  )
  use codex_task_ref <- optional_string_field("codex_task_ref")
  use codex_conversation_ref <- optional_string_field("codex_conversation_ref")
  use codex_turn_ref <- optional_string_field("codex_turn_ref")
  use intent_kind <- decode.field("intent_kind", decode.string)
  use structured_payload <- decode.field(
    "structured_payload",
    structured_dict_decoder(),
  )
  use creation_basis <- decode.field(
    "creation_basis",
    enum_decoder(["explicit", "inferred", "confirmed"], "creation basis"),
  )
  use issued_at <- decode.field("issued_at", decode.int)
  decode.success(CommandMutation(
    schema_version:,
    command_id:,
    idempotency_key:,
    origin:,
    codex_task_ref:,
    codex_conversation_ref:,
    codex_turn_ref:,
    intent_kind:,
    structured_payload:,
    creation_basis:,
    issued_at:,
  ))
}

/// Encode one bounded Codex work request as compact JSON.
pub fn encode_codex_work_request(value: CodexWorkRequest) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("request_id", json.string(value.request_id)),
    #("flare_id", json.string(value.flare_id)),
    #("domain_id", json.string(value.domain_id)),
    #("concern_id", json.string(value.concern_id)),
    #("objective", json.string(value.objective)),
    #("completion_requirements", strings_json(value.completion_requirements)),
    #("evidence_refs", strings_json(value.evidence_refs)),
    #("input_refs", strings_json(value.input_refs)),
    #("capability_manifest", structured_dict_json(value.capability_manifest)),
    #("authority_boundary", structured_dict_json(value.authority_boundary)),
    #("codex_task_ref", json.nullable(value.codex_task_ref, of: json.string)),
    #(
      "codex_conversation_ref",
      json.nullable(value.codex_conversation_ref, of: json.string),
    ),
    #("codex_turn_ref", json.nullable(value.codex_turn_ref, of: json.string)),
    #("idempotency_key", json.string(value.idempotency_key)),
    #("requested_at", json.int(value.requested_at)),
  ])
  |> json.to_string
}

/// Decode and validate one version-1 Codex work request.
pub fn decode_codex_work_request(
  raw: String,
) -> Result(CodexWorkRequest, String) {
  parse_contract(raw, codex_work_request_decoder(), True)
}

fn codex_work_request_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use request_id <- decode.field("request_id", decode.string)
  use flare_id <- decode.field("flare_id", decode.string)
  use domain_id <- decode.field("domain_id", decode.string)
  use concern_id <- decode.field("concern_id", decode.string)
  use objective <- decode.field("objective", decode.string)
  use completion_requirements <- decode.field(
    "completion_requirements",
    strings_decoder(),
  )
  use evidence_refs <- decode.field("evidence_refs", strings_decoder())
  use input_refs <- decode.field("input_refs", strings_decoder())
  use capability_manifest <- decode.field(
    "capability_manifest",
    structured_dict_decoder(),
  )
  use authority_boundary <- decode.field(
    "authority_boundary",
    structured_dict_decoder(),
  )
  use codex_task_ref <- optional_string_field("codex_task_ref")
  use codex_conversation_ref <- optional_string_field("codex_conversation_ref")
  use codex_turn_ref <- optional_string_field("codex_turn_ref")
  use idempotency_key <- decode.field("idempotency_key", decode.string)
  use requested_at <- decode.field("requested_at", decode.int)
  decode.success(CodexWorkRequest(
    schema_version:,
    request_id:,
    flare_id:,
    domain_id:,
    concern_id:,
    objective:,
    completion_requirements:,
    evidence_refs:,
    input_refs:,
    capability_manifest:,
    authority_boundary:,
    codex_task_ref:,
    codex_conversation_ref:,
    codex_turn_ref:,
    idempotency_key:,
    requested_at:,
  ))
}

/// Encode one compact Codex work handback as compact JSON.
pub fn encode_codex_handback(value: CodexHandback) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("request_id", json.string(value.request_id)),
    #("flare_id", json.string(value.flare_id)),
    #("attempt_id", json.string(value.attempt_id)),
    #("status", json.string(value.status)),
    #("compact_outcome", json.string(value.compact_outcome)),
    #("proof_refs", strings_json(value.proof_refs)),
    #("check_results", strings_json(value.check_results)),
    #("artifact_refs", strings_json(value.artifact_refs)),
    #("external_effect_receipts", strings_json(value.external_effect_receipts)),
    #("open_gaps", strings_json(value.open_gaps)),
    #("codex_task_ref", json.nullable(value.codex_task_ref, of: json.string)),
    #(
      "codex_conversation_ref",
      json.nullable(value.codex_conversation_ref, of: json.string),
    ),
    #("completed_at", json.int(value.completed_at)),
  ])
  |> json.to_string
}

/// Decode a version-1 Codex handback. Transcript-shaped fields are invalid.
pub fn decode_codex_handback(raw: String) -> Result(CodexHandback, String) {
  parse_contract(raw, codex_handback_decoder(), True)
}

fn codex_handback_decoder() {
  use schema_version <- decode.field("schema_version", version_decoder())
  use request_id <- decode.field("request_id", decode.string)
  use flare_id <- decode.field("flare_id", decode.string)
  use attempt_id <- decode.field("attempt_id", decode.string)
  use status <- decode.field(
    "status",
    enum_decoder(
      ["completed", "blocked", "failed", "cancelled"],
      "Codex handback status",
    ),
  )
  use compact_outcome <- decode.field("compact_outcome", decode.string)
  use proof_refs <- decode.field("proof_refs", strings_decoder())
  use check_results <- decode.field("check_results", strings_decoder())
  use artifact_refs <- decode.field("artifact_refs", strings_decoder())
  use external_effect_receipts <- decode.field(
    "external_effect_receipts",
    strings_decoder(),
  )
  use open_gaps <- decode.field("open_gaps", strings_decoder())
  use codex_task_ref <- optional_string_field("codex_task_ref")
  use codex_conversation_ref <- optional_string_field("codex_conversation_ref")
  use completed_at <- decode.field("completed_at", decode.int)
  decode.success(CodexHandback(
    schema_version:,
    request_id:,
    flare_id:,
    attempt_id:,
    status:,
    compact_outcome:,
    proof_refs:,
    check_results:,
    artifact_refs:,
    external_effect_receipts:,
    open_gaps:,
    codex_task_ref:,
    codex_conversation_ref:,
    completed_at:,
  ))
}

fn validate_preparation_authorization(
  value: CanaryPreparationAuthorizationV1,
) -> Result(Nil, String) {
  use _ <- result.try(require_opaque_identifier(
    "authorization_id",
    value.authorization_id,
  ))
  use _ <- result.try(require_opaque_identifier("canary_id", value.canary_id))
  use _ <- result.try(require_opaque_identifier(
    "oauth_client_ref",
    value.oauth_client_ref,
  ))
  use _ <- result.try(require_hash("oauth_client_hash", value.oauth_client_hash))
  use _ <- result.try(require_nonempty_unique(
    "preparation_connector",
    value.connectors |> list.map(fn(connector) { connector.connector_id }),
  ))
  use _ <- result.try(list.try_each(
    value.connectors,
    validate_preparation_connector,
  ))
  use _ <- result.try(require_nonempty_unique("grant", value.grants))
  use _ <- result.try(case value.expires_at_ms > 0 {
    True -> Ok(Nil)
    False -> Error("invalid_preparation_authorization_expiry")
  })
  require_opaque_identifier("authorized_by_ref", value.authorized_by_ref)
}

fn validate_preparation_connector(
  value: PreparationConnectorV1,
) -> Result(Nil, String) {
  use _ <- result.try(require_opaque_identifier(
    "connector_id",
    value.connector_id,
  ))
  use _ <- result.try(require_opaque_identifier(
    "configuration_ref",
    value.configuration_ref,
  ))
  use _ <- result.try(require_oauth_scope(value.oauth_scope))
  require_opaque_identifier("identity_endpoint_id", value.identity_endpoint_id)
}

fn validate_canary_authorization(
  value: CanaryAuthorizationV1,
) -> Result(Nil, String) {
  use _ <- result.try(require_opaque_identifier(
    "authorization_id",
    value.authorization_id,
  ))
  use _ <- result.try(require_opaque_identifier(
    "preparation_authorization_id",
    value.preparation_authorization_id,
  ))
  use _ <- result.try(require_opaque_identifier("canary_id", value.canary_id))
  use _ <- result.try(require_opaque_identifier("domain_id", value.domain_id))
  use _ <- result.try(require_opaque_identifier("concern_id", value.concern_id))
  use _ <- result.try(require_nonempty_unique("policy_ref", value.policy_refs))
  use _ <- result.try(require_nonempty_unique(
    "authorized_connector",
    value.connectors |> list.map(fn(connector) { connector.connector_id }),
  ))
  use _ <- result.try(require_nonempty_unique(
    "activation_id",
    value.connectors |> list.map(fn(connector) { connector.activation_id }),
  ))
  use _ <- result.try(list.try_each(
    value.connectors,
    validate_authorized_connector,
  ))
  use _ <- result.try(require_nonempty_unique(
    "activation_grant",
    value.activation_grants,
  ))
  use _ <- result.try(require_opaque_identifier("monitor_id", value.monitor_id))
  use _ <- result.try(require_hash(
    "monitor_capability_hash",
    value.monitor_capability_hash,
  ))
  use _ <- result.try(require_opaque_identifier(
    "monitor_runtime_ref",
    value.monitor_runtime_ref,
  ))
  use _ <- result.try(require_hash(
    "monitor_prompt_hash",
    value.monitor_prompt_hash,
  ))
  use _ <- result.try(require_interval(
    "monitor_interval_ms",
    value.monitor_interval_ms,
  ))
  use _ <- result.try(require_nonempty_unique(
    "monitor_grant",
    value.monitor_grants,
  ))
  use _ <- result.try(
    case
      value.attention_owner == "codex"
      && value.attention_target == "codex_monitor"
    {
      True -> Ok(Nil)
      False -> Error("invalid_canary_attention_route")
    },
  )
  use _ <- result.try(case !value.discord_delivery_allowed {
    True -> Ok(Nil)
    False -> Error("canary_discord_delivery_not_permitted")
  })
  use _ <- result.try(
    case value.starts_at_ms >= 0 && value.ends_at_ms > value.starts_at_ms {
      True -> Ok(Nil)
      False -> Error("invalid_canary_authorization_time_range")
    },
  )
  use _ <- result.try(require_nonempty_unique("metric_id", value.metric_ids))
  use _ <- result.try(require_opaque_identifier(
    "metric_review_owner_ref",
    value.metric_review_owner_ref,
  ))
  use _ <- result.try(require_opaque_identifier(
    "authorized_by_ref",
    value.authorized_by_ref,
  ))
  require_opaque_identifier("rollback_owner_ref", value.rollback_owner_ref)
}

fn validate_authorized_connector(
  value: AuthorizedConnectorV1,
) -> Result(Nil, String) {
  use _ <- result.try(require_opaque_identifier(
    "connector_id",
    value.connector_id,
  ))
  use _ <- result.try(require_opaque_identifier(
    "activation_id",
    value.activation_id,
  ))
  use _ <- result.try(require_opaque_identifier(
    "configuration_ref",
    value.configuration_ref,
  ))
  use _ <- result.try(require_hash(
    "configuration_hash",
    value.configuration_hash,
  ))
  use _ <- result.try(require_hash(
    "account_fingerprint",
    value.account_fingerprint,
  ))
  use _ <- result.try(require_opaque_identifier(
    "oauth_proof_ref",
    value.oauth_proof_ref,
  ))
  use _ <- result.try(require_opaque_identifier(
    "identity_proof_ref",
    value.identity_proof_ref,
  ))
  use _ <- result.try(require_oauth_scope(value.oauth_scope))
  use _ <- result.try(require_opaque_identifier("capability", value.capability))
  use _ <- result.try(require_opaque_identifier(
    "retention_policy_ref",
    value.retention_policy_ref,
  ))
  use _ <- result.try(require_interval(
    "poll_interval_ms",
    value.poll_interval_ms,
  ))
  use _ <- result.try(require_limit(
    "max_pages_per_poll",
    value.max_pages_per_poll,
    100,
  ))
  use _ <- result.try(require_limit(
    "max_items_per_poll",
    value.max_items_per_poll,
    1000,
  ))
  require_limit("max_response_bytes", value.max_response_bytes, 1_048_576)
}

fn validate_connector_activation(
  value: ConnectorActivationV1,
) -> Result(Nil, String) {
  use _ <- result.try(require_opaque_identifier(
    "activation_id",
    value.activation_id,
  ))
  use _ <- result.try(require_opaque_identifier(
    "authorization_id",
    value.authorization_id,
  ))
  use _ <- result.try(require_opaque_identifier(
    "connector_id",
    value.connector_id,
  ))
  use _ <- result.try(require_opaque_identifier("domain_id", value.domain_id))
  use _ <- result.try(require_opaque_identifier("concern_id", value.concern_id))
  use _ <- result.try(require_opaque_identifier(
    "configuration_ref",
    value.configuration_ref,
  ))
  use _ <- result.try(require_oauth_scope(value.oauth_scope))
  use _ <- result.try(
    case
      list.contains(
        ["disabled", "enabling", "enabled", "disabling"],
        value.state,
      )
    {
      True -> Ok(Nil)
      False -> Error("invalid_connector_activation_state")
    },
  )
  case value.version > 0 && value.updated_at_ms >= 0 {
    True -> Ok(Nil)
    False -> Error("invalid_connector_activation_version_or_time")
  }
}

fn require_opaque_identifier(name: String, value: String) -> Result(Nil, String) {
  let valid_characters =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:"
  case
    value != ""
    && string.length(value) <= 256
    && {
      value
      |> string.to_graphemes
      |> list.all(fn(character) { string.contains(valid_characters, character) })
    }
  {
    True -> Ok(Nil)
    False -> Error("invalid_canary_" <> name)
  }
}

fn require_hash(name: String, value: String) -> Result(Nil, String) {
  let hexadecimal = "0123456789abcdef"
  case
    string.length(value) == 64
    && {
      value
      |> string.to_graphemes
      |> list.all(fn(character) { string.contains(hexadecimal, character) })
    }
  {
    True -> Ok(Nil)
    False -> Error("invalid_canary_" <> name)
  }
}

fn require_oauth_scope(value: String) -> Result(Nil, String) {
  case
    string.starts_with(value, "https://")
    && string.length(value) <= 512
    && !string.contains(value, " ")
    && !string.contains(value, "\n")
  {
    True -> Ok(Nil)
    False -> Error("invalid_canary_oauth_scope")
  }
}

fn require_nonempty_unique(
  name: String,
  values: List(String),
) -> Result(Nil, String) {
  use _ <- result.try(case values {
    [] -> Error("missing_canary_" <> name)
    _ -> Ok(Nil)
  })
  use _ <- result.try(
    list.try_each(values, fn(value) { require_opaque_identifier(name, value) }),
  )
  case list.length(list.unique(values)) == list.length(values) {
    True -> Ok(Nil)
    False -> Error("duplicate_canary_" <> name)
  }
}

fn require_interval(name: String, value: Int) -> Result(Nil, String) {
  case value >= 60_000 && value <= 86_400_000 {
    True -> Ok(Nil)
    False -> Error("invalid_canary_" <> name)
  }
}

fn require_limit(name: String, value: Int, maximum: Int) -> Result(Nil, String) {
  case value > 0 && value <= maximum {
    True -> Ok(Nil)
    False -> Error("invalid_canary_" <> name)
  }
}

fn parse_contract(
  raw: String,
  decoder: decode.Decoder(value),
  reject_transcript_fields: Bool,
) -> Result(value, String) {
  use dynamic_value <- result.try(
    json.parse(raw, decode.dynamic)
    |> result.map_error(fn(error) {
      "Invalid operational contract JSON: " <> string.inspect(error)
    }),
  )
  use _ <- result.try(
    case
      reject_transcript_fields
      && contains_forbidden_transcript_field(dynamic_value)
    {
      True -> Error("Raw conversation transcript fields are not permitted")
      False -> Ok(Nil)
    },
  )
  decode.run(dynamic_value, decoder)
  |> result.map_error(fn(error) {
    "Invalid operational contract: " <> string.inspect(error)
  })
}

fn parse_canary_request_contract(
  raw: String,
  decoder: decode.Decoder(value),
) -> Result(value, String) {
  use dynamic_value <- result.try(
    json.parse(raw, decode.dynamic)
    |> result.map_error(fn(error) {
      "Invalid operational contract JSON: " <> string.inspect(error)
    }),
  )
  use _ <- result.try(case contains_server_generated_time_field(dynamic_value) {
    True -> Error("Server-generated time fields are not permitted")
    False -> Ok(Nil)
  })
  parse_contract(raw, decoder, True)
}

fn parse_monitor_command(
  raw: String,
  decoder: decode.Decoder(value),
) -> Result(value, String) {
  use dynamic_value <- result.try(
    json.parse(raw, decode.dynamic)
    |> result.map_error(fn(error) {
      "Invalid operational contract JSON: " <> string.inspect(error)
    }),
  )
  use _ <- result.try(case contains_monitor_time_field(dynamic_value) {
    True -> Error("Caller time fields are not permitted")
    False -> Ok(Nil)
  })
  parse_contract(raw, decoder, True)
}

fn contains_monitor_time_field(value: Dynamic) -> Bool {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) ->
      fields
      |> dict.to_list
      |> list.any(fn(entry) {
        list.contains(
          [
            "requested_at",
            "occurred_at",
            "server_time",
            "created_at_ms",
            "updated_at_ms",
          ],
          entry.0,
        )
        || contains_monitor_time_field(entry.1)
      })
    Error(_) ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> list.any(items, contains_monitor_time_field)
        Error(_) -> False
      }
  }
}

fn contains_forbidden_transcript_field(value: Dynamic) -> Bool {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) ->
      fields
      |> dict.to_list
      |> list.any(fn(entry) {
        forbidden_transcript_key(entry.0)
        || contains_forbidden_transcript_field(entry.1)
      })
    Error(_) ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> list.any(items, contains_forbidden_transcript_field)
        Error(_) -> False
      }
  }
}

fn contains_server_generated_time_field(value: Dynamic) -> Bool {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) ->
      fields
      |> dict.to_list
      |> list.any(fn(entry) {
        list.contains(["created_at_ms", "updated_at_ms"], entry.0)
        || contains_server_generated_time_field(entry.1)
      })
    Error(_) ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(items) -> list.any(items, contains_server_generated_time_field)
        Error(_) -> False
      }
  }
}

fn forbidden_transcript_key(key: String) -> Bool {
  let compact =
    key
    |> string.lowercase
    |> string.replace(each: "-", with: "_")
    |> string.replace(each: "_", with: "")
    |> string.replace(each: " ", with: "")
    |> string.replace(each: ".", with: "")
  string.contains(compact, "transcript")
  || list.contains(
    [
      "rawtext", "rawvoicetext", "voicetext", "assistantresponse",
      "assistantmessage", "assistanttext", "usermessage", "usertext",
      "conversation", "conversationmessages", "messages", "prompt",
    ],
    compact,
  )
}

fn version_decoder() {
  use version <- decode.then(decode.int)
  case version == schema_version {
    True -> decode.success(version)
    False -> decode.failure(0, expected: "schema_version 1")
  }
}

fn enum_decoder(values: List(String), expected: String) {
  use value <- decode.then(decode.string)
  case list.contains(values, value) {
    True -> decode.success(value)
    False -> decode.failure("", expected: expected)
  }
}

fn optional_string_field(
  name: String,
  next: fn(Option(String)) -> decode.Decoder(value),
) {
  decode.optional_field(name, None, decode.optional(decode.string), next)
}

fn optional_plain_string_field(
  name: String,
  next: fn(String) -> decode.Decoder(value),
) {
  decode.optional_field(name, "", decode.string, next)
}

fn optional_int_field(
  name: String,
  next: fn(Option(Int)) -> decode.Decoder(value),
) {
  decode.optional_field(name, None, decode.optional(decode.int), next)
}

fn strings_decoder() {
  decode.list(decode.string)
}

fn structured_dict_decoder() {
  decode.dict(decode.string, structured_value_decoder())
}

fn strings_json(values: List(String)) {
  json.array(values, of: json.string)
}

fn sorted_strings_json(values: List(String)) {
  values
  |> list.sort(string.compare)
  |> strings_json
}

fn structured_value_decoder() -> decode.Decoder(StructuredValue) {
  use <- decode.recursive
  decode.one_of(
    decode.optional(decode.string)
      |> decode.map(fn(value) {
        case value {
          None -> StructuredNull
          Some(value) -> StructuredString(value)
        }
      }),
    or: [
      decode.int |> decode.map(StructuredInt),
      decode.float |> decode.map(StructuredFloat),
      decode.bool |> decode.map(StructuredBool),
      decode.list(structured_value_decoder()) |> decode.map(StructuredArray),
      decode.dict(decode.string, structured_value_decoder())
        |> decode.map(StructuredObject),
    ],
  )
}

fn structured_dict_json(values: Dict(String, StructuredValue)) {
  json.dict(values, fn(value) { value }, structured_value_json)
}

fn structured_value_json(value: StructuredValue) -> json.Json {
  case value {
    StructuredString(value) -> json.string(value)
    StructuredInt(value) -> json.int(value)
    StructuredFloat(value) -> json.float(value)
    StructuredBool(value) -> json.bool(value)
    StructuredNull -> json.null()
    StructuredArray(values) -> json.array(values, of: structured_value_json)
    StructuredObject(values) -> structured_dict_json(values)
  }
}
