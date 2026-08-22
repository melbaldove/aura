import aura/attention_queue
import aura/codex_monitor_runtime
import aura/connector_activation
import aura/ctl
import aura/db
import aura/domain_registry
import aura/google_execution_fixture
import aura/operating_contracts
import aura/secret
import aura/test_helpers
import aura/xdg
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
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

pub fn run_once_returns_empty_output_for_no_item_test() {
  let #(root, paths, raw_config) = runtime_fixture("no-item")
  let calls = process.new_subject()
  codex_monitor_runtime.run_once_with(paths, raw_config, fn(command) {
    process.send(calls, command)
    Ok("{\"ok\":true,\"attention\":null,\"server_time_ms\":100}")
  })
  |> should.equal(Ok(""))
  process.receive(calls, 100)
  |> should.be_ok
  |> string.starts_with("monitor claim ")
  |> should.be_true
  cleanup(root)
}

pub fn run_once_returns_only_one_compact_attention_envelope_test() {
  let #(root, paths, raw_config) = runtime_fixture("one-item")
  let envelope = compact_envelope()
  let response =
    "{\"ok\":true,\"attention\":"
    <> operating_contracts.encode_monitor_attention_envelope(envelope)
    <> ",\"server_time_ms\":100}"
  let output =
    codex_monitor_runtime.run_once_with(paths, raw_config, fn(_) {
      Ok(response)
    })
    |> should.be_ok
  output
  |> operating_contracts.decode_monitor_attention_envelope
  |> should.equal(Ok(envelope))
  let _ = string.contains(output, "transcript") |> should.be_false
  let output_is_compact = string.byte_size(output) < 16_384
  let _ = output_is_compact |> should.be_true
  cleanup(root)
}

pub fn wrong_or_missing_capability_fails_before_ctl_test() {
  let #(root, paths, raw_config) = runtime_fixture("wrong-capability")
  let calls = process.new_subject()
  let config = codex_monitor_runtime.decode_config(raw_config) |> should.be_ok
  secret.atomic_write(
    xdg.monitor_capability_path(paths, config.capability_sha256),
    "wrong-capability",
  )
  |> should.be_ok
  codex_monitor_runtime.run_once_with(paths, raw_config, fn(command) {
    process.send(calls, command)
    Ok("")
  })
  |> should.equal(Error("monitor_authentication_failed"))
  process.receive(calls, 0) |> should.be_error
  cleanup(root)
}

pub fn outcome_commands_are_signed_and_contain_no_caller_text_test() {
  let #(root, paths, raw_config) = runtime_fixture("outcome")
  let calls = process.new_subject()
  let receipt =
    operating_contracts.MonitorOutcomeReceipt(
      schema_version: 1,
      outcome_id: "codex:outcome:one",
      queue_id: "attention:event-one",
      disposition: "acknowledge",
      state: "acknowledged",
      version: 3,
      audit_action: "attention.monitor_acknowledged",
    )
  let response =
    "{\"ok\":true,\"receipt\":"
    <> operating_contracts.encode_monitor_outcome_receipt(receipt)
    <> ",\"server_time_ms\":100}"
  codex_monitor_runtime.acknowledge_with(
    paths,
    raw_config,
    "codex:outcome:one",
    "attention:event-one",
    "attention:event-one:1:monitor:test",
    Some("codex:task:one"),
    fn(command) {
      process.send(calls, command)
      Ok(response)
    },
  )
  |> should.equal(
    Ok(operating_contracts.encode_monitor_outcome_receipt(receipt)),
  )
  let command = process.receive(calls, 100) |> should.be_ok
  string.starts_with(command, "monitor outcome ") |> should.be_true
  string.contains(command, "message") |> should.be_false
  string.contains(command, "transcript") |> should.be_false
  cleanup(root)
}

pub fn reviewed_runtime_fixture_has_only_public_bounded_fields_test() {
  let raw =
    simplifile.read(
      "test/fixtures/canary/personal-life-codex-monitor-runtime.json",
    )
    |> should.be_ok
  codex_monitor_runtime.decode_config(raw) |> should.be_ok
  string.contains(raw, "token") |> should.be_false
  string.contains(raw, "transcript") |> should.be_false
  string.contains(raw, "message_body") |> should.be_false
}

