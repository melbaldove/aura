import aura/canary_metrics
import aura/codex_monitor_runtime
import aura/cognitive_context
import aura/cognitive_decision
import aura/cognitive_delivery
import aura/cognitive_event
import aura/config
import aura/connector_activation
import aura/connector_registry
import aura/connector_runtime
import aura/ctl
import aura/db
import aura/domain_registry
import aura/event_ingest
import aura/evidence
import aura/google_execution_fixture
import aura/integrations/calendar_api
import aura/integrations/gmail_api
import aura/operating_contracts
import aura/secret
import aura/test_helpers
import aura/time
import aura/xdg
import fakes/fake_discord
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import gleeunit/should
import simplifile

pub fn synthetic_personal_life_canary_uses_production_boundaries_test() {
  let root =
    "/tmp/aura-personal-life-live-proof-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([root])
  let paths = xdg.resolve_with_home(root)
  write_context(paths)
  let assert Ok(db_subject) = db.start(root <> "/aura.db")

  let disabled =
    connector_runtime.load(db_subject, configurations()) |> should.be_ok
  connector_runtime.activation_ids(disabled) |> should.equal([])

  let assert Ok(capability) =
    secret.prepare_monitor_capability_in(xdg.monitor_capabilities_dir(paths))
  let now = time.now_ms()
  let preparation = preparation(now)
  let authorization = authorization(now, capability.sha256)
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
    "canary:prepare",
    authorization.authorized_by_ref,
  )
  |> should.be_ok
  let enabled =
    connector_activation.enable_set(
      db_subject,
      authorization.authorization_id,
      "canary:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
    |> should.be_ok
  let runtime =
    connector_runtime.load(db_subject, configurations()) |> should.be_ok
  connector_runtime.activation_ids(runtime)
  |> list.sort(string.compare)
  |> should.equal([
    "activation:calendar-personal-life",
    "activation:gmail-personal-life",
  ])

  let assert Ok(ingest_started) = event_ingest.start(db_subject)
  let registry = registry()
  let gmail_activation = find_activation(enabled, "gmail")
  let gmail_context =
    begin_read(
      db_subject,
      authorization,
      gmail_activation,
      "attempt:gmail-local-proof",
      "worker:gmail-local-proof",
    )
  let gmail_insert =
    gmail_api.execute_metadata(
      registry,
      ingest_started.data,
      gmail_context,
      gmail_url(),
      fn(_) { Ok(gmail_message()) },
    )
    |> should.be_ok
  let assert Some(gmail_insert) = gmail_insert
  let gmail_replay_context =
    begin_read(
      db_subject,
      authorization,
      gmail_activation,
      "attempt:gmail-local-replay",
      "worker:gmail-local-replay",
    )
  let assert Some(gmail_replay) =
    gmail_api.execute_metadata(
      registry,
      ingest_started.data,
      gmail_replay_context,
      gmail_url(),
      fn(_) { Ok(gmail_message()) },
    )
    |> should.be_ok
  gmail_replay.inserted |> should.be_false
  let gmail_conflict_context =
    begin_read(
      db_subject,
      authorization,
      gmail_activation,
      "attempt:gmail-local-conflict",
      "worker:gmail-local-conflict",
    )
  gmail_api.execute_metadata(
    registry,
    ingest_started.data,
    gmail_conflict_context,
    gmail_url(),
    fn(_) {
      Ok(
        gmail_api.MetadataMessage(
          ..gmail_message(),
          subject: "Changed synthetic signal",
        ),
      )
    },
  )
  |> should.equal(Error("idempotency_conflict"))

  let calendar_activation = find_activation(enabled, "calendar")
  let calendar_context =
    begin_read(
      db_subject,
      authorization,
      calendar_activation,
      "attempt:calendar-local-proof",
      "worker:calendar-local-proof",
    )
  let calendar_insert =
    calendar_api.execute_pages(
      registry,
      db_subject,
      ingest_started.data,
      authorization,
      calendar_context,
      calendar_url(authorization),
      fn(_) {
        Ok(calendar_api.EventsPage(
          [
            calendar_event("calendar-event-1", "Synthetic appointment"),
            calendar_event("calendar-event-2", "Synthetic reminder"),
          ],
          "",
          512,
        ))
      },
    )
    |> should.be_ok
  let assert Some([calendar_insert, recovery_insert]) = calendar_insert
  db.list_evidence_concern_links(db_subject, gmail_insert.event_id)
  |> should.equal(Ok([explicit_concern_link(authorization)]))
  db.list_evidence_concern_links(db_subject, calendar_insert.event_id)
  |> should.equal(Ok([explicit_concern_link(authorization)]))
  db.list_evidence_concern_links(db_subject, recovery_insert.event_id)
  |> should.equal(Ok([explicit_concern_link(authorization)]))

  let packet = decision_context(gmail_insert.event_id)
  let decision = surface_decision(gmail_insert.event_id, authorization)
  cognitive_decision.validate(decision, packet) |> should.be_ok

  let #(discord, discord_transport) = fake_discord.new()
  let reports = process.new_subject()
  let assert Ok(delivery_started) =
    cognitive_delivery.start_with_history(
      paths,
      discord_transport,
      [cognitive_delivery.domain_target("personal-life", "must-not-send")],
      [],
      db_subject,
      Some(reports),
    )
  cognitive_delivery.deliver_authorized(
    delivery_started.data,
    decision,
    authorization,
  )
  let report = process.receive(reports, 1000) |> should.be_ok
  report.status |> should.equal(cognitive_delivery.Queued)
  fake_discord.all_events(discord) |> should.equal([])
  db.list_attention(db_subject, "discord_compat", "pending")
  |> should.equal(Ok([]))
  let assert [queued] =
    db.list_attention(db_subject, "codex", "pending") |> should.be_ok
  queued.event_refs |> should.equal([gmail_insert.event_id])
  queued.citations
  |> should.equal([
    "evidence:" <> gmail_insert.event_id,
    "policy:personal-life-canary:v1",
  ])
  cognitive_delivery.deliver_authorized(
    delivery_started.data,
    decision,
    authorization,
  )
  process.receive(reports, 1000)
  |> should.be_ok
  |> fn(report) { report.status }
  |> should.equal(cognitive_delivery.Queued)
  db.list_attention(db_subject, "codex", "pending")
  |> should.be_ok
  |> list.length
  |> should.equal(1)
  let forged_event_id = "event:forged-personal-life-evidence"
  cognitive_delivery.deliver_authorized(
    delivery_started.data,
    surface_decision(forged_event_id, authorization),
    authorization,
  )
  let forged_report = process.receive(reports, 1000) |> should.be_ok
  forged_report.status |> should.equal(cognitive_delivery.Failed)
  forged_report.error
  |> should.equal("authorized_attention_evidence_mismatch")
  cognitive_delivery.deliver_authorized(
    delivery_started.data,
    cognitive_decision.DecisionEnvelope(
      ..decision,
      summary: "Changed payload under the same decision identity.",
    ),
    authorization,
  )
  let conflict_report = process.receive(reports, 1000) |> should.be_ok
  conflict_report.status |> should.equal(cognitive_delivery.Failed)
  string.contains(conflict_report.error, "idempotency_conflict")
  |> should.be_true

  let raw_config = runtime_config(authorization, capability.sha256, 60_000)
  let envelope =
    codex_monitor_runtime.run_once_with(
      paths,
      raw_config,
      ctl_sender(paths, db_subject),
    )
    |> should.be_ok
    |> operating_contracts.decode_monitor_attention_envelope
    |> should.be_ok
  envelope.queue_id |> should.equal(queued.queue_id)
  envelope.domain_context.domain_id |> should.equal("domain:personal-life")
  let assert Some(concern) = envelope.concern_context
  concern.concern_id |> should.equal(authorization.concern_id)
  codex_monitor_runtime.run_once_with(
    paths,
    raw_config,
    ctl_sender(paths, db_subject),
  )
  |> should.equal(Ok(""))

  let receipt =
    codex_monitor_runtime.acknowledge_with(
      paths,
      raw_config,
      "codex:outcome:personal-life-proof",
      envelope.queue_id,
      envelope.lease_token,
      Some("codex:task:personal-life-proof"),
      ctl_sender(paths, db_subject),
    )
    |> should.be_ok
  codex_monitor_runtime.acknowledge_with(
    paths,
    raw_config,
    "codex:outcome:personal-life-proof",
    envelope.queue_id,
    envelope.lease_token,
    Some("codex:task:personal-life-proof"),
    ctl_sender(paths, db_subject),
  )
  |> should.equal(Ok(receipt))

  let deferred_decision = ask_decision(calendar_insert.event_id, authorization)
  cognitive_delivery.deliver_authorized(
    delivery_started.data,
    deferred_decision,
    authorization,
  )
  process.receive(reports, 1000) |> should.be_ok
  let deferred_envelope =
    codex_monitor_runtime.run_once_with(
      paths,
      raw_config,
      ctl_sender(paths, db_subject),
    )
    |> should.be_ok
    |> operating_contracts.decode_monitor_attention_envelope
    |> should.be_ok
  let defer_until = time.now_ms() + 120_000
  let defer_receipt =
    codex_monitor_runtime.defer_with(
      paths,
      raw_config,
      "codex:outcome:personal-life-defer",
      deferred_envelope.queue_id,
      deferred_envelope.lease_token,
      defer_until,
      Some("codex:task:personal-life-defer"),
      ctl_sender(paths, db_subject),
    )
    |> should.be_ok
  codex_monitor_runtime.defer_with(
    paths,
    raw_config,
    "codex:outcome:personal-life-defer",
    deferred_envelope.queue_id,
    deferred_envelope.lease_token,
    defer_until,
    Some("codex:task:personal-life-defer"),
    ctl_sender(paths, db_subject),
  )
  |> should.equal(Ok(defer_receipt))
  let recovery_decision =
    cognitive_decision.DecisionEnvelope(
      ..surface_decision(recovery_insert.event_id, authorization),
      summary: "A synthetic calendar change needs review.",
    )
  cognitive_delivery.deliver_authorized(
    delivery_started.data,
    recovery_decision,
    authorization,
  )
  process.receive(reports, 1000) |> should.be_ok
  let short_config = runtime_config(authorization, capability.sha256, 1)
  let interrupted =
    codex_monitor_runtime.run_once_with(
      paths,
      short_config,
      ctl_sender(paths, db_subject),
    )
    |> should.be_ok
    |> operating_contracts.decode_monitor_attention_envelope
    |> should.be_ok
  process.sleep(5)
  codex_monitor_runtime.run_once_with(
    paths,
    raw_config,
    ctl_sender(paths, db_subject),
  )
  |> should.equal(Ok(""))
  db.get_attention(db_subject, interrupted.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("dead_letter")

  connector_activation.begin_disable_set(
    db_subject,
    authorization.authorization_id,
    "canary:disable",
    authorization.rollback_owner_ref,
    ["connector.disable"],
  )
  |> should.be_ok
  connector_activation.finalize_disable_set(
    db_subject,
    authorization.authorization_id,
    "canary:disable-finalize",
    authorization.rollback_owner_ref,
  )
  |> should.be_ok
  db.reserve_connector_read(
    db_subject,
    "attempt:after-disable",
    gmail_activation.activation_id,
    authorization.authorization_id,
    "worker:after-disable",
    1000,
  )
  |> should.equal(Error("connector_activation_not_effective"))

  let metrics =
    canary_metrics.collect(db_subject, authorization) |> should.be_ok
  db.collect_canary_metrics(db_subject, authorization.authorization_id, [
    "metric:evidence.accepted",
  ])
  |> should.equal(Error("unauthorized_canary_metric_set"))
  dict.get(metrics.counts, "metric:evidence.accepted")
  |> should.equal(Ok(3))
  dict.get(metrics.counts, "metric:attention.queued")
  |> should.equal(Ok(3))
  dict.get(metrics.counts, "metric:discord.deliveries")
  |> should.equal(Ok(0))
  dict.get(metrics.counts, "metric:evidence.replays")
  |> should.equal(Ok(1))
  dict.get(metrics.counts, "metric:evidence.conflicts")
  |> should.equal(Ok(1))
  dict.get(metrics.counts, "metric:attention.duplicates")
  |> should.equal(Ok(1))
  dict.get(metrics.counts, "metric:transcript.violations")
  |> should.equal(Ok(0))
  let encoded =
    operating_contracts.encode_monitor_attention_envelope(envelope)
    <> canary_metrics.encode(metrics)
  forbidden_values()
  |> list.each(fn(value) {
    string.contains(string.lowercase(encoded), value) |> should.be_false
  })
  db.load_messages(db_subject, "personal-life-canary", 100)
  |> should.equal(Ok([]))
  fake_discord.all_events(discord) |> should.equal([])

  let assert Ok(pid) = process.subject_owner(ingest_started.data)
  process.unlink(pid)
  process.kill(pid)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([root])
}

fn configurations() -> List(config.ConnectorConfiguration) {
  [configuration("gmail"), configuration("calendar")]
}

fn configuration(connector_id: String) -> config.ConnectorConfiguration {
  let scope = "https://www.googleapis.com/auth/" <> connector_id <> ".readonly"
  let configuration_ref = "configuration:" <> connector_id <> "-personal-life"
  config.ConnectorConfiguration(
    configuration_ref:,
    connector_id:,
    oauth_client_ref: "oauth-client:personal-life",
    credential_ref: "credential:" <> connector_id <> "-personal-life",
    resource_ref: "resource:" <> connector_id <> "-primary",
    oauth_scope: scope,
    configuration_hash: config.connector_configuration_hash(
      configuration_ref,
      connector_id,
      "oauth-client:personal-life",
      "credential:" <> connector_id <> "-personal-life",
      "resource:" <> connector_id <> "-primary",
      scope,
    )
      |> string.lowercase,
  )
}

fn preparation(now: Int) -> operating_contracts.CanaryPreparationAuthorizationV1 {
  operating_contracts.CanaryPreparationAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:personal-life-preparation",
    canary_id: "canary:personal-life:gmail-calendar",
    oauth_client_ref: "oauth-client:personal-life",
    oauth_client_hash: hash("oauth-client"),
    connectors: [
      preparation_connector("calendar"),
      preparation_connector("gmail"),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: now + 900_000,
    authorized_by_ref: "operator:local-proof",
  )
}

fn preparation_connector(
  id: String,
) -> operating_contracts.PreparationConnectorV1 {
  operating_contracts.PreparationConnectorV1(
    connector_id: id,
    configuration_ref: "configuration:" <> id <> "-personal-life",
    oauth_scope: "https://www.googleapis.com/auth/" <> id <> ".readonly",
    identity_endpoint_id: id <> ".readonly.identity",
  )
}

fn authorization(
  now: Int,
  capability_hash: String,
) -> operating_contracts.CanaryAuthorizationV1 {
  operating_contracts.CanaryAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:personal-life-local-proof",
    preparation_authorization_id: "authorization:personal-life-preparation",
    canary_id: "canary:personal-life:gmail-calendar",
    domain_id: "domain:personal-life",
    concern_id: "concern:domain:personal-life:weekly-awareness",
    policy_refs: ["policy:personal-life-canary:v1"],
    connectors: [
      authorized_connector("calendar"),
      authorized_connector("gmail"),
    ],
    activation_grants: ["connector.disable", "connector.enable"],
    monitor_id: "monitor:personal-life-canary",
    monitor_capability_hash: capability_hash,
    monitor_runtime_ref: "codex:runtime:personal-life-canary",
    monitor_prompt_hash: hash("monitor-prompt"),
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
    starts_at_ms: now - 1000,
    ends_at_ms: now + 600_000,
    metric_ids: [
      "metric:gmail.read_attempts",
      "metric:calendar.read_attempts",
      "metric:evidence.accepted",
      "metric:evidence.gaps",
      "metric:evidence.unknown_reads",
      "metric:evidence.replays",
      "metric:evidence.conflicts",
      "metric:policy.surface_now",
      "metric:policy.ask_now",
      "metric:attention.queued",
      "metric:attention.duplicates",
      "metric:discord.deliveries",
      "metric:monitor.claims",
      "metric:monitor.outcomes",
      "metric:recovery.effect_unknown",
      "metric:actions.unapproved",
      "metric:transcript.violations",
    ],
    metric_review_owner_ref: "operator:local-metrics",
    authorized_by_ref: "operator:local-proof",
    rollback_owner_ref: "operator:local-rollback",
  )
}

