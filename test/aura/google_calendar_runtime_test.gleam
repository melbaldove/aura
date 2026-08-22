import aura/config
import aura/connector_activation
import aura/connector_adapter
import aura/connector_registry
import aura/connector_runtime
import aura/db
import aura/event_ingest
import aura/google_calendar_runtime
import aura/google_execution_fixture
import aura/google_http_client
import aura/google_oauth_runtime
import aura/integrations/calendar_api
import aura/oauth
import aura/operating_contracts
import aura/test_helpers
import aura/time
import aura/xdg
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

const calendar_scope = "https://www.googleapis.com/auth/calendar.readonly"

type System {
  System(
    root: String,
    paths: xdg.Paths,
    db_subject: process.Subject(db.DbMessage),
    ingest_subject: process.Subject(event_ingest.IngestMessage),
    authorization: operating_contracts.CanaryAuthorizationV1,
    activation_id: String,
    configurations: List(config.ConnectorConfiguration),
  )
}

pub fn main() {
  gleeunit.main()
}

pub fn production_calendar_reader_commits_two_pages_and_checkpoint_test() {
  let system = setup()
  let receipt =
    run(system, "attempt:calendar-runtime-1", fixture_transport)
    |> should.be_ok
  receipt.evidence_count |> should.equal(2)
  receipt.page_count |> should.equal(2)
  let assert Ok(Some(checkpoint)) =
    db.get_connector_checkpoint(
      system.db_subject,
      "configuration:calendar-runtime-test",
      system.activation_id,
    )
  checkpoint.cursor_kind |> should.equal("calendar_poll")
  should.be_true(checkpoint.next_due_at_ms > time.now_ms())
  let assert [first_event] =
    fixture("calendar-events-page-1.json")
    |> calendar_api.decode_events_page_response
    |> should.be_ok
    |> fn(page) { page.events }
  let connector_result =
    first_event |> calendar_api.event_to_result |> should.be_ok
  let expected =
    connector_adapter.normalize(
      calendar_registry("configuration:calendar-runtime-test"),
      connector_result,
    )
    |> should.be_ok
  let assert Ok(Some(stored)) =
    db.get_stored_evidence(system.db_subject, expected.event_id)
  dict.get(stored.envelope.provenance, "configuration_ref")
  |> should.equal(
    Ok(operating_contracts.StructuredString(
      "configuration:calendar-runtime-test",
    )),
  )
  let _ = simplifile.delete_all([system.root])
}

pub fn calendar_response_decoder_rejects_unapproved_fields_test() {
  calendar_api.decode_events_page_response(
    "{\"items\":[{\"id\":\"event-1\",\"etag\":\"etag-1\",\"status\":\"confirmed\",\"summary\":\"Synthetic\",\"start\":{\"dateTime\":\"2026-08-10T09:00:00Z\"},\"end\":{\"dateTime\":\"2026-08-10T09:30:00Z\"},\"updated\":\"2026-08-09T08:00:00Z\",\"eventType\":\"default\",\"transparency\":\"opaque\",\"visibility\":\"default\",\"attendees\":[{\"email\":\"private@example.test\"}]}]}",
  )
  |> should.equal(Error("calendar_response_fields_invalid"))
}

pub fn calendar_next_page_cycle_fails_without_evidence_test() {
  let system = setup()
  run(system, "attempt:calendar-runtime-cycle", fn(_, _, _) {
    response(200, "{\"items\":[],\"nextPageToken\":\"page-2\"}")
  })
  |> should.equal(Error("calendar_page_token_cycle"))
  let _ = simplifile.delete_all([system.root])
}

pub fn exact_repeat_with_later_poll_time_is_idempotent_test() {
  let system = setup()
  run(system, "attempt:calendar-repeat-1", fixture_transport) |> should.be_ok
  run(system, "attempt:calendar-repeat-2", fixture_transport) |> should.be_ok
  let assert Ok(Some(checkpoint)) =
    db.get_connector_checkpoint(
      system.db_subject,
      "configuration:calendar-runtime-test",
      system.activation_id,
    )
  checkpoint.version |> should.equal(2)
  let _ = simplifile.delete_all([system.root])
}

