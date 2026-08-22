import aura/operating_contracts
import gleam/dict
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn authorized_monitor_commands_reject_caller_time_and_transcript_test() {
  operating_contracts.decode_authorized_monitor_claim_command(
    "{\"schema_version\":1,\"authorization_id\":\"auth:one\",\"monitor_runtime_ref\":\"codex:runtime:one\",\"monitor_id\":\"monitor:one\",\"authority_grants\":[\"attention.read\",\"attention.claim\"],\"lease_ms\":1000,\"requested_at\":1}",
  )
  |> should.be_error
  operating_contracts.decode_authorized_monitor_outcome_command(
    "{\"schema_version\":1,\"authorization_id\":\"auth:one\",\"monitor_runtime_ref\":\"codex:runtime:one\",\"outcome_id\":\"outcome:one\",\"queue_id\":\"queue:one\",\"lease_token\":\"lease:one\",\"monitor_id\":\"monitor:one\",\"disposition\":\"acknowledge\",\"defer_until\":null,\"codex_task_ref\":null,\"codex_conversation_ref\":null,\"codex_turn_ref\":null,\"authority_grants\":[\"attention.acknowledge\"],\"occurred_at\":1}",
  )
  |> should.be_error
  operating_contracts.decode_authorized_monitor_claim_command(
    "{\"schema_version\":1,\"authorization_id\":\"auth:one\",\"monitor_runtime_ref\":\"codex:runtime:one\",\"monitor_id\":\"monitor:one\",\"authority_grants\":[\"attention.read\",\"attention.claim\"],\"lease_ms\":1000,\"transcript\":\"not allowed\"}",
  )
  |> should.be_error
}

fn string_map() {
  dict.from_list([
    #("kind", operating_contracts.StructuredString("reference")),
  ])
}

pub fn domain_contract_round_trips_test() {
  let value =
    operating_contracts.Domain(
      schema_version: 1,
      domain_id: "domain-1",
      slug: "personal-os",
      display_name: "Personal OS",
      aliases: ["os"],
      purpose: "Own operating context.",
      status: "active",
      context_refs: ["ref:context"],
      default_authority_policy_ref: Some("policy:default"),
      cwd: None,
      compatibility_transports: ["discord"],
      version: 3,
      created_at: 100,
      updated_at: 200,
    )

  value
  |> operating_contracts.encode_domain
  |> operating_contracts.decode_domain
  |> should.equal(Ok(value))
}

pub fn concern_contract_round_trips_test() {
  let value =
    operating_contracts.Concern(
      schema_version: 1,
      concern_id: "concern-1",
      domain_id: "domain-1",
      slug: "delivery-health",
      title: "Delivery health",
      status: "active",
      summary: "Watch delivery health.",
      why: "Prevent lost attention items.",
      current_state: "Stable.",
      watch_conditions: ["A delivery is uncertain."],
      authority_boundary: string_map(),
      gaps: [],
      evidence_refs: ["event:1"],
      work_refs: ["work:1"],
      policy_refs: ["policy:1"],
      version: 2,
      created_at: 100,
      updated_at: 200,
    )

  value
  |> operating_contracts.encode_concern
  |> operating_contracts.decode_concern
  |> should.equal(Ok(value))
}

pub fn evidence_event_contract_round_trips_test() {
  let value =
    operating_contracts.EvidenceEvent(
      schema_version: 1,
      event_id: "event-1",
      source: "hook",
      source_kind: "hook",
      event_type: "state.changed",
      external_id: Some("external-1"),
      resource: string_map(),
      observed_at: 100,
      summary: "A state changed.",
      normalized_data: string_map(),
      raw_ref: Some("source:external-1"),
      content_hash: "sha256:value",
      provenance: string_map(),
      candidate_domain_refs: ["domain-1"],
      candidate_concern_refs: ["concern-1"],
      verification_status: "verified",
    )

  value
  |> operating_contracts.encode_evidence_event
  |> operating_contracts.decode_evidence_event
  |> should.equal(Ok(value))
}

pub fn evidence_event_rejects_raw_transcript_fields_test() {
  let raw =
    "{\"schema_version\":1,\"event_id\":\"ev-1\",\"source\":\"codex\",\"source_kind\":\"codex\",\"event_type\":\"tool.result\",\"external_id\":\"x\",\"resource\":{},\"observed_at\":1,\"summary\":\"done\",\"normalized_data\":{\"raw_transcript\":\"copied conversation\"},\"raw_ref\":\"codex://task/1\",\"content_hash\":\"h\",\"provenance\":{},\"candidate_domain_refs\":[],\"candidate_concern_refs\":[],\"verification_status\":\"verified\"}"
  operating_contracts.decode_evidence_event(raw) |> should.be_error
}