pub fn runtime_reads_only_private_controlled_xdg_config_test() {
  let #(root, paths, raw_config) = runtime_fixture("xdg-config")
  let path = xdg.codex_monitor_runtime_config_path(paths)
  simplifile.create_directory_all(paths.config <> "/monitors") |> should.be_ok
  simplifile.write(path, raw_config) |> should.be_ok
  codex_monitor_runtime.run_once(paths)
  |> should.equal(Error("monitor_runtime_config_unavailable"))
  simplifile.delete(path) |> should.be_ok
  secret.atomic_write(path, raw_config) |> should.be_ok
  codex_monitor_runtime.run_once(paths)
  |> should.equal(Error("monitor_ctl_unavailable"))
  cleanup(root)
}

pub fn transcript_like_runtime_config_and_server_output_fail_closed_test() {
  let #(root, paths, raw_config) = runtime_fixture("transcript-rejection")
  codex_monitor_runtime.decode_config(
    string.drop_end(raw_config, 1) <> ",\"transcript\":\"copied words\"}",
  )
  |> should.equal(Error("invalid_monitor_runtime_config"))
  codex_monitor_runtime.run_once_with(paths, raw_config, fn(_) {
    Ok(
      "{\"ok\":true,\"attention\":{\"schema_version\":1,\"transcript\":\"copied words\"},\"server_time_ms\":100}",
    )
  })
  |> should.equal(Error("invalid_monitor_response"))
  cleanup(root)
}

pub fn successful_response_requires_explicit_attention_field_test() {
  let #(root, paths, raw_config) = runtime_fixture("missing-attention")
  codex_monitor_runtime.run_once_with(paths, raw_config, fn(_) {
    Ok("{\"ok\":true,\"server_time_ms\":100}")
  })
  |> should.equal(Error("invalid_monitor_response"))
  cleanup(root)
}

pub fn compact_limit_counts_utf8_bytes_test() {
  let #(root, paths, raw_config) = runtime_fixture("utf8-limit")
  let envelope =
    operating_contracts.MonitorAttentionEnvelope(
      ..compact_envelope(),
      summary: string.repeat("🙂", 5000),
    )
  let response =
    "{\"ok\":true,\"attention\":"
    <> operating_contracts.encode_monitor_attention_envelope(envelope)
    <> ",\"server_time_ms\":100}"
  codex_monitor_runtime.run_once_with(paths, raw_config, fn(_) { Ok(response) })
  |> should.equal(Error("monitor_output_too_large"))
  cleanup(root)
}

