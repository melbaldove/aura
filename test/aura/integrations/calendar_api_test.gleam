import aura/connector_activation
import aura/connector_adapter
import aura/connector_registry
import aura/db
import aura/event_ingest
import aura/google_execution_fixture
import aura/integrations/calendar_api
import aura/operating_contracts
import aura/time
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn calendar_event_becomes_compact_versioned_evidence_test() {
  let result =
    calendar_api.event_to_result(fixture_event("etag-1")) |> should.be_ok
  result.connector_id |> should.equal("calendar")
  result.capability |> should.equal("calendar.read")
  result.scope
  |> should.equal("https://www.googleapis.com/auth/calendar.readonly")
  string.starts_with(result.raw_ref, "calendar://event/") |> should.be_true
  result.candidate_domain_refs |> should.equal([])
  result.candidate_concern_refs |> should.equal([])
  dict.get(result.normalized_data, "description") |> should.equal(Error(Nil))
  dict.get(result.normalized_data, "location") |> should.equal(Error(Nil))
  dict.get(result.normalized_data, "attendees") |> should.equal(Error(Nil))
  dict.get(result.normalized_data, "attachments") |> should.equal(Error(Nil))
  dict.get(result.normalized_data, "conference_data")
  |> should.equal(Error(Nil))
  dict.get(result.normalized_data, "recurring_event_ref")
  |> should.be_ok

  let changed =
    calendar_api.event_to_result(fixture_event("etag-2")) |> should.be_ok
  changed.source_event_id |> should.not_equal(result.source_event_id)
  changed.raw_ref |> should.not_equal(result.raw_ref)
}

pub fn calendar_identity_creates_only_opaque_proof_test() {
  let seed =
    calendar_api.identity_seed(
      calendar_api.CalendarIdentity("primary-account@example.test"),
      string.repeat("k", 32),
    )
    |> should.be_ok
  string.length(seed.account_fingerprint) |> should.equal(64)
  string.contains(seed.account_fingerprint, "primary-account")
  |> should.be_false
  string.contains(seed.proof_hash, "example.test") |> should.be_false
  calendar_api.identity_seed(
    calendar_api.CalendarIdentity("primary-account@example.test"),
    "weak-key",
  )
  |> should.equal(Error("calendar_identity_invalid"))
}

pub fn calendar_pages_enforce_page_item_and_response_bounds_test() {
  calendar_api.collect_pages(
    [
      calendar_api.EventsPage([fixture_event("etag-1")], "page-2", 200),
      calendar_api.EventsPage([fixture_event("etag-2")], "", 200),
    ],
    2,
    2,
    400,
  )
  |> should.be_ok
  calendar_api.collect_pages(
    [calendar_api.EventsPage([fixture_event("etag-1")], "", 401)],
    1,
    1,
    400,
  )
  |> should.equal(Error("calendar_response_limit_exceeded"))
}

pub fn authorization_bound_executor_collects_pages_before_submission_test() {
  let authority =
    calendar_api.read_authority(fixture_authorization(), fixture_context())
    |> should.be_ok
  calendar_api.execute_pages_with(
    authority,
    authorized_calendar_url(),
    fn(url) {
      case string.contains(url, "pageToken=page-2") {
        True -> Ok(calendar_api.EventsPage([fixture_event("etag-2")], "", 200))
        False ->
          Ok(calendar_api.EventsPage([fixture_event("etag-1")], "page-2", 200))
      }
    },
    fn(events) { Ok(list.length(events)) },
  )
  |> should.equal(Ok(2))
  calendar_api.read_authority(
    fixture_authorization(),
    operating_contracts.ConnectorSubmissionContext(
      ..fixture_context(),
      configuration_hash: string.repeat("x", 64),
    ),
  )
  |> should.equal(Error("calendar_authority_mismatch"))
}

pub fn ineffective_activation_stops_before_page_transport_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(ingest) = event_ingest.start(db_subject)
  calendar_api.execute_pages(
    fixture_registry(),
    db_subject,
    ingest.data,
    fixture_authorization(),
    fixture_context(),
    authorized_calendar_url(),
    fn(_) { Error("transport_must_not_run") },
  )
  |> should.equal(Error("calendar_activation_not_effective"))
}

