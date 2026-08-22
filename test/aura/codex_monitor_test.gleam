import aura/attention_queue
import aura/codex_monitor
import aura/connector_activation
import aura/db
import aura/domain_registry
import aura/google_execution_fixture
import aura/operating_contracts
import aura/secret
import aura/test_helpers
import aura/time
import aura/xdg
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlight

pub fn main() {
  gleeunit.main()
}

fn fixture(label: String) -> #(String, xdg.Paths, process.Subject(db.DbMessage)) {
  let base =
    "/tmp/aura-codex-monitor-" <> label <> "-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  simplifile.create_directory_all(base) |> should.be_ok
  let paths = xdg.resolve_with_home(base)
  let now = 100
  domain_registry.write(
    paths,
    domain_registry.Record(
      domain_id: "domain:sample",
      slug: "sample",
      display_name: "Sample Domain",
      aliases: ["sample-work"],
      purpose: "Protect the selected operating context.",
      status: "active",
      cwd: None,
      discord_channel: None,
      version: 1,
      created_at: now,
      updated_at: now,
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
  let assert Ok(db_subject) = db.start(":memory:")
  #(base, paths, db_subject)
}

fn enqueue_codex(
  db_subject: process.Subject(db.DbMessage),
  event_id: String,
  now: Int,
) -> operating_contracts.AttentionQueueItem {
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
      deferral_cost: Some("A delay can increase risk."),
      why_not_digest: Some("The digest window is too late."),
      authority_request: Some("human_judgment"),
      citations: ["evidence:" <> event_id, "policy:attention.md"],
      delivery_owner: "codex",
      delivery_target: "codex_monitor",
      delivery_key: "codex:" <> event_id,
      available_at: now,
      expires_at: None,
    ),
  )
  |> should.be_ok
}

fn claim_request(now: Int) -> operating_contracts.MonitorClaimRequest {
  operating_contracts.MonitorClaimRequest(
    schema_version: 1,
    monitor_id: "monitor:test",
    authority_grants: ["attention.read", "attention.claim"],
    lease_ms: 10_000,
    requested_at: now,
  )
}

fn outcome(
  envelope: operating_contracts.MonitorAttentionEnvelope,
  outcome_id: String,
  disposition: String,
  grants: List(String),
  defer_until: Option(Int),
) -> operating_contracts.MonitorOutcome {
  operating_contracts.MonitorOutcome(
    schema_version: 1,
    outcome_id:,
    queue_id: envelope.queue_id,
    lease_token: envelope.lease_token,
    monitor_id: "monitor:test",
    disposition:,
    defer_until:,
    codex_task_ref: Some("codex:task:opaque"),
    codex_conversation_ref: Some("codex:conversation:opaque"),
    codex_turn_ref: Some("codex:turn:opaque"),
    authority_grants: grants,
    occurred_at: time.now_ms(),
  )
}