pub fn empty_page_atomically_commits_the_next_due_checkpoint_test() {
  let system = setup()
  let receipt =
    run(system, "attempt:calendar-empty", fn(_, _, _) {
      response(200, "{\"items\":[]}")
    })
    |> should.be_ok
  receipt.evidence_count |> should.equal(0)
  let assert Ok(Some(checkpoint)) =
    db.get_connector_checkpoint(
      system.db_subject,
      "configuration:calendar-runtime-test",
      system.activation_id,
    )
  checkpoint.version |> should.equal(1)
  let _ = simplifile.delete_all([system.root])
}

pub fn concurrent_disable_discards_calendar_read_without_checkpoint_test() {
  let system = setup()
  let provider_calls = process.new_subject()
  process.send(provider_calls, 0)
  run(system, "attempt:calendar-concurrent-disable", fn(guard, url, attempt) {
    let assert Ok(count) = process.receive(provider_calls, 1000)
    process.send(provider_calls, count + 1)
    let assert Ok(_) =
      connector_activation.begin_disable_set(
        system.db_subject,
        system.authorization.authorization_id,
        "calendar-runtime:concurrent-disable",
        system.authorization.rollback_owner_ref,
        ["connector.disable"],
      )
    fixture_transport(guard, url, attempt)
  })
  |> should.equal(Error("calendar_activation_not_effective"))
  db.get_connector_checkpoint(
    system.db_subject,
    "configuration:calendar-runtime-test",
    system.activation_id,
  )
  |> should.equal(Ok(None))
  process.receive(provider_calls, 1000) |> should.equal(Ok(1))
  let _ = simplifile.delete_all([system.root])
}

pub fn calendar_rate_limit_uses_provider_retry_after_test() {
  let system = setup()
  let before = time.now_ms()
  run(system, "attempt:calendar-retry-after", fn(_, _, _) {
    response_with_retry(429, "{}", 120_000)
  })
  |> should.be_error
  let assert Ok(Some(checkpoint)) =
    db.get_connector_checkpoint(
      system.db_subject,
      "configuration:calendar-runtime-test",
      system.activation_id,
    )
  should.be_true(checkpoint.next_due_at_ms >= before + 120_000)
  let _ = simplifile.delete_all([system.root])
}

pub fn calendar_provider_statuses_finish_or_retry_the_attempt_test() {
  [401, 403, 429, 503]
  |> list.each(fn(status) {
    let system = setup()
    let attempt_id = "attempt:calendar-status-" <> string.inspect(status)
    run(system, attempt_id, fn(_, _, _) { response(status, "{}") })
    |> should.be_error
    let audits =
      db.list_operational_audit(
        system.db_subject,
        "connector_read_attempt",
        attempt_id,
      )
      |> should.be_ok
    list.any(audits, fn(record) {
      record.action == "connector.read.failed"
      || record.action == "connector.read.interrupted"
    })
    |> should.be_true
    let _ = simplifile.delete_all([system.root])
  })
}

pub fn calendar_unauthorized_response_refreshes_once_then_retries_test() {
  let system = setup()
  let provider_calls = process.new_subject()
  process.send(provider_calls, 0)
  let refresh_calls = process.new_subject()
  let provider = fn(guard, url, attempt) {
    let assert Ok(count) = process.receive(provider_calls, 1000)
    process.send(provider_calls, count + 1)
    case count {
      0 -> response(401, "{}")
      _ -> fixture_transport(guard, url, attempt)
    }
  }
  let force_refresh = fn(configuration_ref, _, _, _) {
    process.send(refresh_calls, Nil)
    use current <- result.try(oauth.load_calendar_token(
      system.paths,
      configuration_ref,
    ))
    oauth.replace_scoped_token(
      system.paths,
      current,
      oauth.ScopedTokenSetV2(
        ..current,
        issued_at_ms: current.issued_at_ms + 1,
        expires_at_ms: current.expires_at_ms + 1,
        access_token: "synthetic-refreshed-calendar-token",
      ),
    )
  }
  google_calendar_runtime.run_once_with_transports_for_test(
    system.db_subject,
    system.ingest_subject,
    system.paths,
    system.configurations,
    system.authorization.authorization_id,
    system.activation_id,
    "attempt:calendar-refresh",
    "worker:calendar-runtime-test",
    fn() { google_oauth_runtime.BeforeDispatch },
    force_refresh,
    provider,
  )
  |> should.be_ok
  process.receive(refresh_calls, 1000) |> should.be_ok
  process.receive(refresh_calls, 20) |> should.be_error
  let assert Ok(provider_count) = process.receive(provider_calls, 1000)
  provider_count |> should.equal(3)
  let _ = simplifile.delete_all([system.root])
}