fn authorized_connector(id: String) -> operating_contracts.AuthorizedConnectorV1 {
  let configuration = configuration(id)
  operating_contracts.AuthorizedConnectorV1(
    connector_id: id,
    activation_id: "activation:" <> id <> "-personal-life",
    configuration_ref: configuration.configuration_ref,
    configuration_hash: configuration.configuration_hash,
    account_fingerprint: hash(id <> "-account"),
    oauth_proof_ref: "proof:" <> id <> "-oauth",
    identity_proof_ref: "proof:" <> id <> "-identity",
    oauth_scope: configuration.oauth_scope,
    capability: case id {
      "gmail" -> "mail.read"
      _ -> "calendar.read"
    },
    retention_policy_ref: "retention:" <> id <> "-compact",
    poll_interval_ms: 60_000,
    max_pages_per_poll: 2,
    max_items_per_poll: 10,
    max_response_bytes: 4096,
  )
}

fn registry() -> connector_registry.Registry {
  connector_registry.build(
    [descriptor("gmail", "mail.read"), descriptor("calendar", "calendar.read")],
    [registry_activation("gmail"), registry_activation("calendar")],
  )
  |> should.be_ok
}

fn descriptor(
  id: String,
  capability: String,
) -> connector_registry.ConnectorDescriptor {
  connector_registry.ConnectorDescriptor(
    schema_version: 1,
    connector_id: id,
    display_name: id,
    source_kind: "connector",
    capabilities: [capability],
    scopes: ["https://www.googleapis.com/auth/" <> id <> ".readonly"],
    descriptor_provenance_ref: "descriptor://" <> id <> "/readonly/v1",
    summary_limit: 512,
    value_limit: 1024,
    read_authority_ref: None,
    write_authority_ref: None,
    policy_boundary_ref: "policy://personal-life-canary/v1",
  )
}