pub fn runtime_composes_real_ctl_claim_outcomes_replay_and_recovery_test() {
  let #(root, paths, db_subject, authorization, raw_config) =
    authorized_runtime_fixture("ctl-composition")
  start_ctl(paths, db_subject)

  let first =
    enqueue_authorized(
      db_subject,
      root <> "/aura.db",
      authorization,
      "runtime-ack",
    )
  let envelope =
    codex_monitor_runtime.run_once(paths)
    |> should.be_ok
    |> operating_contracts.decode_monitor_attention_envelope
    |> should.be_ok
  envelope.queue_id |> should.equal(first.queue_id)
  codex_monitor_runtime.run_once(paths) |> should.equal(Ok(""))

  let receipt =
    codex_monitor_runtime.acknowledge(
      paths,
      "codex:outcome:runtime-ack",
      envelope.queue_id,
      envelope.lease_token,
      Some("codex:task:runtime-ack"),
    )
    |> should.be_ok
  codex_monitor_runtime.acknowledge(
    paths,
    "codex:outcome:runtime-ack",
    envelope.queue_id,
    envelope.lease_token,
    Some("codex:task:runtime-ack"),
  )
  |> should.equal(Ok(receipt))
  db.get_attention(db_subject, first.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("acknowledged")

  let deferred =
    enqueue_authorized(
      db_subject,
      root <> "/aura.db",
      authorization,
      "runtime-defer",
    )
  let defer_envelope =
    codex_monitor_runtime.run_once(paths)
    |> should.be_ok
    |> operating_contracts.decode_monitor_attention_envelope
    |> should.be_ok
  let defer_until = 9_999_999_999_000
  codex_monitor_runtime.defer(
    paths,
    "codex:outcome:runtime-defer",
    defer_envelope.queue_id,
    defer_envelope.lease_token,
    defer_until,
    Some("codex:task:runtime-defer"),
  )
  |> should.be_ok
  db.get_attention(db_subject, deferred.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("deferred")

  let interrupted =
    enqueue_authorized(
      db_subject,
      root <> "/aura.db",
      authorization,
      "runtime-interrupted",
    )
  let short_config =
    string.replace(raw_config, "\"lease_ms\":60000", "\"lease_ms\":1")
  secret.atomic_write(
    xdg.codex_monitor_runtime_config_path(paths),
    short_config,
  )
  |> should.be_ok
  codex_monitor_runtime.run_once(paths) |> should.be_ok
  process.sleep(5)
  codex_monitor_runtime.run_once(paths) |> should.equal(Ok(""))
  db.get_attention(db_subject, interrupted.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("dead_letter")

  let audits =
    db.list_operational_audit(db_subject, "attention_queue", first.queue_id)
    |> should.be_ok
  list.any(audits, fn(record) {
    record.action == "attention.monitor_acknowledged"
  })
  |> should.be_true
  list.any(audits, fn(record) { string.contains(record.action, "discord") })
  |> should.be_false
  sqlite_count(root <> "/aura.db", "messages") |> should.equal(0)
  sqlite_count(root <> "/aura.db", "conversations") |> should.equal(0)

  ctl.cleanup(paths)
  process.send(db_subject, db.Shutdown)
  cleanup(root)
}

fn runtime_fixture(label: String) -> #(String, xdg.Paths, String) {
  let root =
    "/tmp/aura-monitor-runtime-" <> label <> "-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([root])
  let paths = xdg.resolve_with_home(root)
  let assert Ok(capability) =
    secret.prepare_monitor_capability_in(xdg.monitor_capabilities_dir(paths))
  let raw =
    "{\"schema_version\":1,\"authorization_id\":\"authorization:synthetic\",\"monitor_id\":\"monitor:synthetic\",\"monitor_runtime_ref\":\"codex:runtime:synthetic\",\"capability_sha256\":\""
    <> capability.sha256
    <> "\",\"lease_ms\":60000}"
  #(root, paths, raw)
}

fn compact_envelope() -> operating_contracts.MonitorAttentionEnvelope {
  operating_contracts.MonitorAttentionEnvelope(
    schema_version: 1,
    queue_id: "attention:event-one",
    lease_token: "attention:event-one:1:monitor:synthetic",
    lease_expires_at: 200,
    queue_version: 2,
    monitor_id: "monitor:synthetic",
    action: "surface_now",
    summary: "Review one verified condition.",
    rationale: "The policy threshold is met.",
    why_now: Some("The condition is active."),
    deferral_cost: None,
    why_not_digest: None,
    authority_request: None,
    evidence_refs: ["evidence:event-one"],
    policy_refs: ["policy:attention"],
    domain_context: operating_contracts.MonitorDomainContext(
      domain_id: "domain:personal-life",
      source_ref: "domains/personal-life/domain.json",
      display_name: "Personal Life",
      purpose: "Protect personal commitments.",
      status: "active",
    ),
    concern_context: Some(operating_contracts.MonitorConcernContext(
      concern_id: "concern:domain:personal-life:review",
      source_ref: "domains/personal-life/concerns/review.md",
      status: "active",
      summary: "Review one verified condition.",
    )),
    allowed_outcomes: ["acknowledge", "defer"],
  )
}

fn authorized_runtime_fixture(
  label: String,
) -> #(
  String,
  xdg.Paths,
  process.Subject(db.DbMessage),
  operating_contracts.CanaryAuthorizationV1,
  String,
) {
  let root =
    "/tmp/aura-monitor-runtime-authorized-"
    <> label
    <> "-"
    <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([root])
  let paths = xdg.resolve_with_home(root)
  simplifile.create_directory_all(paths.state) |> should.be_ok
  let assert Ok(db_subject) = db.start(root <> "/aura.db")
  let assert Ok(capability) =
    secret.prepare_monitor_capability_in(xdg.monitor_capabilities_dir(paths))
  let preparation = runtime_preparation_authorization()
  let authorization = runtime_authorization(capability.sha256)
  db.create_canary_preparation_authorization(db_subject, preparation)
  |> should.be_ok
  google_execution_fixture.seed_authorization_proofs(
    db_subject,
    preparation,
    authorization,
  )
  |> should.be_ok
  db.create_canary_authorization(db_subject, authorization) |> should.be_ok
  connector_activation.prepare_disabled(
    db_subject,
    authorization.authorization_id,
    "runtime-prepare",
    authorization.authorized_by_ref,
  )
  |> should.be_ok
  connector_activation.enable_set(
    db_subject,
    authorization.authorization_id,
    "runtime-enable",
    authorization.authorized_by_ref,
    ["connector.enable"],
  )
  |> should.be_ok
  write_runtime_domain(paths)
  let raw_config =
    "{\"schema_version\":1,\"authorization_id\":\""
    <> authorization.authorization_id
    <> "\",\"monitor_id\":\""
    <> authorization.monitor_id
    <> "\",\"monitor_runtime_ref\":\""
    <> authorization.monitor_runtime_ref
    <> "\",\"capability_sha256\":\""
    <> capability.sha256
    <> "\",\"lease_ms\":60000}"
  secret.atomic_write(xdg.codex_monitor_runtime_config_path(paths), raw_config)
  |> should.be_ok
  #(root, paths, db_subject, authorization, raw_config)
}

fn start_ctl(paths: xdg.Paths, db_subject: process.Subject(db.DbMessage)) {
  ctl.start(ctl.CtlContext(
    paths:,
    db_subject:,
    event_ingest_subject: process.new_subject(),
    cognitive_subject: process.new_subject(),
    delivery_subject: None,
    asks_subject: None,
    oauth_subject: process.new_subject(),
    connector_runtime_subject: process.new_subject(),
    connector_configurations: [],
    domains: [],
    dream_model: "",
    dream_budget_percent: 10,
    brain_context: 1000,
    started_at_ms: 0,
  ))
  |> should.be_ok
}

fn enqueue_authorized(
  db_subject: process.Subject(db.DbMessage),
  db_path: String,
  authorization: operating_contracts.CanaryAuthorizationV1,
  event_id: String,
) -> operating_contracts.AttentionQueueItem {
  let item =
    db.enqueue_attention(
      db_subject,
      attention_queue.EnqueueRequest(
        queue_id: "attention:" <> event_id,
        decision_id: event_id,
        domain_id: "sample",
        concern_id: Some("concern:domain:sample:review"),
        event_refs: [event_id, "evidence:" <> event_id],
        action: "surface_now",
        summary: "A verified condition needs review.",
        rationale: "The policy threshold is met.",
        why_now: Some("The condition is active."),
        deferral_cost: None,
        why_not_digest: Some("The digest window is too late."),
        authority_request: None,
        citations: ["evidence:" <> event_id, "policy:attention"],
        delivery_owner: "codex",
        delivery_target: "codex_monitor",
        delivery_key: "codex:" <> event_id,
        available_at: 0,
        expires_at: None,
      ),
    )
    |> should.be_ok
  let assert Ok(conn) = sqlight.open(db_path)
  let assert Ok(_) =
    sqlight.query(
      "UPDATE attention_queue SET schema_version = 2, route_authorization_id = ?, route_activation_ids_json = ? WHERE queue_id = ?",
      on: conn,
      with: [
        sqlight.text(authorization.authorization_id),
        sqlight.text(
          "[\"activation:calendar-runtime\",\"activation:gmail-runtime\"]",
        ),
        sqlight.text(item.queue_id),
      ],
      expecting: decode.success(Nil),
    )
  let _ = sqlight.close(conn)
  item
}

fn runtime_preparation_authorization() {
  operating_contracts.CanaryPreparationAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:runtime-preparation",
    canary_id: "canary:runtime",
    oauth_client_ref: "oauth-client:runtime",
    oauth_client_hash: hash64("oauth-client"),
    connectors: [
      runtime_preparation_connector("calendar"),
      runtime_preparation_connector("gmail"),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: 9_999_999_999_999,
    authorized_by_ref: "operator:runtime",
  )
}

fn runtime_preparation_connector(id: String) {
  operating_contracts.PreparationConnectorV1(
    connector_id: id,
    configuration_ref: "configuration:" <> id <> "-runtime",
    oauth_scope: "https://www.googleapis.com/auth/" <> id <> ".readonly",
    identity_endpoint_id: id <> ".identity",
  )
}

fn runtime_authorization(capability_hash: String) {
  operating_contracts.CanaryAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:runtime",
    preparation_authorization_id: "authorization:runtime-preparation",
    canary_id: "canary:runtime",
    domain_id: "domain:sample",
    concern_id: "concern:domain:sample:review",
    policy_refs: ["policy:runtime"],
    connectors: [
      runtime_connector("calendar", "activation:calendar-runtime"),
      runtime_connector("gmail", "activation:gmail-runtime"),
    ],
    activation_grants: ["connector.disable", "connector.enable"],
    monitor_id: "monitor:runtime",
    monitor_capability_hash: capability_hash,
    monitor_runtime_ref: "codex:runtime:personal-life-monitor-v1",
    monitor_prompt_hash: hash64("prompt"),
    monitor_interval_ms: 60_000,
    monitor_grants: [
      "attention.acknowledge",
      "attention.claim",
      "attention.defer",
      "attention.read",
    ],
    attention_owner: "codex",
    attention_target: "codex_monitor",
    discord_delivery_allowed: False,
    starts_at_ms: 0,
    ends_at_ms: 9_999_999_999_999,
    metric_ids: ["metric:runtime"],
    metric_review_owner_ref: "operator:runtime-metrics",
    authorized_by_ref: "operator:runtime",
    rollback_owner_ref: "operator:runtime-rollback",
  )
}