pub fn attention_queue_contract_round_trips_test() {
  let value =
    operating_contracts.AttentionQueueItem(
      schema_version: 1,
      queue_id: "queue-1",
      decision_id: "decision-1",
      domain_id: "domain-1",
      concern_id: Some("concern-1"),
      event_refs: ["event-1"],
      action: "surface_now",
      summary: "Attention is needed.",
      rationale: "The deferral cost is high.",
      why_now: Some("A deadline is near."),
      deferral_cost: Some("A delivery can fail."),
      why_not_digest: Some("The deadline is near."),
      authority_request: None,
      citations: ["event-1"],
      state: "pending",
      delivery_owner: "discord_compat",
      delivery_target: "domain:delivery",
      delivery_key: "event-1",
      lease_owner: None,
      lease_expires_at: None,
      attempt_count: 0,
      available_at: 100,
      expires_at: Some(200),
      created_at: 100,
      updated_at: 100,
      version: 1,
    )

  value
  |> operating_contracts.encode_attention_queue_item
  |> operating_contracts.decode_attention_queue_item
  |> should.equal(Ok(value))
}

pub fn command_mutation_contract_round_trips_test() {
  let value =
    operating_contracts.CommandMutation(
      schema_version: 1,
      command_id: "command-1",
      idempotency_key: "key-1",
      origin: "codex_voice",
      codex_task_ref: Some("task:1"),
      codex_conversation_ref: Some("conversation:1"),
      codex_turn_ref: Some("turn:1"),
      intent_kind: "concern.update",
      structured_payload: dict.from_list([
        #(
          "conditions",
          operating_contracts.StructuredArray([
            operating_contracts.StructuredString("active"),
            operating_contracts.StructuredInt(2),
            operating_contracts.StructuredBool(True),
          ]),
        ),
        #(
          "metadata",
          operating_contracts.StructuredObject(
            dict.from_list([
              #("confidence", operating_contracts.StructuredFloat(0.75)),
              #("optional", operating_contracts.StructuredNull),
            ]),
          ),
        ),
      ]),
      creation_basis: "explicit",
      issued_at: 100,
    )

  value
  |> operating_contracts.encode_command_mutation
  |> operating_contracts.decode_command_mutation
  |> should.equal(Ok(value))
}

pub fn codex_work_contracts_round_trip_test() {
  let request =
    operating_contracts.CodexWorkRequest(
      schema_version: 1,
      request_id: "request-1",
      flare_id: "flare-1",
      domain_id: "domain-1",
      concern_id: "concern-1",
      objective: "Verify the condition.",
      completion_requirements: ["Provide proof."],
      evidence_refs: ["event-1"],
      input_refs: ["artifact-1"],
      capability_manifest: string_map(),
      authority_boundary: string_map(),
      codex_task_ref: Some("task:1"),
      codex_conversation_ref: None,
      codex_turn_ref: None,
      idempotency_key: "key-1",
      requested_at: 100,
    )
  let handback =
    operating_contracts.CodexHandback(
      schema_version: 1,
      request_id: "request-1",
      flare_id: "flare-1",
      attempt_id: "attempt-1",
      status: "completed",
      compact_outcome: "The condition passed.",
      proof_refs: ["proof-1"],
      check_results: ["check-1"],
      artifact_refs: ["artifact-1"],
      external_effect_receipts: [],
      open_gaps: [],
      codex_task_ref: Some("task:1"),
      codex_conversation_ref: None,
      completed_at: 200,
    )

  request
  |> operating_contracts.encode_codex_work_request
  |> operating_contracts.decode_codex_work_request
  |> should.equal(Ok(request))
  handback
  |> operating_contracts.encode_codex_handback
  |> operating_contracts.decode_codex_handback
  |> should.equal(Ok(handback))
}