fn registry_activation(id: String) -> connector_registry.ConnectorActivation {
  connector_registry.ConnectorActivation(
    schema_version: 1,
    connector_id: id,
    state: "enabled",
    configuration_ref: "config://personal-life/" <> id,
  )
}

fn find_activation(
  values: List(operating_contracts.ConnectorActivationV1),
  id: String,
) -> operating_contracts.ConnectorActivationV1 {
  list.find(values, fn(value) { value.connector_id == id }) |> should.be_ok
}

fn explicit_concern_link(
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> evidence.ConcernLink {
  evidence.ConcernLink(
    concern_id: authorization.concern_id,
    confidence: 1.0,
    provenance: "authorization:" <> authorization.authorization_id,
    confirmed: True,
  )
}

fn begin_read(
  db_subject: process.Subject(db.DbMessage),
  authorization: operating_contracts.CanaryAuthorizationV1,
  activation: operating_contracts.ConnectorActivationV1,
  attempt_id: String,
  worker_id: String,
) -> operating_contracts.ConnectorSubmissionContext {
  let attempt =
    db.reserve_connector_read(
      db_subject,
      attempt_id,
      activation.activation_id,
      authorization.authorization_id,
      worker_id,
      10_000,
    )
    |> should.be_ok
  db.begin_connector_read(db_subject, attempt_id, worker_id) |> should.be_ok
  let connector =
    list.find(authorization.connectors, fn(value) {
      value.activation_id == activation.activation_id
    })
    |> should.be_ok
  operating_contracts.ConnectorSubmissionContext(
    activation_id: activation.activation_id,
    activation_version: attempt.activation_version,
    authorization_id: authorization.authorization_id,
    attempt_id:,
    worker_id:,
    connector_id: connector.connector_id,
    capability: connector.capability,
    oauth_scope: connector.oauth_scope,
    configuration_hash: connector.configuration_hash,
    account_fingerprint: connector.account_fingerprint,
    domain_id: authorization.domain_id,
    concern_id: authorization.concern_id,
  )
}

fn gmail_url() -> String {
  "https://gmail.googleapis.com/gmail/v1/users/me/messages/message-1?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date&fields=id%2CthreadId%2ClabelIds%2ChistoryId%2CinternalDate%2CsizeEstimate%2Cpayload%28headers%29"
}

fn gmail_message() -> gmail_api.MetadataMessage {
  gmail_api.MetadataMessage(
    message_id: "message-1",
    thread_id: "thread-1",
    history_id: "42",
    internal_date_ms: 1_786_204_800_000,
    label_ids: ["INBOX"],
    size_estimate: 128,
    subject: "Synthetic personal signal",
    from: "Synthetic Person <person@example.test>",
  )
}

fn calendar_url(
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> String {
  "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&showDeleted=true&timeMin="
  <> uri.percent_encode(time.format_ms_rfc3339_utc(authorization.starts_at_ms))
  <> "&timeMax="
  <> uri.percent_encode(time.format_ms_rfc3339_utc(authorization.ends_at_ms))
  <> "&maxResults=10&fields=nextPageToken%2Citems%28id%2Cetag%2Cstatus%2Csummary%2Cstart%28date%2CdateTime%29%2Cend%28date%2CdateTime%29%2Cupdated%2CrecurringEventId%2CeventType%2Ctransparency%2Cvisibility%29"
}

fn calendar_event(
  event_id: String,
  summary: String,
) -> calendar_api.CalendarEvent {
  calendar_api.CalendarEvent(
    event_id:,
    etag: "etag-" <> event_id,
    status: "confirmed",
    summary:,
    start: "2026-08-10T09:00:00Z",
    end: "2026-08-10T09:30:00Z",
    updated: "2026-08-09T08:00:00Z",
    recurring_event_id: None,
    event_type: "default",
    transparency: "opaque",
    visibility: "default",
    updated_at_ms: 1_786_204_800_000,
    observed_at_ms: 1_786_204_800_000,
  )
}

fn decision_context(event_id: String) -> cognitive_context.ContextPacket {
  let observation =
    cognitive_event.Observation(
      id: event_id,
      source: "connector:gmail",
      resource_id: "message:message-1",
      resource_type: "gmail_message",
      event_type: "gmail.message.metadata_observed",
      event_time_ms: 1_786_204_800_000,
      actors: [],
      tags: dict.new(),
      text: "Synthetic personal signal",
      state_before: "",
      state_after: "",
      raw_ref: "gmail://message/message-1",
      raw_data: "{}",
    )
  cognitive_context.ContextPacket(
    observation:,
    evidence: cognitive_event.EvidenceBundle(
      observation_id: event_id,
      atoms: [
        cognitive_event.EvidenceAtom(
          id: event_id,
          kind: "metadata_summary",
          value: "Synthetic personal signal",
          source_path: "summary",
          text_span: "",
          confidence: 1.0,
          provenance: "connector:gmail",
        ),
      ],
      resource_refs: [],
      raw_refs: [],
    ),
    policies: [
      cognitive_context.PolicyFile(
        name: "Personal Life canary",
        path: "policies/personal-life-canary.md",
        source_ref: "policy:personal-life-canary:v1",
        content: "Surface a current synthetic signal for the local proof.",
      ),
    ],
    context_files: [],
    concerns: [
      cognitive_context.ConcernFile(
        name: "Weekly awareness",
        path: "concerns/weekly-awareness.md",
        source_ref: "concern:domain:personal-life:weekly-awareness",
        content: "Review verified personal signals together.",
      ),
    ],
    delivery_targets: ["none", "domain:personal-life"],
    digest_windows: [],
    current_local_time: "2026-08-09T09:00:00+08:00",
    recent_decisions: "",
  )
}

fn surface_decision(
  event_id: String,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> cognitive_decision.DecisionEnvelope {
  cognitive_decision.DecisionEnvelope(
    event_id:,
    concern_refs: [authorization.concern_id],
    summary: "A synthetic personal signal needs review.",
    citations: ["evidence:" <> event_id, "policy:personal-life-canary:v1"],
    attention: cognitive_decision.AttentionDecision(
      action: "surface_now",
      rationale: "The synthetic policy threshold is met.",
      why_now: "The synthetic signal is current.",
      deferral_cost: "A later review can miss the synthetic window.",
      why_not_digest: "The synthetic window closes before the next digest.",
    ),
    work: cognitive_decision.WorkDecision(
      action: "prepare",
      target: "personal review context",
      proof_required: "stored evidence is cited",
    ),
    authority: cognitive_decision.AuthorityDecision(
      required: "human_judgment",
      reason: "The user owns the decision.",
    ),
    delivery: cognitive_decision.DeliveryDecision(
      target: "domain:personal-life",
      rationale: "Use the selected domain context.",
    ),
    gaps: [],
    proposed_patches: [],
  )
}

fn ask_decision(
  event_id: String,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> cognitive_decision.DecisionEnvelope {
  let base = surface_decision(event_id, authorization)
  cognitive_decision.DecisionEnvelope(
    ..base,
    summary: "A synthetic calendar choice needs confirmation.",
    attention: cognitive_decision.AttentionDecision(
      ..base.attention,
      action: "ask_now",
    ),
  )
}

fn runtime_config(
  authorization: operating_contracts.CanaryAuthorizationV1,
  capability_hash: String,
  lease_ms: Int,
) -> String {
  "{\"schema_version\":1,\"authorization_id\":\""
  <> authorization.authorization_id
  <> "\",\"monitor_id\":\""
  <> authorization.monitor_id
  <> "\",\"monitor_runtime_ref\":\""
  <> authorization.monitor_runtime_ref
  <> "\",\"capability_sha256\":\""
  <> capability_hash
  <> "\",\"lease_ms\":"
  <> int.to_string(lease_ms)
  <> "}"
}

fn ctl_sender(paths, db_subject) {
  fn(command) {
    case string.starts_with(command, "monitor claim ") {
      True ->
        Ok(ctl.process_monitor_claim(
          paths,
          db_subject,
          string.drop_start(command, string.length("monitor claim ")),
        ))
      False ->
        Ok(ctl.process_monitor_outcome(
          paths,
          db_subject,
          string.drop_start(command, string.length("monitor outcome ")),
        ))
    }
  }
}

fn write_context(paths: xdg.Paths) -> Nil {
  domain_registry.write(
    paths,
    domain_registry.Record(
      domain_id: "domain:personal-life",
      slug: "personal-life",
      display_name: "Personal Life",
      aliases: [],
      purpose: "Protect personal commitments without creating noise.",
      status: "active",
      cwd: None,
      discord_channel: None,
      version: 1,
      created_at: 100,
      updated_at: 100,
    ),
  )
  |> should.be_ok
  simplifile.create_directory_all(xdg.domain_concerns_dir(
    paths,
    "personal-life",
  ))
  |> should.be_ok
  simplifile.write(
    xdg.domain_concerns_dir(paths, "personal-life") <> "/weekly-awareness.md",
    "# Weekly awareness\n\nStatus: active\nDomain-ID: domain:personal-life\nConcern-ID: concern:domain:personal-life:weekly-awareness\nSlug: weekly-awareness\nUpdated: 100\n\n## Summary\nReview verified personal signals together.\n",
  )
  |> should.be_ok
  Nil
}

fn forbidden_values() -> List(String) {
  [
    "transcript_text",
    "copied transcript",
    "capability_proof",
    "access_token",
    "refresh_token",
    "message_body",
    "attachment",
    "attendees",
    "conference",
  ]
}

fn hash(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}