pub fn production_executor_owns_variable_pages_and_one_read_attempt_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let now_ms = time.now_ms()
  let preparation = live_fixture_preparation(now_ms)
  let authorization = live_fixture_authorization(now_ms)
  let assert Ok(_) =
    db.create_canary_preparation_authorization(db_subject, preparation)
  let assert Ok(_) =
    google_execution_fixture.seed_authorization_proofs(
      db_subject,
      preparation,
      authorization,
    )
  let assert Ok(_) = db.create_canary_authorization(db_subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      db_subject,
      authorization.authorization_id,
      "calendar:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(enabled) =
    connector_activation.enable_set(
      db_subject,
      authorization.authorization_id,
      "calendar:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(calendar_activation) =
    list.find(enabled, fn(value) { value.connector_id == "calendar" })
  let assert Ok(attempt) =
    db.reserve_connector_read(
      db_subject,
      "attempt:calendar-pages",
      calendar_activation.activation_id,
      authorization.authorization_id,
      "worker:calendar-pages",
      10_000,
    )
  let assert Ok(_) =
    db.begin_connector_read(
      db_subject,
      attempt.attempt_id,
      "worker:calendar-pages",
    )
  let context =
    operating_contracts.ConnectorSubmissionContext(
      ..fixture_context(),
      activation_version: calendar_activation.version,
      authorization_id: authorization.authorization_id,
      attempt_id: attempt.attempt_id,
      worker_id: "worker:calendar-pages",
    )
  let assert Ok(ingest) = event_ingest.start(db_subject)
  let result =
    calendar_api.execute_pages(
      fixture_registry(),
      db_subject,
      ingest.data,
      authorization,
      context,
      live_authorized_calendar_url(authorization),
      fn(url) {
        case string.contains(url, "pageToken=page-2") {
          True ->
            Ok(calendar_api.EventsPage(
              [
                calendar_api.CalendarEvent(
                  ..fixture_event("etag-2"),
                  event_id: "event-2",
                ),
              ],
              "",
              200,
            ))
          False ->
            Ok(calendar_api.EventsPage([fixture_event("etag-1")], "page-2", 200))
        }
      },
    )
    |> should.be_ok
  let assert Some(inserted) = result
  list.length(inserted) |> should.equal(2)
}

pub fn evidence_batch_rolls_back_first_insert_when_second_item_fails_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let now_ms = time.now_ms()
  let preparation = live_fixture_preparation(now_ms)
  let authorization = live_fixture_authorization(now_ms)
  let assert Ok(_) =
    db.create_canary_preparation_authorization(db_subject, preparation)
  let assert Ok(_) =
    google_execution_fixture.seed_authorization_proofs(
      db_subject,
      preparation,
      authorization,
    )
  let assert Ok(_) = db.create_canary_authorization(db_subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      db_subject,
      authorization.authorization_id,
      "calendar:rollback-prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(enabled) =
    connector_activation.enable_set(
      db_subject,
      authorization.authorization_id,
      "calendar:rollback-enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(calendar_activation) =
    list.find(enabled, fn(value) { value.connector_id == "calendar" })
  let assert Ok(attempt) =
    db.reserve_connector_read(
      db_subject,
      "attempt:calendar-rollback",
      calendar_activation.activation_id,
      authorization.authorization_id,
      "worker:calendar-rollback",
      10_000,
    )
  let assert Ok(_) =
    db.begin_connector_read(
      db_subject,
      attempt.attempt_id,
      "worker:calendar-rollback",
    )
  let context =
    operating_contracts.ConnectorSubmissionContext(
      ..fixture_context(),
      activation_version: calendar_activation.version,
      authorization_id: authorization.authorization_id,
      attempt_id: attempt.attempt_id,
      worker_id: "worker:calendar-rollback",
    )
  let first_result =
    fixture_event("etag-rollback-1")
    |> calendar_api.event_to_result
    |> should.be_ok
  let first =
    connector_adapter.normalize(fixture_registry(), first_result)
    |> should.be_ok
  let second_result =
    calendar_api.CalendarEvent(
      ..fixture_event("etag-rollback-2"),
      event_id: "event-rollback-2",
    )
    |> calendar_api.event_to_result
    |> should.be_ok
  let second =
    connector_adapter.normalize(fixture_registry(), second_result)
    |> should.be_ok
  let invalid_second =
    operating_contracts.EvidenceEvent(
      ..second,
      provenance: dict.insert(
        second.provenance,
        "scope",
        operating_contracts.StructuredString("scope:forged"),
      ),
    )
  db.submit_authorized_connector_evidence_batch(db_subject, context, [
    #(first, []),
    #(invalid_second, []),
  ])
  |> should.equal(Error("connector_submission_context_mismatch"))
  db.get_stored_evidence(db_subject, first.event_id)
  |> should.equal(Ok(None))
  db.list_operational_audit(
    db_subject,
    "connector_read_attempt",
    attempt.attempt_id,
  )
  |> should.be_ok
  |> list.map(fn(record) { record.action })
  |> should.equal([
    "connector.read.reserved",
    "connector.read.request_started",
  ])
}

pub fn exact_provider_version_dedupes_across_poll_times_test() {
  let first =
    calendar_api.event_to_result(fixture_event("etag-1")) |> should.be_ok
  let second =
    calendar_api.event_to_result(
      calendar_api.CalendarEvent(..fixture_event("etag-1"), observed_at_ms: 999),
    )
    |> should.be_ok
  second.source_event_id |> should.equal(first.source_event_id)
  second.content_hash |> should.equal(first.content_hash)
}

pub fn cancelled_event_is_compact_and_versioned_test() {
  let cancelled =
    calendar_api.CalendarEvent(
      ..fixture_event("etag-cancelled"),
      status: "cancelled",
      summary: "",
      recurring_event_id: None,
    )
  let result = calendar_api.event_to_result(cancelled) |> should.be_ok
  dict.get(result.normalized_data, "status")
  |> should.equal(Ok(operating_contracts.StructuredString("cancelled")))
}

pub fn cancelled_tombstone_without_schedule_is_compact_test() {
  let page =
    calendar_api.decode_events_page_response(
      "{\"items\":[{\"id\":\"event-cancelled\",\"etag\":\"etag-cancelled\",\"status\":\"cancelled\",\"updated\":\"2026-08-09T08:00:00Z\",\"eventType\":\"default\",\"transparency\":\"opaque\",\"visibility\":\"default\"}]}",
    )
    |> should.be_ok
  let assert [event] = page.events
  let result = calendar_api.event_to_result(event) |> should.be_ok
  result.summary |> should.equal("Cancelled calendar event")
  dict.get(result.normalized_data, "start") |> should.equal(Error(Nil))
  dict.get(result.normalized_data, "end") |> should.equal(Error(Nil))
}

fn fixture_event(etag: String) -> calendar_api.CalendarEvent {
  calendar_api.CalendarEvent(
    event_id: "event-1",
    etag:,
    status: "confirmed",
    summary: "Synthetic appointment",
    start: "2026-08-10T09:00:00Z",
    end: "2026-08-10T09:30:00Z",
    updated: "2026-08-09T08:00:00Z",
    recurring_event_id: Some("series-1"),
    event_type: "default",
    transparency: "opaque",
    visibility: "default",
    updated_at_ms: 1_786_204_800_000,
    observed_at_ms: 1,
  )
}

fn authorized_calendar_url() -> String {
  "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&showDeleted=true&timeMin=1970-01-01T00%3A00%3A00Z&timeMax=1970-01-08T00%3A00%3A00Z&maxResults=2&fields=nextPageToken%2Citems%28id%2Cetag%2Cstatus%2Csummary%2Cstart%28date%2CdateTime%29%2Cend%28date%2CdateTime%29%2Cupdated%2CrecurringEventId%2CeventType%2Ctransparency%2Cvisibility%29"
}

fn fixture_authorization() -> operating_contracts.CanaryAuthorizationV1 {
  operating_contracts.CanaryAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:calendar-test",
    preparation_authorization_id: "authorization:preparation-test",
    canary_id: "canary:local-test",
    domain_id: "domain:local-test",
    concern_id: "concern:domain:local-test:awareness",
    policy_refs: ["policy:canary:local-test"],
    connectors: [
      operating_contracts.AuthorizedConnectorV1(
        connector_id: "calendar",
        activation_id: "activation:calendar-test",
        configuration_ref: "configuration:calendar-local-test",
        configuration_hash: string.repeat("d", 64),
        account_fingerprint: string.repeat("e", 64),
        oauth_proof_ref: "proof:calendar-oauth",
        identity_proof_ref: "proof:calendar-identity",
        oauth_scope: "https://www.googleapis.com/auth/calendar.readonly",
        capability: "calendar.read",
        retention_policy_ref: "retention:calendar-compact",
        poll_interval_ms: 60_000,
        max_pages_per_poll: 2,
        max_items_per_poll: 2,
        max_response_bytes: 400,
      ),
    ],
    activation_grants: ["connector.disable", "connector.enable"],
    monitor_id: "monitor:local-test",
    monitor_capability_hash: string.repeat("a", 64),
    monitor_runtime_ref: "runtime:local-test",
    monitor_prompt_hash: string.repeat("b", 64),
    monitor_interval_ms: 60_000,
    monitor_grants: ["attention.claim", "attention.read"],
    attention_owner: "codex",
    attention_target: "codex_monitor",
    discord_delivery_allowed: False,
    starts_at_ms: 0,
    ends_at_ms: 604_800_000,
    metric_ids: ["metric:evidence-captured"],
    metric_review_owner_ref: "operator:metrics-reviewer",
    authorized_by_ref: "operator:reviewer",
    rollback_owner_ref: "operator:rollback-owner",
  )
}

fn fixture_context() -> operating_contracts.ConnectorSubmissionContext {
  operating_contracts.ConnectorSubmissionContext(
    activation_id: "activation:calendar-test",
    activation_version: 2,
    authorization_id: "authorization:calendar-test",
    attempt_id: "attempt:calendar-test",
    worker_id: "worker:calendar-test",
    connector_id: "calendar",
    capability: "calendar.read",
    oauth_scope: "https://www.googleapis.com/auth/calendar.readonly",
    configuration_hash: string.repeat("d", 64),
    account_fingerprint: string.repeat("e", 64),
    domain_id: "domain:local-test",
    concern_id: "concern:domain:local-test:awareness",
  )
}

fn fixture_registry() -> connector_registry.Registry {
  connector_registry.build(
    [
      connector_registry.ConnectorDescriptor(
        schema_version: 1,
        connector_id: "calendar",
        display_name: "Calendar",
        source_kind: "connector",
        capabilities: ["calendar.read"],
        scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
        descriptor_provenance_ref: "descriptor://calendar/test",
        summary_limit: 512,
        value_limit: 1024,
        read_authority_ref: None,
        write_authority_ref: None,
        policy_boundary_ref: "policy://canary/local-test",
      ),
    ],
    [
      connector_registry.ConnectorActivation(
        schema_version: 1,
        connector_id: "calendar",
        state: "enabled",
        configuration_ref: "config://calendar/local-test",
      ),
    ],
  )
  |> should.be_ok
}

fn live_fixture_preparation(
  now_ms: Int,
) -> operating_contracts.CanaryPreparationAuthorizationV1 {
  operating_contracts.CanaryPreparationAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:preparation-calendar-test",
    canary_id: "canary:local-test",
    oauth_client_ref: "oauth-client:calendar-test",
    oauth_client_hash: string.repeat("a", 64),
    connectors: [
      operating_contracts.PreparationConnectorV1(
        connector_id: "calendar",
        configuration_ref: "configuration:calendar-local-test",
        oauth_scope: "https://www.googleapis.com/auth/calendar.readonly",
        identity_endpoint_id: "calendar.calendars.get",
      ),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: now_ms + 700_000,
    authorized_by_ref: "operator:reviewer",
  )
}

fn live_fixture_authorization(
  now_ms: Int,
) -> operating_contracts.CanaryAuthorizationV1 {
  operating_contracts.CanaryAuthorizationV1(
    ..fixture_authorization(),
    authorization_id: "authorization:calendar-test",
    preparation_authorization_id: "authorization:preparation-calendar-test",
    starts_at_ms: now_ms - 1000,
    ends_at_ms: now_ms + 600_000,
  )
}

fn live_authorized_calendar_url(
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> String {
  "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&showDeleted=true&timeMin="
  <> uri.percent_encode(time.format_ms_rfc3339_utc(authorization.starts_at_ms))
  <> "&timeMax="
  <> uri.percent_encode(time.format_ms_rfc3339_utc(authorization.ends_at_ms))
  <> "&maxResults=2&fields=nextPageToken%2Citems%28id%2Cetag%2Cstatus%2Csummary%2Cstart%28date%2CdateTime%29%2Cend%28date%2CdateTime%29%2Cupdated%2CrecurringEventId%2CeventType%2Ctransparency%2Cvisibility%29"
}
