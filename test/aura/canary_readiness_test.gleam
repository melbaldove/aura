import aura/attention_queue
import aura/canary_readiness
import aura/codex_monitor
import aura/connector_adapter
import aura/connector_registry
import aura/db
import aura/domain_registry
import aura/event_ingest
import aura/operating_contracts
import aura/test_helpers
import aura/time
import aura/xdg
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import simplifile

pub fn personal_life_canary_is_local_and_disabled_test() {
  let fixture =
    canary_readiness.CanaryPlan(
      canary_id: "canary:personal-life:gmail-calendar",
      domain_id: "domain:personal-life",
      concern_id: "concern:domain:personal-life:weekly-awareness",
      connectors: [
        canary_readiness.ConnectorActivation("gmail", "disabled"),
        canary_readiness.ConnectorActivation("calendar", "disabled"),
      ],
      delivery_owner: "codex",
      delivery_target: "codex_monitor",
      allow_discord: False,
      trial_days: 7,
      read_only: True,
      live_authorized: False,
    )

  canary_readiness.verify(fixture)
  |> should.equal(Ok("ready_for_local_simulation"))
}

pub fn canary_rejects_enabled_or_extra_connectors_and_implicit_concern_test() {
  let base = plan()
  canary_readiness.verify(
    canary_readiness.CanaryPlan(..base, connectors: [
      canary_readiness.ConnectorActivation("gmail", "enabled"),
      canary_readiness.ConnectorActivation("calendar", "disabled"),
    ]),
  )
  |> should.be_error
  canary_readiness.verify(
    canary_readiness.CanaryPlan(..base, connectors: [
      canary_readiness.ConnectorActivation("gmail", "disabled"),
      canary_readiness.ConnectorActivation("calendar", "disabled"),
      canary_readiness.ConnectorActivation("other", "disabled"),
    ]),
  )
  |> should.be_error
  canary_readiness.verify(
    canary_readiness.CanaryPlan(
      ..base,
      concern_id: "concern:domain:other:implicit",
    ),
  )
  |> should.be_error
}