fn cleanup(base: String, db_subject: process.Subject(db.DbMessage)) -> Nil {
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn claim_requires_explicit_read_and_claim_authority_test() {
  let #(base, paths, db_subject) = fixture("claim-authority")
  let queued = enqueue_codex(db_subject, "event-authority", 100)
  let request =
    operating_contracts.MonitorClaimRequest(
      ..claim_request(101),
      authority_grants: ["attention.read"],
    )

  codex_monitor.claim(paths, db_subject, request)
  |> should.be_error
  |> string.contains("authority_denied")
  |> should.be_true
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("pending")
  cleanup(base, db_subject)
}

pub fn authorized_claim_and_outcome_require_exact_capability_and_route_test() {
  let #(base, paths, db_subject, authorization, queued) =
    authorized_fixture("authorized")
  let valid =
    signed_claim(paths, authorization, "codex:command:claim-authorized")

  codex_monitor.claim_authorized(
    paths,
    db_subject,
    operating_contracts.AuthorizedMonitorClaimCommand(
      ..valid,
      monitor_runtime_ref: "codex:runtime:wrong",
    ),
  )
  |> should.equal(Error("monitor_authentication_failed"))
  codex_monitor.claim_authorized(
    paths,
    db_subject,
    operating_contracts.AuthorizedMonitorClaimCommand(
      ..valid,
      command_id: "copied transcript text is not an opaque command reference",
    ),
  )
  |> should.equal(Error("monitor_authentication_failed"))
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("pending")

  codex_monitor.claim_authorized(
    paths,
    db_subject,
    operating_contracts.AuthorizedMonitorClaimCommand(
      ..valid,
      authorization_id: "authorization:wrong",
    ),
  )
  |> should.equal(Error("monitor_authentication_failed"))
  codex_monitor.claim_authorized(
    paths,
    db_subject,
    operating_contracts.AuthorizedMonitorClaimCommand(
      ..valid,
      monitor_id: "monitor:wrong",
    ),
  )
  |> should.equal(Error("monitor_authentication_failed"))
  codex_monitor.claim_authorized(
    paths,
    db_subject,
    operating_contracts.AuthorizedMonitorClaimCommand(
      ..valid,
      authority_grants: ["attention.read"],
    ),
  )
  |> should.equal(Error("monitor_authentication_failed"))

  let assert Ok(Some(envelope)) =
    codex_monitor.claim_authorized(paths, db_subject, valid)
  envelope.queue_id |> should.equal(queued.queue_id)
  envelope.domain_context.domain_id |> should.equal("domain:sample")
  codex_monitor.claim_authorized(paths, db_subject, valid)
  |> should.equal(Ok(None))
  let changed_claim = signed_claim(paths, authorization, valid.command_id)
  let changed_claim =
    operating_contracts.AuthorizedMonitorClaimCommand(
      ..changed_claim,
      lease_ms: 20_000,
      capability_proof: "",
    )
    |> sign_claim_command(paths, authorization)
  codex_monitor.claim_authorized(paths, db_subject, changed_claim)
  |> should.equal(Error("idempotency_conflict"))

  let assert Ok(_) =
    connector_activation.begin_disable_set(
      db_subject,
      authorization.authorization_id,
      "monitor-disable",
      authorization.rollback_owner_ref,
      ["connector.disable"],
    )
  let assert Ok(_) =
    connector_activation.finalize_disable_set(
      db_subject,
      authorization.authorization_id,
      "monitor-disable-finalize",
      authorization.rollback_owner_ref,
    )
  let outcome_command =
    signed_outcome(
      paths,
      authorization,
      operating_contracts.AuthorizedMonitorOutcomeCommand(
        schema_version: 1,
        command_id: "codex:command:outcome-authorized",
        authorization_id: authorization.authorization_id,
        monitor_runtime_ref: authorization.monitor_runtime_ref,
        outcome_id: "outcome:authorized",
        queue_id: envelope.queue_id,
        lease_token: envelope.lease_token,
        monitor_id: authorization.monitor_id,
        disposition: "acknowledge",
        defer_until: None,
        codex_task_ref: Some("codex:task:authorized"),
        codex_conversation_ref: None,
        codex_turn_ref: None,
        authority_grants: ["attention.acknowledge"],
        capability_proof: "",
      ),
    )
  let stale_outcome =
    signed_outcome(
      paths,
      authorization,
      operating_contracts.AuthorizedMonitorOutcomeCommand(
        ..outcome_command,
        command_id: "codex:command:outcome-stale",
        outcome_id: "outcome:stale-after-disable",
        lease_token: "stale-lease",
        capability_proof: "",
      ),
    )
  codex_monitor.submit_authorized_outcome(paths, db_subject, stale_outcome)
  |> should.equal(Error("lease_owner_mismatch_or_inactive"))
  let receipt =
    codex_monitor.submit_authorized_outcome(paths, db_subject, outcome_command)
    |> should.be_ok
  receipt.state |> should.equal("acknowledged")
  codex_monitor.submit_authorized_outcome(paths, db_subject, outcome_command)
  |> should.equal(Ok(receipt))
  let changed_outcome =
    signed_outcome(
      paths,
      authorization,
      operating_contracts.AuthorizedMonitorOutcomeCommand(
        ..outcome_command,
        command_id: "codex:command:outcome-changed",
        codex_task_ref: Some("codex:task:changed"),
        capability_proof: "",
      ),
    )
  codex_monitor.submit_authorized_outcome(paths, db_subject, changed_outcome)
  |> should.equal(Error("idempotency_conflict"))
  db.list_operational_audit(db_subject, "attention_queue", queued.queue_id)
  |> should.be_ok
  |> list.all(fn(record) {
    !string.contains(record.authority_ref |> option.unwrap(""), "capability")
  })
  |> should.be_true
  cleanup(base, db_subject)
}

pub fn authorized_claim_rechecks_route_authority_with_server_time_test() {
  let expires_at = time.now_ms() + 100
  let #(base, _, db_subject, authorization, queued) =
    authorized_fixture_with_end("expired-authority", expires_at)
  process.sleep(150)
  let route =
    db.MonitorRoute(
      authorization_id: authorization.authorization_id,
      activation_ids_json: "[\"activation:calendar-monitor\",\"activation:gmail-monitor\"]",
      domain_id: "sample",
      concern_id: authorization.concern_id,
      claim_command_id: "codex:command:expired",
      claim_payload_hash: hash64("expired"),
    )
  db.claim_authorized_attention(
    db_subject,
    authorization.monitor_id,
    10_000,
    route,
    0,
  )
  |> should.equal(Ok(None))
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("pending")
  cleanup(base, db_subject)

  let #(base, _, db_subject, authorization, queued) =
    authorized_fixture("atomic-authority")
  let route =
    db.MonitorRoute(
      authorization_id: authorization.authorization_id,
      activation_ids_json: "[\"activation:calendar-monitor\",\"activation:gmail-monitor\"]",
      domain_id: "sample",
      concern_id: authorization.concern_id,
      claim_command_id: "codex:command:disabled",
      claim_payload_hash: hash64("disabled"),
    )

  connector_activation.begin_disable_set(
    db_subject,
    authorization.authorization_id,
    "atomic-disable",
    authorization.rollback_owner_ref,
    ["connector.disable"],
  )
  |> should.be_ok
  connector_activation.finalize_disable_set(
    db_subject,
    authorization.authorization_id,
    "atomic-disable-finalize",
    authorization.rollback_owner_ref,
  )
  |> should.be_ok
  db.claim_authorized_attention(
    db_subject,
    authorization.monitor_id,
    10_000,
    route,
    time.now_ms(),
  )
  |> should.equal(Ok(None))
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("pending")
  cleanup(base, db_subject)
}

pub fn authorized_claim_rejects_wrong_domain_and_target_route_test() {
  let #(base, paths, db_subject, authorization, queued) =
    authorized_fixture("wrong-route")
  let assert Ok(conn) = sqlight.open(base <> "/aura.db")
  let assert Ok(_) =
    sqlight.query(
      "UPDATE attention_queue SET domain_id = 'other', delivery_target = 'other_target' WHERE queue_id = ?",
      on: conn,
      with: [sqlight.text(queued.queue_id)],
      expecting: decode.success(Nil),
    )
  let _ = sqlight.close(conn)
  codex_monitor.claim_authorized(
    paths,
    db_subject,
    signed_claim(paths, authorization, "codex:command:wrong-route"),
  )
  |> should.equal(Ok(None))
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("pending")
  cleanup(base, db_subject)
}

pub fn authorized_claim_fails_closed_for_wrong_capability_or_disabled_set_test() {
  let #(base, paths, db_subject, authorization, queued) =
    authorized_fixture("wrong-capability")
  let capability_path =
    xdg.monitor_capability_path(paths, authorization.monitor_capability_hash)
  let command =
    signed_claim(paths, authorization, "codex:command:wrong-capability")
  secret.atomic_write(capability_path, "synthetic-wrong-capability")
  |> should.be_ok
  codex_monitor.claim_authorized(paths, db_subject, command)
  |> should.equal(Error("monitor_authentication_failed"))
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("pending")
  cleanup(base, db_subject)

  let #(base, paths, db_subject, authorization, queued) =
    authorized_fixture("missing-capability")
  let command =
    signed_claim(paths, authorization, "codex:command:missing-capability")
  let _ =
    simplifile.delete_file(xdg.monitor_capability_path(
      paths,
      authorization.monitor_capability_hash,
    ))
  codex_monitor.claim_authorized(paths, db_subject, command)
  |> should.equal(Error("monitor_authentication_failed"))
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("pending")
  cleanup(base, db_subject)

  let #(base, paths, db_subject, authorization, queued) =
    authorized_fixture("disabled")
  let command = signed_claim(paths, authorization, "codex:command:disabled")
  connector_activation.begin_disable_set(
    db_subject,
    authorization.authorization_id,
    "disable-before-claim",
    authorization.rollback_owner_ref,
    ["connector.disable"],
  )
  |> should.be_ok
  connector_activation.finalize_disable_set(
    db_subject,
    authorization.authorization_id,
    "disable-before-claim-finalize",
    authorization.rollback_owner_ref,
  )
  |> should.be_ok
  codex_monitor.claim_authorized(paths, db_subject, command)
  |> should.equal(Error("monitor_authentication_failed"))
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("pending")
  cleanup(base, db_subject)
}

fn authorized_fixture(
  label: String,
) -> #(
  String,
  xdg.Paths,
  process.Subject(db.DbMessage),
  operating_contracts.CanaryAuthorizationV1,
  operating_contracts.AttentionQueueItem,
) {
  authorized_fixture_with_end(label, 9_999_999_999_999)
}