pub fn command_mutation_rejects_nested_transcript_field_test() {
  let raw =
    json.object([
      #("schema_version", json.int(1)),
      #("command_id", json.string("command-1")),
      #("idempotency_key", json.string("key-1")),
      #("origin", json.string("codex_voice")),
      #("intent_kind", json.string("concern.update")),
      #(
        "structured_payload",
        json.object([#("conversation_transcript", json.string("raw content"))]),
      ),
      #("creation_basis", json.string("explicit")),
      #("issued_at", json.int(100)),
    ])
    |> json.to_string

  operating_contracts.decode_command_mutation(raw)
  |> should.be_error
}

pub fn codex_handback_rejects_raw_transcript_field_test() {
  let raw =
    json.object([
      #("schema_version", json.int(1)),
      #("request_id", json.string("request-1")),
      #("flare_id", json.string("flare-1")),
      #("attempt_id", json.string("attempt-1")),
      #("status", json.string("completed")),
      #("compact_outcome", json.string("Done.")),
      #("proof_refs", json.array([], of: json.string)),
      #("check_results", json.array([], of: json.string)),
      #("artifact_refs", json.array([], of: json.string)),
      #("external_effect_receipts", json.array([], of: json.string)),
      #("open_gaps", json.array([], of: json.string)),
      #("completed_at", json.int(100)),
      #("transcript_excerpt", json.string("raw content")),
    ])
    |> json.to_string

  operating_contracts.decode_codex_handback(raw)
  |> should.be_error
}

pub fn command_mutation_rejects_camel_case_raw_voice_text_test() {
  let raw =
    json.object([
      #("schema_version", json.int(1)),
      #("command_id", json.string("command-1")),
      #("idempotency_key", json.string("key-1")),
      #("origin", json.string("codex_voice")),
      #("intent_kind", json.string("concern.update")),
      #("structured_payload", json.object([])),
      #("creation_basis", json.string("explicit")),
      #("issued_at", json.int(100)),
      #("rawVoiceText", json.string("raw content")),
    ])
    |> json.to_string

  operating_contracts.decode_command_mutation(raw)
  |> should.be_error
}

pub fn codex_handback_rejects_camel_case_raw_text_test() {
  let raw =
    json.object([
      #("schema_version", json.int(1)),
      #("request_id", json.string("request-1")),
      #("flare_id", json.string("flare-1")),
      #("attempt_id", json.string("attempt-1")),
      #("status", json.string("completed")),
      #("compact_outcome", json.string("Done.")),
      #("proof_refs", json.array([], of: json.string)),
      #("check_results", json.array([], of: json.string)),
      #("artifact_refs", json.array([], of: json.string)),
      #("external_effect_receipts", json.array([], of: json.string)),
      #("open_gaps", json.array([], of: json.string)),
      #("completed_at", json.int(100)),
      #("rawText", json.string("raw content")),
    ])
    |> json.to_string

  operating_contracts.decode_codex_handback(raw)
  |> should.be_error
}

pub fn monitor_claim_and_outcome_codecs_reject_transcript_fields_test() {
  operating_contracts.decode_monitor_claim_request(
    "{\"schema_version\":1,\"monitor_id\":\"monitor:test\",\"authority_grants\":[\"attention.read\",\"attention.claim\"],\"lease_ms\":1000,\"requested_at\":100,\"voiceTranscript\":\"copied text\"}",
  )
  |> should.be_error
  operating_contracts.decode_monitor_outcome(
    "{\"schema_version\":1,\"outcome_id\":\"outcome:1\",\"queue_id\":\"attention:1\",\"lease_token\":\"lease\",\"monitor_id\":\"monitor:test\",\"disposition\":\"acknowledge\",\"defer_until\":null,\"codex_task_ref\":\"codex:task:1\",\"codex_conversation_ref\":null,\"codex_turn_ref\":null,\"authority_grants\":[\"attention.acknowledge\"],\"occurred_at\":100,\"assistant_response\":\"copied reply\"}",
  )
  |> should.be_error
}

pub fn codex_references_require_typed_opaque_identifiers_test() {
  operating_contracts.valid_codex_reference("codex:task:abc-123", "task")
  |> should.be_true
  operating_contracts.valid_codex_reference(
    "codex:task:assistant said hello",
    "task",
  )
  |> should.be_false
  operating_contracts.valid_codex_reference("codex:turn:abc", "task")
  |> should.be_false
  operating_contracts.valid_codex_reference("codex:task:abc:extra", "task")
  |> should.be_false
}

pub fn codecs_reject_unknown_schema_version_test() {
  let raw =
    operating_contracts.CommandMutation(
      schema_version: 2,
      command_id: "command-1",
      idempotency_key: "key-1",
      origin: "codex_voice",
      codex_task_ref: None,
      codex_conversation_ref: None,
      codex_turn_ref: None,
      intent_kind: "concern.update",
      structured_payload: dict.new(),
      creation_basis: "explicit",
      issued_at: 100,
    )
    |> operating_contracts.encode_command_mutation

  operating_contracts.decode_command_mutation(raw)
  |> should.be_error
}

pub fn canary_preparation_authorization_contract_round_trips_test() {
  let value = preparation_authorization()

  value
  |> operating_contracts.encode_canary_preparation_authorization
  |> operating_contracts.decode_canary_preparation_authorization
  |> should.equal(Ok(value))
}

pub fn canary_authorization_contract_round_trips_test() {
  let value = canary_authorization()

  value
  |> operating_contracts.encode_canary_authorization
  |> operating_contracts.decode_canary_authorization
  |> should.equal(Ok(value))
}

pub fn connector_activation_contract_round_trips_test() {
  let value = connector_activation()

  value
  |> operating_contracts.encode_connector_activation
  |> operating_contracts.decode_connector_activation
  |> should.equal(Ok(value))
}

pub fn canary_contracts_reject_invalid_authority_data_test() {
  operating_contracts.decode_canary_preparation_authorization(
    operating_contracts.CanaryPreparationAuthorizationV1(
      ..preparation_authorization(),
      schema_version: 2,
    )
    |> operating_contracts.encode_canary_preparation_authorization,
  )
  |> should.be_error

  operating_contracts.decode_canary_authorization(
    canary_authorization()
    |> operating_contracts.encode_canary_authorization
    |> string.replace(
      each: "\"ends_at_ms\":604800001",
      with: "\"ends_at_ms\":1",
    ),
  )
  |> should.be_error

  operating_contracts.decode_canary_preparation_authorization(
    preparation_authorization()
    |> operating_contracts.encode_canary_preparation_authorization
    |> string.replace(
      each: "https://www.googleapis.com/auth/gmail.readonly",
      with: "not-a-scope",
    ),
  )
  |> should.be_error

  operating_contracts.decode_canary_authorization(
    canary_authorization()
    |> operating_contracts.encode_canary_authorization
    |> string.replace(
      each: "\"attention_owner\":\"codex\"",
      with: "\"attention_owner\":\"discord\"",
    ),
  )
  |> should.be_error
}

pub fn canary_contracts_reject_duplicate_connectors_and_transcript_fields_test() {
  let duplicate = authorized_connector("gmail", "activation:gmail-2")
  operating_contracts.decode_canary_authorization(
    operating_contracts.CanaryAuthorizationV1(
      ..canary_authorization(),
      connectors: [
        authorized_connector("gmail", "activation:gmail-1"),
        duplicate,
      ],
    )
    |> operating_contracts.encode_canary_authorization,
  )
  |> should.be_error

  operating_contracts.decode_canary_preparation_authorization(
    preparation_authorization()
    |> operating_contracts.encode_canary_preparation_authorization
    |> string.replace(
      each: "\"authorized_by_ref\":\"operator:reviewer\"",
      with: "\"authorized_by_ref\":\"operator:reviewer\",\"conversation\":\"copied text\"",
    ),
  )
  |> should.be_error
}

pub fn canary_contracts_reject_missing_references_and_invalid_limits_test() {
  operating_contracts.decode_canary_authorization(
    canary_authorization()
    |> operating_contracts.encode_canary_authorization
    |> string.replace(
      each: "\"preparation_authorization_id\":\"authorization:preparation-1\"",
      with: "\"preparation_authorization_id\":\"\"",
    ),
  )
  |> should.be_error

  operating_contracts.decode_canary_authorization(
    canary_authorization()
    |> operating_contracts.encode_canary_authorization
    |> string.replace(
      each: "\"monitor_interval_ms\":60000",
      with: "\"monitor_interval_ms\":1",
    ),
  )
  |> should.be_error

  operating_contracts.decode_canary_authorization(
    canary_authorization()
    |> operating_contracts.encode_canary_authorization
    |> string.replace(
      each: "\"max_response_bytes\":4096",
      with: "\"max_response_bytes\":0",
    ),
  )
  |> should.be_error

  operating_contracts.decode_canary_authorization(
    canary_authorization()
    |> operating_contracts.encode_canary_authorization
    |> string.replace(
      each: "\"monitor_runtime_ref\":\"runtime:codex-monitor-local-test\"",
      with: "\"monitor_runtime_ref\":\"\"",
    ),
  )
  |> should.be_error
}

pub fn canary_authorization_rejects_caller_supplied_server_time_test() {
  operating_contracts.decode_canary_authorization(
    canary_authorization()
    |> operating_contracts.encode_canary_authorization
    |> string.replace(
      each: "\"rollback_owner_ref\":\"operator:rollback-owner\"",
      with: "\"rollback_owner_ref\":\"operator:rollback-owner\",\"created_at_ms\":1",
    ),
  )
  |> should.be_error
}

fn preparation_authorization() -> operating_contracts.CanaryPreparationAuthorizationV1 {
  operating_contracts.CanaryPreparationAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:preparation-1",
    canary_id: "canary:local-test",
    oauth_client_ref: "oauth-client:local-test",
    oauth_client_hash: hash("a"),
    connectors: [
      operating_contracts.PreparationConnectorV1(
        connector_id: "calendar",
        configuration_ref: "configuration:calendar-local-test",
        oauth_scope: "https://www.googleapis.com/auth/calendar.readonly",
        identity_endpoint_id: "calendar.calendars.get",
      ),
      operating_contracts.PreparationConnectorV1(
        connector_id: "gmail",
        configuration_ref: "configuration:gmail-local-test",
        oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
        identity_endpoint_id: "gmail.users.getProfile",
      ),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: 604_800_001,
    authorized_by_ref: "operator:reviewer",
  )
}

fn canary_authorization() -> operating_contracts.CanaryAuthorizationV1 {
  operating_contracts.CanaryAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:canary-1",
    preparation_authorization_id: "authorization:preparation-1",
    canary_id: "canary:local-test",
    domain_id: "domain:local-test",
    concern_id: "concern:domain:local-test:awareness",
    policy_refs: ["policy:canary:local-test"],
    connectors: [
      authorized_connector("calendar", "activation:calendar-1"),
      authorized_connector("gmail", "activation:gmail-1"),
    ],
    activation_grants: ["connector.disable", "connector.enable"],
    monitor_id: "monitor:local-test",
    monitor_capability_hash: hash("b"),
    monitor_runtime_ref: "runtime:codex-monitor-local-test",
    monitor_prompt_hash: hash("c"),
    monitor_interval_ms: 60_000,
    monitor_grants: ["attention.claim", "attention.read"],
    attention_owner: "codex",
    attention_target: "codex_monitor",
    discord_delivery_allowed: False,
    starts_at_ms: 1,
    ends_at_ms: 604_800_001,
    metric_ids: ["metric:evidence-captured"],
    metric_review_owner_ref: "operator:metrics-reviewer",
    authorized_by_ref: "operator:reviewer",
    rollback_owner_ref: "operator:rollback-owner",
  )
}