pub fn local_canary_uses_evidence_queue_and_codex_monitor_only_test() {
  let base = "/tmp/aura-personal-life-canary-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(base)
  let _ = simplifile.delete_all([base])
  write_personal_life_context(paths)
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(started) = event_ingest.start(db_subject)
  let ingest = started.data
  let gmail = read_result("test/fixtures/canary/personal-life-gmail.json")
  let calendar = read_result("test/fixtures/canary/personal-life-calendar.json")

  connector_adapter.normalize(disabled_registry(), gmail)
  |> should.equal(Error("connector_not_enabled:gmail"))
  connector_adapter.normalize(disabled_registry(), calendar)
  |> should.equal(Error("connector_not_enabled:calendar"))

  let simulation = simulation_registry()
  let gmail_insert =
    connector_adapter.submit(simulation, ingest, gmail) |> should.be_ok
  let gmail_duplicate =
    connector_adapter.submit(simulation, ingest, gmail) |> should.be_ok
  let calendar_insert =
    connector_adapter.submit(simulation, ingest, calendar) |> should.be_ok
  gmail_insert.inserted |> should.be_true
  gmail_duplicate.inserted |> should.be_false
  gmail_duplicate.event_id |> should.equal(gmail_insert.event_id)
  calendar_insert.inserted |> should.be_true
  db.list_evidence_concern_links(db_subject, gmail_insert.event_id)
  |> should.be_ok
  |> list.map(fn(link) { link.concern_id })
  |> should.equal(["concern:domain:personal-life:weekly-awareness"])

  let request =
    queue_request("primary", [gmail_insert.event_id, calendar_insert.event_id])
  let queued = db.enqueue_attention(db_subject, request) |> should.be_ok
  db.enqueue_attention(db_subject, request)
  |> should.equal(Ok(queued))
  db.list_attention(db_subject, "codex", "pending")
  |> should.be_ok
  |> list.length
  |> should.equal(1)
  db.list_attention(db_subject, "discord_compat", "pending")
  |> should.equal(Ok([]))
  queued.citations
  |> should.equal([
    "evidence:" <> gmail_insert.event_id,
    "evidence:" <> calendar_insert.event_id,
    "policy:canary:personal-life:v1",
  ])
  db.list_operational_audit(db_subject, "attention_queue", queued.queue_id)
  |> should.be_ok
  |> list.map(fn(record) { record.action })
  |> should.equal(["attention.enqueued"])

  codex_monitor.claim(
    paths,
    db_subject,
    operating_contracts.MonitorClaimRequest(
      schema_version: 1,
      monitor_id: "monitor:canary",
      authority_grants: ["attention.read"],
      lease_ms: 10_000,
      requested_at: 0,
    ),
  )
  |> should.be_error
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("pending")

  let assert Ok(Some(envelope)) =
    codex_monitor.claim(paths, db_subject, claim_request(10_000))
  envelope.domain_context.domain_id |> should.equal("domain:personal-life")
  let assert Some(concern) = envelope.concern_context
  concern.concern_id
  |> should.equal("concern:domain:personal-life:weekly-awareness")
  concern.summary |> should.equal("Review verified personal signals together.")
  let encoded = operating_contracts.encode_monitor_attention_envelope(envelope)
  string.contains(encoded, "transcript") |> should.be_false
  { string.length(encoded) < 16_000 } |> should.be_true
  codex_monitor.claim(paths, db_subject, claim_request(10_000))
  |> should.equal(Ok(None))

  let outcome =
    operating_contracts.MonitorOutcome(
      schema_version: 1,
      outcome_id: "outcome:canary-primary",
      queue_id: envelope.queue_id,
      lease_token: envelope.lease_token,
      monitor_id: "monitor:canary",
      disposition: "acknowledge",
      defer_until: None,
      codex_task_ref: Some("codex:task:canary-primary"),
      codex_conversation_ref: Some("codex:conversation:canary-primary"),
      codex_turn_ref: Some("codex:turn:canary-primary"),
      authority_grants: ["attention.acknowledge"],
      occurred_at: time.now_ms(),
    )
  codex_monitor.submit_outcome(
    db_subject,
    operating_contracts.MonitorOutcome(..outcome, authority_grants: []),
  )
  |> should.be_error
  codex_monitor.submit_outcome(
    db_subject,
    operating_contracts.MonitorOutcome(
      ..outcome,
      codex_task_ref: Some("codex:task:copied transcript words"),
    ),
  )
  |> should.be_error
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("leased")
  let first = codex_monitor.submit_outcome(db_subject, outcome) |> should.be_ok
  codex_monitor.submit_outcome(db_subject, outcome)
  |> should.equal(Ok(first))
  db.list_operational_audit(db_subject, "attention_queue", queued.queue_id)
  |> should.be_ok
  |> list.map(fn(record) { record.action })
  |> should.equal([
    "attention.enqueued",
    "attention.claimed",
    "attention.delivery_intended",
    "attention.monitor_acknowledged",
  ])
  db.load_messages(db_subject, "canary-codex-monitor", 100)
  |> should.equal(Ok([]))

  let recovering =
    db.enqueue_attention(
      db_subject,
      queue_request("recovery", [calendar_insert.event_id]),
    )
    |> should.be_ok
  let assert Ok(Some(_)) =
    codex_monitor.claim(paths, db_subject, claim_request(1))
  process.sleep(5)
  codex_monitor.claim(paths, db_subject, claim_request(10_000))
  |> should.equal(Ok(None))
  db.get_attention(db_subject, recovering.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("dead_letter")
  db.list_operational_audit(db_subject, "attention_queue", recovering.queue_id)
  |> should.be_ok
  |> list.map(fn(record) { record.action })
  |> should.equal([
    "attention.enqueued",
    "attention.claimed",
    "attention.delivery_intended",
    "attention.delivery_effect_unknown",
  ])
  db.list_attention(db_subject, "discord_compat", "pending")
  |> should.equal(Ok([]))

  let assert Ok(pid) = process.subject_owner(ingest)
  process.unlink(pid)
  process.kill(pid)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
}

fn plan() -> canary_readiness.CanaryPlan {
  canary_readiness.CanaryPlan(
    canary_id: "canary:personal-life:gmail-calendar",
    domain_id: "domain:personal-life",
    concern_id: "concern:domain:personal-life:weekly-awareness",
    connectors: [
      canary_readiness.ConnectorActivation("gmail", "disabled"),
      canary_readiness.ConnectorActivation("calendar", "disabled"),
    ],
    delivery_owner: "codex",
    delivery_target: "codex_monitor",
    allow_discord: False,
    trial_days: 7,
    read_only: True,
    live_authorized: False,
  )
}

fn descriptor(connector_id: String) -> connector_registry.ConnectorDescriptor {
  connector_registry.ConnectorDescriptor(
    schema_version: 1,
    connector_id:,
    display_name: connector_id,
    source_kind: "connector",
    capabilities: ["resource.read"],
    scopes: ["personal-life.readonly"],
    descriptor_provenance_ref: "descriptor://canary/" <> connector_id,
    summary_limit: 300,
    value_limit: 1000,
    read_authority_ref: None,
    write_authority_ref: None,
    policy_boundary_ref: "policy://canary/personal-life/v1",
  )
}

fn registry(state: String) -> connector_registry.Registry {
  connector_registry.build([descriptor("gmail"), descriptor("calendar")], [
    connector_registry.ConnectorActivation(
      1,
      "gmail",
      state,
      "fixture://canary/personal-life/gmail",
    ),
    connector_registry.ConnectorActivation(
      1,
      "calendar",
      state,
      "fixture://canary/personal-life/calendar",
    ),
  ])
  |> should.be_ok
}

fn disabled_registry() -> connector_registry.Registry {
  registry("disabled")
}

fn simulation_registry() -> connector_registry.Registry {
  registry("enabled")
}

fn read_result(path: String) -> operating_contracts.ConnectorResult {
  let decoded =
    simplifile.read(path)
    |> should.be_ok
    |> operating_contracts.decode_connector_result
    |> should.be_ok
  operating_contracts.ConnectorResult(
    ..decoded,
    content_hash: connector_adapter.content_hash(decoded),
  )
}

fn write_personal_life_context(paths: xdg.Paths) -> Nil {
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

fn queue_request(
  suffix: String,
  event_refs: List(String),
) -> attention_queue.EnqueueRequest {
  attention_queue.EnqueueRequest(
    queue_id: "attention:canary:" <> suffix,
    decision_id: "decision:canary:" <> suffix,
    domain_id: "personal-life",
    concern_id: Some("concern:domain:personal-life:weekly-awareness"),
    event_refs:,
    action: "surface_now",
    summary: "A verified personal signal is ready for review.",
    rationale: "The local canary policy selected this evidence.",
    why_now: Some("The evidence is current."),
    deferral_cost: Some("A delayed review can miss a useful window."),
    why_not_digest: Some("The canary fixture marks this item as eligible now."),
    authority_request: Some("human_judgment"),
    citations: list.append(
      list.map(event_refs, fn(ref) { "evidence:" <> ref }),
      ["policy:canary:personal-life:v1"],
    ),
    delivery_owner: "codex",
    delivery_target: "codex_monitor",
    delivery_key: "codex:canary:" <> suffix,
    available_at: 0,
    expires_at: None,
  )
}

fn claim_request(lease_ms: Int) -> operating_contracts.MonitorClaimRequest {
  operating_contracts.MonitorClaimRequest(
    schema_version: 1,
    monitor_id: "monitor:canary",
    authority_grants: ["attention.read", "attention.claim"],
    lease_ms:,
    requested_at: 0,
  )
}