fn signed_claim(
  paths: xdg.Paths,
  authorization: operating_contracts.CanaryAuthorizationV1,
  command_id: String,
) -> operating_contracts.AuthorizedMonitorClaimCommand {
  let unsigned =
    operating_contracts.AuthorizedMonitorClaimCommand(
      schema_version: 1,
      command_id:,
      authorization_id: authorization.authorization_id,
      monitor_runtime_ref: authorization.monitor_runtime_ref,
      monitor_id: authorization.monitor_id,
      authority_grants: ["attention.read", "attention.claim"],
      lease_ms: 10_000,
      capability_proof: "",
    )
  let assert Ok(proof) =
    secret.sign_monitor_command(
      xdg.monitor_capability_path(paths, authorization.monitor_capability_hash),
      operating_contracts.authorized_monitor_claim_proof_payload(unsigned),
    )
  operating_contracts.AuthorizedMonitorClaimCommand(
    ..unsigned,
    capability_proof: proof,
  )
}

fn sign_claim_command(
  command: operating_contracts.AuthorizedMonitorClaimCommand,
  paths: xdg.Paths,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> operating_contracts.AuthorizedMonitorClaimCommand {
  let assert Ok(proof) =
    secret.sign_monitor_command(
      xdg.monitor_capability_path(paths, authorization.monitor_capability_hash),
      operating_contracts.authorized_monitor_claim_proof_payload(command),
    )
  operating_contracts.AuthorizedMonitorClaimCommand(
    ..command,
    capability_proof: proof,
  )
}

fn signed_outcome(
  paths: xdg.Paths,
  authorization: operating_contracts.CanaryAuthorizationV1,
  unsigned: operating_contracts.AuthorizedMonitorOutcomeCommand,
) -> operating_contracts.AuthorizedMonitorOutcomeCommand {
  let assert Ok(proof) =
    secret.sign_monitor_command(
      xdg.monitor_capability_path(paths, authorization.monitor_capability_hash),
      operating_contracts.authorized_monitor_outcome_proof_payload(unsigned),
    )
  operating_contracts.AuthorizedMonitorOutcomeCommand(
    ..unsigned,
    capability_proof: proof,
  )
}

fn authorized_fixture_with_end(
  label: String,
  ends_at_ms: Int,
) -> #(
  String,
  xdg.Paths,
  process.Subject(db.DbMessage),
  operating_contracts.CanaryAuthorizationV1,
  operating_contracts.AttentionQueueItem,
) {
  let base =
    "/tmp/aura-codex-monitor-authorized-"
    <> label
    <> "-"
    <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  simplifile.create_directory_all(base) |> should.be_ok
  let paths = xdg.resolve_with_home(base)
  let db_path = base <> "/aura.db"
  let assert Ok(db_subject) = db.start(db_path)
  let assert Ok(capability) =
    secret.prepare_monitor_capability_in(xdg.monitor_capabilities_dir(paths))
  let preparation = monitor_preparation_authorization()
  let authorization =
    operating_contracts.CanaryAuthorizationV1(
      ..monitor_authorization(capability.sha256),
      ends_at_ms:,
    )
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
    "monitor-prepare",
    authorization.authorized_by_ref,
  )
  |> should.be_ok
  connector_activation.enable_set(
    db_subject,
    authorization.authorization_id,
    "monitor-enable",
    authorization.authorized_by_ref,
    ["connector.enable"],
  )
  |> should.be_ok
  let #(_, domain_paths, _) = fixture_domain_only(base)
  let queued = enqueue_codex(db_subject, "event-authorized", time.now_ms())
  let assert Ok(conn) = sqlight.open(db_path)
  let assert Ok(_) =
    sqlight.query(
      "UPDATE attention_queue SET schema_version = 2, route_authorization_id = ?, route_activation_ids_json = ? WHERE queue_id = ?",
      on: conn,
      with: [
        sqlight.text(authorization.authorization_id),
        sqlight.text(
          "[\"activation:calendar-monitor\",\"activation:gmail-monitor\"]",
        ),
        sqlight.text(queued.queue_id),
      ],
      expecting: decode.success(Nil),
    )
  let _ = sqlight.close(conn)
  #(base, domain_paths, db_subject, authorization, queued)
}