pub fn disabled_or_expired_calendar_authority_makes_zero_provider_calls_test() {
  let disabled = setup()
  let calls = process.new_subject()
  let assert Ok(_) =
    connector_activation.begin_disable_set(
      disabled.db_subject,
      disabled.authorization.authorization_id,
      "calendar-runtime:disable-before-read",
      disabled.authorization.rollback_owner_ref,
      ["connector.disable"],
    )
  run(disabled, "attempt:calendar-disabled", fn(_, _, _) {
    process.send(calls, Nil)
    google_http_client.BeforeDispatch("unexpected")
  })
  |> should.be_error
  process.receive(calls, 20) |> should.be_error
  let _ = simplifile.delete_all([disabled.root])

  let expired = setup_with_duration(200)
  process.sleep(250)
  run(expired, "attempt:calendar-expired", fn(_, _, _) {
    process.send(calls, Nil)
    google_http_client.BeforeDispatch("unexpected")
  })
  |> should.be_error
  process.receive(calls, 20) |> should.be_error
  let _ = simplifile.delete_all([expired.root])
}

pub fn cumulative_calendar_response_cap_fails_before_checkpoint_test() {
  let system = setup()
  run(system, "attempt:calendar-response-cap", fn(_, _, _) {
    response(200, string.repeat("x", 100_001))
  })
  |> should.equal(Error("calendar_response_limit_exceeded"))
  db.get_connector_checkpoint(
    system.db_subject,
    "configuration:calendar-runtime-test",
    system.activation_id,
  )
  |> should.equal(Ok(None))
  let _ = simplifile.delete_all([system.root])
}

pub fn calendar_page_and_item_caps_fail_before_checkpoint_test() {
  let page_system = setup()
  let page_calls = process.new_subject()
  process.send(page_calls, 0)
  run(page_system, "attempt:calendar-page-cap", fn(_, _, _) {
    let assert Ok(count) = process.receive(page_calls, 1000)
    process.send(page_calls, count + 1)
    response(
      200,
      "{\"items\":[],\"nextPageToken\":\"page-"
        <> string.inspect(count + 2)
        <> "\"}",
    )
  })
  |> should.equal(Error("calendar_page_limit_exceeded"))
  db.get_connector_checkpoint(
    page_system.db_subject,
    "configuration:calendar-runtime-test",
    page_system.activation_id,
  )
  |> should.equal(Ok(None))
  let _ = simplifile.delete_all([page_system.root])

  let item_system = setup()
  let first = fixture("calendar-events-page-1.json")
  let one_event =
    first
    |> string.split_once(on: "[{")
    |> should.be_ok
    |> fn(parts) {
      parts.1
      |> string.split_once(on: "}],\"nextPageToken\"")
      |> should.be_ok
      |> fn(event_parts) { "{" <> event_parts.0 <> "}" }
    }
  let five =
    [1, 2, 3, 4, 5]
    |> list.map(fn(index) {
      string.replace(one_event, "event-1", "event-" <> string.inspect(index))
    })
    |> string.join(with: ",")
  run(item_system, "attempt:calendar-item-cap", fn(_, _, _) {
    response(200, "{\"items\":[" <> five <> "]}")
  })
  |> should.equal(Error("calendar_item_limit_exceeded"))
  let _ = simplifile.delete_all([item_system.root])
}