fn runtime_connector(id: String, activation_id: String) {
  operating_contracts.AuthorizedConnectorV1(
    connector_id: id,
    activation_id:,
    configuration_ref: "configuration:" <> id <> "-runtime",
    configuration_hash: hash64("configuration-" <> id),
    account_fingerprint: hash64("account-" <> id),
    oauth_proof_ref: "proof:" <> id <> "-oauth",
    identity_proof_ref: "proof:" <> id <> "-identity",
    oauth_scope: "https://www.googleapis.com/auth/" <> id <> ".readonly",
    capability: "read",
    retention_policy_ref: "retention:" <> id,
    poll_interval_ms: 60_000,
    max_pages_per_poll: 1,
    max_items_per_poll: 10,
    max_response_bytes: 4096,
  )
}

fn write_runtime_domain(paths: xdg.Paths) {
  domain_registry.write(
    paths,
    domain_registry.Record(
      domain_id: "domain:sample",
      slug: "sample",
      display_name: "Sample Domain",
      aliases: [],
      purpose: "Protect the selected operating context.",
      status: "active",
      cwd: None,
      discord_channel: None,
      version: 1,
      created_at: 100,
      updated_at: 100,
    ),
  )
  |> should.be_ok
  simplifile.create_directory_all(xdg.domain_concerns_dir(paths, "sample"))
  |> should.be_ok
  simplifile.write(
    xdg.domain_concerns_dir(paths, "sample") <> "/review.md",
    "# Review readiness\n\nStatus: active\nDomain-ID: domain:sample\nConcern-ID: concern:domain:sample:review\nSlug: review\nUpdated: 100\n\n## Summary\nCheck the evidence before acting.\n",
  )
  |> should.be_ok
}

fn sqlite_count(path: String, table: String) -> Int {
  let assert Ok(conn) = sqlight.open(path)
  let count_decoder = {
    use count <- decode.field(0, decode.int)
    decode.success(count)
  }
  let assert Ok([count]) =
    sqlight.query(
      "SELECT COUNT(*) FROM " <> table,
      on: conn,
      with: [],
      expecting: count_decoder,
    )
  let _ = sqlight.close(conn)
  count
}

fn hash64(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}

fn cleanup(root: String) {
  let _ = simplifile.delete_all([root])
  Nil
}