fn fixture_domain_only(base: String) -> #(String, xdg.Paths, Nil) {
  let paths = xdg.resolve_with_home(base)
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
  #(base, paths, Nil)
}

fn monitor_preparation_authorization() -> operating_contracts.CanaryPreparationAuthorizationV1 {
  operating_contracts.CanaryPreparationAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:monitor-preparation",
    canary_id: "canary:monitor",
    oauth_client_ref: "oauth-client:monitor",
    oauth_client_hash: hash64("a"),
    connectors: [
      monitor_preparation_connector("calendar"),
      monitor_preparation_connector("gmail"),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: 9_999_999_999_999,
    authorized_by_ref: "operator:monitor",
  )
}

fn monitor_preparation_connector(
  id: String,
) -> operating_contracts.PreparationConnectorV1 {
  operating_contracts.PreparationConnectorV1(
    connector_id: id,
    configuration_ref: "configuration:" <> id <> "-monitor",
    oauth_scope: "https://www.googleapis.com/auth/" <> id <> ".readonly",
    identity_endpoint_id: id <> ".identity",
  )
}

fn monitor_authorization(
  capability_hash: String,
) -> operating_contracts.CanaryAuthorizationV1 {
  operating_contracts.CanaryAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:monitor",
    preparation_authorization_id: "authorization:monitor-preparation",
    canary_id: "canary:monitor",
    domain_id: "domain:sample",
    concern_id: "concern:domain:sample:review",
    policy_refs: ["policy:monitor"],
    connectors: [
      monitor_connector("calendar", "activation:calendar-monitor"),
      monitor_connector("gmail", "activation:gmail-monitor"),
    ],
    activation_grants: ["connector.disable", "connector.enable"],
    monitor_id: "monitor:authorized",
    monitor_capability_hash: capability_hash,
    monitor_runtime_ref: "codex:runtime:authorized",
    monitor_prompt_hash: hash64("b"),
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
    metric_ids: ["metric:monitor"],
    metric_review_owner_ref: "operator:monitor-metrics",
    authorized_by_ref: "operator:monitor",
    rollback_owner_ref: "operator:monitor-rollback",
  )
}