pub fn invalid_calendar_timestamp_and_forbidden_nested_field_fail_closed_test() {
  calendar_api.decode_events_page_response(string.replace(
    fixture("calendar-events-page-1.json"),
    "2026-08-09T08:00:00Z",
    "not-a-time",
  ))
  |> should.equal(Error("calendar_response_invalid"))
  calendar_api.decode_events_page_response(string.replace(
    fixture("calendar-events-page-1.json"),
    "{\"dateTime\":\"2026-08-10T09:00:00Z\"}",
    "{\"dateTime\":\"2026-08-10T09:00:00Z\",\"timeZone\":\"Private/Zone\"}",
  ))
  |> should.equal(Error("calendar_response_fields_invalid"))

  let offset =
    fixture("calendar-events-page-1.json")
    |> string.replace("2026-08-10T09:00:00Z", "2026-08-10T19:00:00+10:00")
    |> string.replace("2026-08-10T09:30:00Z", "2026-08-10T19:30:00+10:00")
    |> string.replace("2026-08-09T08:00:00Z", "2026-08-09T18:00:00+10:00")
  calendar_api.decode_events_page_response(offset) |> should.be_ok
  calendar_api.decode_events_page_response(
    "{\"items\":[{\"id\":\"event-invalid-date\",\"etag\":\"etag-invalid-date\",\"status\":\"confirmed\",\"summary\":\"Synthetic\",\"start\":{\"date\":\"2026-99-99\"},\"end\":{\"date\":\"2026-99-99\"},\"updated\":\"2026-08-09T08:00:00Z\",\"eventType\":\"default\",\"transparency\":\"opaque\",\"visibility\":\"default\"}]}",
  )
  |> should.equal(Error("calendar_event_invalid"))
}

pub fn calendar_scope_failure_starts_safe_disable_test() {
  let system = setup()
  run(system, "attempt:calendar-scope", fn(_, _, _) {
    response(403, "{\"reason\":\"ACCESS_TOKEN_SCOPE_INSUFFICIENT\"}")
  })
  |> should.equal(Error("calendar_events_scope_insufficient"))
  let effective =
    db.list_effective_connector_activations(system.db_subject) |> should.be_ok
  list.any(effective, fn(value) { value.activation_id == system.activation_id })
  |> should.be_false
  let _ = simplifile.delete_all([system.root])
}

pub fn mismatched_calendar_token_proof_makes_zero_provider_calls_test() {
  let system = setup()
  let current =
    oauth.load_calendar_token(
      system.paths,
      "configuration:calendar-runtime-test",
    )
    |> should.be_ok
  let token_path =
    oauth.scoped_token_path(system.paths, current.configuration_ref)
  let _ = simplifile.delete(token_path)
  oauth.save_calendar_token(
    system.paths,
    oauth.ScopedTokenSetV2(..current, oauth_proof_ref: "proof:forged"),
  )
  |> should.be_ok
  let calls = process.new_subject()
  run(system, "attempt:calendar-proof-mismatch", fn(_, _, _) {
    process.send(calls, Nil)
    google_http_client.BeforeDispatch("unexpected")
  })
  |> should.equal(Error("calendar_token_authority_mismatch"))
  process.receive(calls, 20) |> should.be_error
  let _ = simplifile.delete_all([system.root])
}