fn authorized_connector(
  connector_id: String,
  activation_id: String,
) -> operating_contracts.AuthorizedConnectorV1 {
  operating_contracts.AuthorizedConnectorV1(
    connector_id:,
    activation_id:,
    configuration_ref: "configuration:" <> connector_id <> "-local-test",
    configuration_hash: hash("d"),
    account_fingerprint: hash("e"),
    oauth_proof_ref: "proof:" <> connector_id <> "-oauth",
    identity_proof_ref: "proof:" <> connector_id <> "-identity",
    oauth_scope: "https://www.googleapis.com/auth/"
      <> connector_id
      <> ".readonly",
    capability: "read",
    retention_policy_ref: "retention:" <> connector_id <> "-compact",
    poll_interval_ms: 60_000,
    max_pages_per_poll: 1,
    max_items_per_poll: 10,
    max_response_bytes: 4096,
  )
}

fn connector_activation() -> operating_contracts.ConnectorActivationV1 {
  operating_contracts.ConnectorActivationV1(
    schema_version: 1,
    activation_id: "activation:gmail-1",
    authorization_id: "authorization:canary-1",
    connector_id: "gmail",
    domain_id: "domain:local-test",
    concern_id: "concern:domain:local-test:awareness",
    configuration_ref: "configuration:gmail-local-test",
    oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
    state: "disabled",
    version: 1,
    updated_at_ms: 1,
  )
}

fn hash(character: String) -> String {
  string.repeat(character, 64)
}