fn monitor_connector(
  id: String,
  activation_id: String,
) -> operating_contracts.AuthorizedConnectorV1 {
  operating_contracts.AuthorizedConnectorV1(
    connector_id: id,
    activation_id:,
    configuration_ref: "configuration:" <> id <> "-monitor",
    configuration_hash: hash64("c"),
    account_fingerprint: hash64("d"),
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

fn hash64(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}

pub fn claim_returns_compact_selected_context_and_one_lease_test() {
  let #(base, paths, db_subject) = fixture("claim-context")
  let queued = enqueue_codex(db_subject, "event-context", 100)

  let assert Ok(Some(envelope)) =
    codex_monitor.claim(paths, db_subject, claim_request(101))
  envelope.queue_id |> should.equal(queued.queue_id)
  envelope.monitor_id |> should.equal("monitor:test")
  envelope.action |> should.equal("surface_now")
  envelope.why_now |> should.equal(Some("The condition is active."))
  envelope.evidence_refs
  |> should.equal(["event-context", "evidence:event-context"])
  envelope.policy_refs |> should.equal(["policy:attention.md"])
  envelope.domain_context.domain_id |> should.equal("domain:sample")
  envelope.domain_context.purpose
  |> should.equal("Protect the selected operating context.")
  let assert Some(concern_context) = envelope.concern_context
  concern_context.concern_id
  |> should.equal("concern:domain:sample:review")
  concern_context.summary
  |> should.equal("Check the evidence before acting.")
  envelope.allowed_outcomes |> should.equal(["acknowledge", "defer"])
  envelope
  |> operating_contracts.encode_monitor_attention_envelope
  |> operating_contracts.decode_monitor_attention_envelope
  |> should.equal(Ok(envelope))
  codex_monitor.claim(paths, db_subject, claim_request(101))
  |> should.equal(Ok(None))
  db.list_attention_attempts(db_subject, queued.queue_id)
  |> should.be_ok
  |> list.map(fn(attempt) { attempt.phase })
  |> should.equal(["intent"])
  cleanup(base, db_subject)
}

pub fn claim_recovery_never_requeues_a_transferred_envelope_test() {
  let #(base, paths, db_subject) = fixture("claim-recovery")
  let queued = enqueue_codex(db_subject, "event-recovery", 100)
  let assert Ok(Some(_)) =
    codex_monitor.claim(
      paths,
      db_subject,
      operating_contracts.MonitorClaimRequest(..claim_request(101), lease_ms: 1),
    )
  process.sleep(5)

  codex_monitor.claim(paths, db_subject, claim_request(202))
  |> should.equal(Ok(None))
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("dead_letter")
  db.list_operational_audit(db_subject, "attention_queue", queued.queue_id)
  |> should.be_ok
  |> list.map(fn(record) { record.action })
  |> string.join(",")
  |> string.contains("attention.delivery_effect_unknown")
  |> should.be_true
  cleanup(base, db_subject)
}

pub fn caller_timestamp_cannot_recover_another_monitor_lease_test() {
  let #(base, paths, db_subject) = fixture("caller-time")
  let first = enqueue_codex(db_subject, "event-first-monitor", 100)
  let assert Ok(Some(_)) =
    codex_monitor.claim(paths, db_subject, claim_request(101))
  let second = enqueue_codex(db_subject, "event-second-monitor", 100)
  let request =
    operating_contracts.MonitorClaimRequest(
      ..claim_request(9_999_999_999_999),
      monitor_id: "monitor:second",
    )

  let assert Ok(Some(envelope)) =
    codex_monitor.claim(paths, db_subject, request)
  envelope.queue_id |> should.equal(second.queue_id)
  db.get_attention(db_subject, first.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("leased")
  cleanup(base, db_subject)
}

pub fn pre_transfer_expired_claim_is_recovered_before_monitor_claim_test() {
  let #(base, paths, db_subject) = fixture("pre-transfer-recovery")
  let queued = enqueue_codex(db_subject, "event-pre-transfer", 100)
  let assert Ok(Some(_)) =
    db.claim_attention(db_subject, "codex", "interrupted", 10, 101)

  let assert Ok(Some(envelope)) =
    codex_monitor.claim(paths, db_subject, claim_request(112))
  envelope.queue_id |> should.equal(queued.queue_id)
  db.list_attention_attempts(db_subject, queued.queue_id)
  |> should.be_ok
  |> list.map(fn(attempt) { attempt.phase })
  |> should.equal(["failed", "intent"])
  cleanup(base, db_subject)
}

pub fn acknowledged_outcome_is_idempotent_and_audited_test() {
  let #(base, paths, db_subject) = fixture("acknowledge")
  let queued = enqueue_codex(db_subject, "event-ack", 100)
  let assert Ok(Some(envelope)) =
    codex_monitor.claim(paths, db_subject, claim_request(101))
  let input =
    outcome(
      envelope,
      "outcome:ack",
      "acknowledge",
      ["attention.acknowledge"],
      None,
    )

  let first = codex_monitor.submit_outcome(db_subject, input) |> should.be_ok
  let second = codex_monitor.submit_outcome(db_subject, input) |> should.be_ok
  second |> should.equal(first)
  first.state |> should.equal("acknowledged")
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("acknowledged")
  db.list_operational_audit(db_subject, "attention_queue", queued.queue_id)
  |> should.be_ok
  |> list.map(fn(record) { record.action })
  |> should.equal([
    "attention.enqueued",
    "attention.claimed",
    "attention.delivery_intended",
    "attention.monitor_acknowledged",
  ])
  cleanup(base, db_subject)
}

pub fn changed_replay_wrong_monitor_and_missing_grant_are_rejected_test() {
  let #(base, paths, db_subject) = fixture("outcome-rejection")
  let queued = enqueue_codex(db_subject, "event-reject", 100)
  let assert Ok(Some(envelope)) =
    codex_monitor.claim(paths, db_subject, claim_request(101))
  let valid =
    outcome(
      envelope,
      "outcome:reject",
      "acknowledge",
      ["attention.acknowledge"],
      None,
    )

  codex_monitor.submit_outcome(
    db_subject,
    operating_contracts.MonitorOutcome(..valid, monitor_id: "monitor:wrong"),
  )
  |> should.be_error
  |> string.contains("lease_owner_mismatch")
  |> should.be_true
  codex_monitor.submit_outcome(
    db_subject,
    operating_contracts.MonitorOutcome(..valid, authority_grants: []),
  )
  |> should.be_error
  |> string.contains("authority_denied")
  |> should.be_true
  db.apply_monitor_outcome(
    db_subject,
    operating_contracts.MonitorOutcome(
      ..valid,
      codex_task_ref: Some("codex:task:assistant said hello"),
    ),
  )
  |> should.be_error
  |> string.contains("invalid_monitor_outcome")
  |> should.be_true
  codex_monitor.submit_outcome(db_subject, valid) |> should.be_ok
  codex_monitor.submit_outcome(
    db_subject,
    operating_contracts.MonitorOutcome(
      ..valid,
      codex_turn_ref: Some("codex:turn:changed"),
    ),
  )
  |> should.be_error
  |> string.contains("idempotency_conflict")
  |> should.be_true
  codex_monitor.submit_outcome(
    db_subject,
    operating_contracts.MonitorOutcome(..valid, outcome_id: "outcome:late"),
  )
  |> should.be_error
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("acknowledged")
  cleanup(base, db_subject)
}

pub fn defer_outcome_requires_future_time_and_specific_grant_test() {
  let #(base, paths, db_subject) = fixture("defer")
  let queued = enqueue_codex(db_subject, "event-defer", 100)
  let assert Ok(Some(envelope)) =
    codex_monitor.claim(paths, db_subject, claim_request(101))
  let invalid = outcome(envelope, "outcome:defer", "defer", [], Some(200))
  codex_monitor.submit_outcome(db_subject, invalid)
  |> should.be_error
  |> string.contains("authority_denied")
  |> should.be_true
  let valid =
    operating_contracts.MonitorOutcome(
      ..invalid,
      authority_grants: ["attention.defer"],
      defer_until: Some(invalid.occurred_at + 1000),
    )
  let receipt = codex_monitor.submit_outcome(db_subject, valid) |> should.be_ok
  receipt.state |> should.equal("deferred")
  let deferred = db.get_attention(db_subject, queued.queue_id) |> should.be_ok
  deferred.state |> should.equal("deferred")
  deferred.available_at |> should.equal(invalid.occurred_at + 1000)
  cleanup(base, db_subject)
}

pub fn outcome_after_lease_expiry_is_rejected_test() {
  let #(base, paths, db_subject) = fixture("expired-outcome")
  let queued = enqueue_codex(db_subject, "event-expired-outcome", 100)
  let assert Ok(Some(envelope)) =
    codex_monitor.claim(paths, db_subject, claim_request(101))
  let expired =
    operating_contracts.MonitorOutcome(
      ..outcome(
        envelope,
        "outcome:expired",
        "acknowledge",
        ["attention.acknowledge"],
        None,
      ),
      occurred_at: envelope.lease_expires_at + 1,
    )

  codex_monitor.submit_outcome(db_subject, expired) |> should.be_error
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("leased")
  cleanup(base, db_subject)
}

pub fn monitor_outcome_rolls_back_receipt_state_and_attempt_when_audit_fails_test() {
  let base = "/tmp/aura-codex-monitor-audit-rollback.db"
  let _ = simplifile.delete(base)
  let paths = xdg.resolve_with_home(base <> "-home")
  let assert Ok(db_subject) = db.start(base)
  let _ = fixture_context(paths)
  let queued = enqueue_codex(db_subject, "event-audit", 100)
  let assert Ok(Some(envelope)) =
    codex_monitor.claim(paths, db_subject, claim_request(101))
  let assert Ok(conn) = sqlight.open(base)
  let assert Ok(_) = sqlight.exec("DROP TABLE operational_audit", conn)

  codex_monitor.submit_outcome(
    db_subject,
    outcome(
      envelope,
      "outcome:audit",
      "acknowledge",
      ["attention.acknowledge"],
      None,
    ),
  )
  |> should.be_error
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("leased")
  db.list_attention_attempts(db_subject, queued.queue_id)
  |> should.be_ok
  |> list.map(fn(attempt) { attempt.phase })
  |> should.equal(["intent"])
  sqlight.query(
    "SELECT COUNT(*) FROM attention_monitor_outcomes",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> should.equal(Ok([0]))
  process.send(db_subject, db.Shutdown)
  let _ = sqlight.close(conn)
  let _ = simplifile.delete(base)
  let _ = simplifile.delete_all([base <> "-home"])
  Nil
}

fn fixture_context(paths: xdg.Paths) -> Result(Nil, String) {
  use _ <- result.try(domain_registry.write(
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
  ))
  use _ <- result.try(
    simplifile.create_directory_all(xdg.domain_concerns_dir(paths, "sample"))
    |> result.map_error(string.inspect),
  )
  simplifile.write(
    xdg.domain_concerns_dir(paths, "sample") <> "/review.md",
    "# Review readiness\n\nStatus: active\n\n## Summary\nCheck the evidence before acting.\n",
  )
  |> result.map_error(string.inspect)
}