pub fn calendar_runtime_actor_selects_calendar_without_parallel_worker_test() {
  let system = setup()
  let calls = process.new_subject()
  let runner = fn(connector_id, _, activation_id, attempt_id, _) {
    process.send(calls, #(connector_id, activation_id))
    process.sleep(100)
    Ok(connector_runtime.RunReceipt(connector_id, attempt_id, 0))
  }
  let name = process.new_name("calendar_runtime_single_worker_test")
  let started =
    connector_runtime.start_named_with_runner_for_test(
      name,
      system.db_subject,
      system.configurations,
      runner,
    )
    |> should.be_ok
  process.unlink(started.pid)
  process.receive(calls, 1000)
  |> should.equal(Ok(#("calendar", system.activation_id)))
  connector_runtime.run_once(
    started.data,
    system.authorization.authorization_id,
    system.activation_id,
  )
  |> should.equal(Error("connector_read_in_progress"))
  process.sleep(120)
  process.receive(calls, 20) |> should.be_error
  process.kill(started.pid)
  let _ = simplifile.delete_all([system.root])
}

fn run(
  system: System,
  attempt_id: String,
  transport: google_calendar_runtime.ProviderTransport,
) -> Result(google_calendar_runtime.RunReceipt, String) {
  google_calendar_runtime.run_once_with_transports_for_test(
    system.db_subject,
    system.ingest_subject,
    system.paths,
    system.configurations,
    system.authorization.authorization_id,
    system.activation_id,
    attempt_id,
    "worker:calendar-runtime-test",
    fn() { google_oauth_runtime.BeforeDispatch },
    fn(_, _, _, _) { Error("unexpected_forced_refresh") },
    transport,
  )
}

fn fixture_transport(_, url: String, _) -> google_http_client.Outcome {
  case string.contains(url, "pageToken=page-2") {
    True -> response(200, fixture("calendar-events-page-2.json"))
    False -> response(200, fixture("calendar-events-page-1.json"))
  }
}

fn response(status: Int, body: String) -> google_http_client.Outcome {
  response_with_retry(status, body, 0)
}

fn response_with_retry(
  status: Int,
  body: String,
  retry_after_ms: Int,
) -> google_http_client.Outcome {
  google_http_client.Response(google_http_client.HttpResponse(
    status:,
    body:,
    retry_after_ms:,
  ))
}

fn calendar_registry(configuration_ref: String) -> connector_registry.Registry {
  connector_registry.build(
    [
      connector_registry.ConnectorDescriptor(
        schema_version: 1,
        connector_id: "calendar",
        display_name: "Calendar",
        source_kind: "connector",
        capabilities: ["calendar.read"],
        scopes: [calendar_scope],
        descriptor_provenance_ref: "descriptor://aura/calendar-readonly/v1",
        summary_limit: 512,
        value_limit: 1024,
        read_authority_ref: None,
        write_authority_ref: None,
        policy_boundary_ref: "policy://aura/evidence/v1",
      ),
    ],
    [
      connector_registry.ConnectorActivation(
        schema_version: 1,
        connector_id: "calendar",
        state: "enabled",
        configuration_ref:,
      ),
    ],
  )
  |> should.be_ok
}

fn fixture(name: String) -> String {
  simplifile.read("test/fixtures/google/" <> name) |> should.be_ok
}

fn setup() -> System {
  setup_with_duration(600_000)
}

fn setup_with_duration(duration_ms: Int) -> System {
  let root = "/tmp/aura-calendar-runtime-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([root])
  let _ = simplifile.create_directory_all(root)
  let paths = xdg.resolve_with_home(root)
  let now_ms = time.now_ms()
  let identity_key = string.repeat("c", 32)
  let fingerprint =
    calendar_api.identity_seed(
      calendar_api.CalendarIdentity("primary-calendar@example.test"),
      identity_key,
    )
    |> should.be_ok
    |> fn(seed) { seed.account_fingerprint }
  let preparation = preparation(now_ms)
  let authorization = authorization(now_ms, fingerprint, duration_ms)
  let assert Ok(db_subject) = db.start(":memory:")
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
      "calendar-runtime:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(enabled) =
    connector_activation.enable_set(
      db_subject,
      authorization.authorization_id,
      "calendar-runtime:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(activation) =
    list.find(enabled, fn(value) { value.connector_id == "calendar" })
  oauth.save_calendar_token(
    paths,
    token(preparation, authorization, identity_key, now_ms),
  )
  |> should.be_ok
  let assert Ok(ingest) = event_ingest.start(db_subject)
  System(
    root:,
    paths:,
    db_subject:,
    ingest_subject: ingest.data,
    authorization:,
    activation_id: activation.activation_id,
    configurations: [configuration()],
  )
}

fn preparation(
  now_ms: Int,
) -> operating_contracts.CanaryPreparationAuthorizationV1 {
  operating_contracts.CanaryPreparationAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:preparation-calendar-runtime-test",
    canary_id: "canary:calendar-runtime-test",
    oauth_client_ref: "oauth-client:calendar-runtime-test",
    oauth_client_hash: string.repeat("a", 64),
    connectors: [
      operating_contracts.PreparationConnectorV1(
        connector_id: "calendar",
        configuration_ref: "configuration:calendar-runtime-test",
        oauth_scope: calendar_scope,
        identity_endpoint_id: "calendar.calendars.get",
      ),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: now_ms + 700_000,
    authorized_by_ref: "operator:calendar-runtime-test",
  )
}

fn authorization(
  now_ms: Int,
  account_fingerprint: String,
  duration_ms: Int,
) -> operating_contracts.CanaryAuthorizationV1 {
  operating_contracts.CanaryAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:calendar-runtime-test",
    preparation_authorization_id: "authorization:preparation-calendar-runtime-test",
    canary_id: "canary:calendar-runtime-test",
    domain_id: "domain:personal-life",
    concern_id: "concern:domain:personal-life:awareness",
    policy_refs: ["policy:personal-life-canary"],
    connectors: [
      operating_contracts.AuthorizedConnectorV1(
        connector_id: "calendar",
        activation_id: "activation:calendar-runtime-test",
        configuration_ref: "configuration:calendar-runtime-test",
        configuration_hash: hash("configuration:calendar-runtime-test"),
        account_fingerprint:,
        oauth_proof_ref: "proof:calendar-oauth",
        identity_proof_ref: "proof:calendar-identity",
        oauth_scope: calendar_scope,
        capability: "calendar.read",
        retention_policy_ref: "retention:calendar-compact",
        poll_interval_ms: 60_000,
        max_pages_per_poll: 2,
        max_items_per_poll: 4,
        max_response_bytes: 100_000,
      ),
    ],
    activation_grants: ["connector.disable", "connector.enable"],
    monitor_id: "monitor:calendar-runtime-test",
    monitor_capability_hash: string.repeat("b", 64),
    monitor_runtime_ref: "runtime:calendar-runtime-test",
    monitor_prompt_hash: string.repeat("c", 64),
    monitor_interval_ms: 60_000,
    monitor_grants: ["attention.claim", "attention.read"],
    attention_owner: "codex",
    attention_target: "codex_monitor",
    discord_delivery_allowed: False,
    starts_at_ms: now_ms - 1000,
    ends_at_ms: now_ms + duration_ms,
    metric_ids: ["metric:evidence-captured"],
    metric_review_owner_ref: "operator:metrics-reviewer",
    authorized_by_ref: "operator:calendar-runtime-test",
    rollback_owner_ref: "operator:rollback-owner",
  )
}

fn token(
  preparation: operating_contracts.CanaryPreparationAuthorizationV1,
  authorization: operating_contracts.CanaryAuthorizationV1,
  identity_key: String,
  now_ms: Int,
) -> oauth.ScopedTokenSetV2 {
  let assert [connector] = authorization.connectors
  oauth.ScopedTokenSetV2(
    session_ref: "session:calendar-runtime-test",
    oauth_effect_ref: "effect:calendar-runtime-test",
    preparation_authorization_id: preparation.authorization_id,
    connector_id: "calendar",
    configuration_ref: connector.configuration_ref,
    configuration_hash: connector.configuration_hash,
    oauth_client_ref: "oauth-client:fixture:calendar",
    oauth_client_hash: hash("oauth-client:calendar"),
    client_set_ref: preparation.oauth_client_ref,
    client_set_hash: preparation.oauth_client_hash,
    oauth_proof_ref: connector.oauth_proof_ref,
    oauth_result_hash: hash("oauth-result:calendar"),
    identity_proof_ref: connector.identity_proof_ref,
    identity_result_hash: hash("identity-result:calendar"),
    token_effect_ref: "effect:token:calendar-runtime-test",
    token_effect_result_hash: hash("token-effect:calendar-runtime-test"),
    account_fingerprint: connector.account_fingerprint,
    granted_scope: calendar_scope,
    issued_at_ms: now_ms,
    expires_at_ms: now_ms + 3_600_000,
    access_token: "synthetic-calendar-access-token",
    refresh_token: "synthetic-calendar-refresh-token",
    identity_hmac_key: identity_key,
  )
}

fn configuration() -> config.ConnectorConfiguration {
  config.ConnectorConfiguration(
    configuration_ref: "configuration:calendar-runtime-test",
    connector_id: "calendar",
    oauth_client_ref: "oauth-client:fixture:calendar",
    credential_ref: "credential:calendar-runtime-test",
    resource_ref: "resource:calendar-runtime-test",
    oauth_scope: calendar_scope,
    configuration_hash: hash("configuration:calendar-runtime-test"),
  )
}

fn hash(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}
