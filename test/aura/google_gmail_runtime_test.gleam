import aura/config
import aura/connector_activation
import aura/connector_runtime
import aura/db
import aura/event_ingest
import aura/google_execution_fixture
import aura/google_gmail_runtime
import aura/google_http_client
import aura/integrations/gmail_api
import aura/oauth
import aura/operating_contracts
import aura/test_helpers
import aura/time
import aura/xdg
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

const gmail_scope = "https://www.googleapis.com/auth/gmail.readonly"

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

pub fn production_reader_seeds_then_commits_bounded_pages_atomically_test() {
  let system = setup()
  let init =
    run(system, "attempt:gmail-init", fixture_transport) |> should.be_ok
  init.initialized |> should.be_true
  init.evidence_count |> should.equal(0)
  let poll =
    run(system, "attempt:gmail-poll", fixture_transport) |> should.be_ok
  poll.initialized |> should.be_false
  poll.evidence_count |> should.equal(2)
  poll.missing_count |> should.equal(1)
  poll.checkpoint_history_id |> should.equal("102")
  let assert Ok(Some(checkpoint)) =
    db.get_connector_checkpoint(
      system.db_subject,
      "configuration:gmail-runtime-test",
      system.activation_id,
    )
  checkpoint.cursor_value |> should.equal("102")
  checkpoint.version |> should.equal(2)
  let replay =
    run(system, "attempt:gmail-replay", fixture_transport) |> should.be_ok
  replay.evidence_count |> should.equal(2)
  let assert Ok(Some(replayed_checkpoint)) =
    db.get_connector_checkpoint(
      system.db_subject,
      "configuration:gmail-runtime-test",
      system.activation_id,
    )
  replayed_checkpoint.version |> should.equal(3)
  let audits =
    db.list_operational_audit(
      system.db_subject,
      "connector_checkpoint",
      "configuration:gmail-runtime-test:" <> system.activation_id,
    )
    |> should.be_ok
  list.any(audits, fn(record) {
    record.action == "connector.gmail.missing_resource_observed"
  })
  |> should.be_true
  let _ = simplifile.delete_all([system.root])
}

pub fn changed_provider_payload_rolls_back_checkpoint_test() {
  let system = setup()
  let _ =
    run(system, "attempt:gmail-conflict-init", fixture_transport)
    |> should.be_ok
  let _ =
    run(system, "attempt:gmail-conflict-seed", fixture_transport)
    |> should.be_ok
  let changed = fn(guard, url, attempt_number) {
    case string.contains(url, "/messages/message-1?") {
      True ->
        response(
          200,
          string.replace(
            fixture("gmail-message-1.json"),
            "Synthetic reminder",
            "Changed synthetic reminder",
          ),
        )
      False -> fixture_transport(guard, url, attempt_number)
    }
  }
  run(system, "attempt:gmail-conflict", changed)
  |> should.equal(Error("idempotency_conflict"))
  let assert Ok(Some(checkpoint)) =
    db.get_connector_checkpoint(
      system.db_subject,
      "configuration:gmail-runtime-test",
      system.activation_id,
    )
  checkpoint.version |> should.equal(2)
  let _ = simplifile.delete_all([system.root])
}

pub fn concurrent_disable_discards_the_started_read_without_checkpoint_test() {
  let system = setup()
  let disabling_transport = fn(guard, url, attempt_number) {
    let assert Ok(_) =
      connector_activation.begin_disable_set(
        system.db_subject,
        system.authorization.authorization_id,
        "gmail-runtime:concurrent-disable",
        system.authorization.rollback_owner_ref,
        ["connector.disable"],
      )
    fixture_transport(guard, url, attempt_number)
  }
  run(system, "attempt:gmail-concurrent-disable", disabling_transport)
  |> should.equal(Error("gmail_activation_not_effective"))
  db.get_connector_checkpoint(
    system.db_subject,
    "configuration:gmail-runtime-test",
    system.activation_id,
  )
  |> should.equal(Ok(None))
  let _ = simplifile.delete_all([system.root])
}

pub fn provider_statuses_have_closed_retry_safe_classes_test() {
  google_gmail_runtime.provider_status_error(401, "gmail_history")
  |> should.equal("gmail_history_unauthorized")
  google_gmail_runtime.provider_status_error(403, "gmail_history")
  |> should.equal("gmail_history_forbidden")
  google_gmail_runtime.provider_status_error(429, "gmail_history")
  |> should.equal("gmail_history_rate_limited")
  google_gmail_runtime.provider_status_error(503, "gmail_history")
  |> should.equal("gmail_history_provider_unavailable")
}

pub fn actual_provider_statuses_finish_or_retry_the_attempt_test() {
  [401, 403, 429, 503]
  |> list.each(fn(status) {
    let system = setup()
    let attempt_id = "attempt:gmail-status-" <> string.inspect(status)
    let _ =
      run(system, attempt_id <> "-init", fixture_transport) |> should.be_ok
    let status_transport = fn(_, url, _) {
      case string.contains(url, "/history?") {
        True -> response(status, "{}")
        False -> fixture_transport(google_http_client.Gmail, url, 1)
      }
    }
    run(system, attempt_id, status_transport) |> should.be_error
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

pub fn unauthorized_response_forces_one_refresh_then_retries_test() {
  let system = setup()
  let _ =
    run(system, "attempt:gmail-refresh-init", fixture_transport) |> should.be_ok
  let history_calls = process.new_subject()
  process.send(history_calls, 0)
  let refresh_calls = process.new_subject()
  let provider = fn(_, url, _) {
    case string.contains(url, "/history?") {
      False -> fixture_transport(google_http_client.Gmail, url, 1)
      True -> {
        let assert Ok(count) = process.receive(history_calls, 1000)
        process.send(history_calls, count + 1)
        case count {
          0 -> response(401, "{}")
          _ -> fixture_history_transport(url)
        }
      }
    }
  }
  let force_refresh = fn(configuration_ref, _, _, _) {
    process.send(refresh_calls, Nil)
    use current <- result.try(oauth.load_scoped_token(
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
        access_token: "synthetic-refreshed-access-token",
      ),
    )
  }
  google_gmail_runtime.run_once_with_transports_for_test(
    system.db_subject,
    system.ingest_subject,
    system.paths,
    system.configurations,
    system.authorization.authorization_id,
    system.activation_id,
    "attempt:gmail-refresh",
    "worker:gmail-runtime-test",
    google_oauth_runtime_before_dispatch,
    force_refresh,
    provider,
  )
  |> should.be_ok
  process.receive(refresh_calls, 1000) |> should.be_ok
  process.receive(refresh_calls, 20) |> should.be_error
  let assert Ok(history_count) = process.receive(history_calls, 1000)
  history_count |> should.equal(3)
  let _ = simplifile.delete_all([system.root])
}

pub fn insufficient_scope_response_starts_safe_disable_test() {
  let system = setup()
  let _ =
    run(system, "attempt:gmail-scope-init", fixture_transport) |> should.be_ok
  run(system, "attempt:gmail-scope", fn(_, url, _) {
    case string.contains(url, "/history?") {
      True -> response(403, "{\"reason\":\"ACCESS_TOKEN_SCOPE_INSUFFICIENT\"}")
      False -> fixture_transport(google_http_client.Gmail, url, 1)
    }
  })
  |> should.equal(Error("gmail_history_scope_insufficient"))
  let effective =
    db.list_effective_connector_activations(system.db_subject) |> should.be_ok
  list.any(effective, fn(value) { value.activation_id == system.activation_id })
  |> should.be_false
  let _ = simplifile.delete_all([system.root])
}

pub fn disabled_or_expired_authority_makes_zero_transport_calls_test() {
  let disabled = setup()
  let disabled_calls = process.new_subject()
  let assert Ok(_) =
    connector_activation.begin_disable_set(
      disabled.db_subject,
      disabled.authorization.authorization_id,
      "gmail-runtime:disable-before-run",
      disabled.authorization.rollback_owner_ref,
      ["connector.disable"],
    )
  run(disabled, "attempt:gmail-disabled", fn(_, _, _) {
    process.send(disabled_calls, Nil)
    google_http_client.BeforeDispatch("unexpected")
  })
  |> should.be_error
  process.receive(disabled_calls, 20) |> should.be_error
  let _ = simplifile.delete_all([disabled.root])

  let expired = setup_with_duration(200)
  process.sleep(250)
  let expired_calls = process.new_subject()
  run(expired, "attempt:gmail-expired", fn(_, _, _) {
    process.send(expired_calls, Nil)
    google_http_client.BeforeDispatch("unexpected")
  })
  |> should.be_error
  process.receive(expired_calls, 20) |> should.be_error
  let _ = simplifile.delete_all([expired.root])
}

pub fn mismatched_token_proof_makes_zero_transport_calls_test() {
  let system = setup()
  let current =
    oauth.load_scoped_token(system.paths, "configuration:gmail-runtime-test")
    |> should.be_ok
  let token_path =
    oauth.scoped_token_path(system.paths, current.configuration_ref)
  let _ = simplifile.delete(token_path)
  oauth.save_scoped_token(
    system.paths,
    oauth.ScopedTokenSetV2(..current, oauth_proof_ref: "proof:forged"),
  )
  |> should.be_ok
  let calls = process.new_subject()
  run(system, "attempt:gmail-proof-mismatch", fn(_, _, _) {
    process.send(calls, Nil)
    google_http_client.BeforeDispatch("unexpected")
  })
  |> should.equal(Error("gmail_token_authority_mismatch"))
  process.receive(calls, 20) |> should.be_error
  let _ = simplifile.delete_all([system.root])
}

pub fn cumulative_response_cap_fails_before_evidence_or_checkpoint_advance_test() {
  let system = setup()
  let _ =
    run(system, "attempt:gmail-cap-init", fixture_transport) |> should.be_ok
  let oversized = string.repeat("x", 100_001)
  run(system, "attempt:gmail-cap", fn(_, url, _) {
    case string.contains(url, "/history?") {
      True -> response(200, oversized)
      False -> fixture_transport(google_http_client.Gmail, url, 1)
    }
  })
  |> should.equal(Error("gmail_poll_response_limit_exceeded"))
  let assert Ok(Some(checkpoint)) =
    db.get_connector_checkpoint(
      system.db_subject,
      "configuration:gmail-runtime-test",
      system.activation_id,
    )
  checkpoint.version |> should.equal(1)
  let _ = simplifile.delete_all([system.root])
}

pub fn repeated_missing_id_is_fetched_once_and_counts_toward_global_limit_test() {
  let system = setup()
  let _ =
    run(system, "attempt:gmail-missing-init", fixture_transport) |> should.be_ok
  let missing_calls = process.new_subject()
  let transport = fn(_, url, _) {
    case string.contains(url, "pageToken=page-2") {
      True ->
        response(
          200,
          "{\"history\":[{\"messagesAdded\":[{\"message\":{\"id\":\"message-missing\"}},{\"message\":{\"id\":\"message-1\"}}]}],\"historyId\":\"102\"}",
        )
      False ->
        case string.contains(url, "/history?") {
          True ->
            response(
              200,
              "{\"history\":[{\"messagesAdded\":[{\"message\":{\"id\":\"message-missing\"}}]}],\"nextPageToken\":\"page-2\",\"historyId\":\"101\"}",
            )
          False ->
            case string.contains(url, "/messages/message-missing?") {
              True -> {
                process.send(missing_calls, Nil)
                response(404, "{}")
              }
              False -> fixture_transport(google_http_client.Gmail, url, 1)
            }
        }
    }
  }
  let receipt =
    run(system, "attempt:gmail-missing-repeat", transport) |> should.be_ok
  receipt.evidence_count |> should.equal(1)
  receipt.missing_count |> should.equal(1)
  process.receive(missing_calls, 1000) |> should.be_ok
  process.receive(missing_calls, 20) |> should.be_error
  let _ = simplifile.delete_all([system.root])
}

pub fn runtime_actor_allows_only_one_worker_per_activation_test() {
  let system = setup()
  let calls = process.new_subject()
  let runner = fn(_, _, activation_id, attempt_id, _) {
    process.send(calls, activation_id)
    process.sleep(100)
    Ok(connector_runtime.RunReceipt("gmail", attempt_id, 0))
  }
  let name = process.new_name("gmail_runtime_single_worker_test")
  let started =
    connector_runtime.start_named_with_runner_for_test(
      name,
      system.db_subject,
      system.configurations,
      runner,
    )
    |> should.be_ok
  process.unlink(started.pid)
  process.receive(calls, 1000) |> should.equal(Ok(system.activation_id))
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

pub fn runtime_worker_crash_cannot_start_overlapping_provider_read_test() {
  let system = setup()
  let provider_calls = process.new_subject()
  let runner = fn(_, _, activation_id, attempt_id, worker_id) {
    use _ <- result.try(db.reserve_connector_read(
      system.db_subject,
      attempt_id,
      activation_id,
      system.authorization.authorization_id,
      worker_id,
      300_000,
    ))
    use _ <- result.try(db.begin_connector_read(
      system.db_subject,
      attempt_id,
      worker_id,
    ))
    process.send(provider_calls, Nil)
    panic as "synthetic Gmail worker crash"
  }
  let name = process.new_name("gmail_runtime_crash_overlap_test")
  let started =
    connector_runtime.start_named_with_runner_for_test(
      name,
      system.db_subject,
      system.configurations,
      runner,
    )
    |> should.be_ok
  process.unlink(started.pid)
  process.receive(provider_calls, 1000) |> should.be_ok
  process.sleep(20)
  process.send(started.data, connector_runtime.Tick)
  process.sleep(20)
  process.receive(provider_calls, 50) |> should.be_error
  process.kill(started.pid)
  let _ = simplifile.delete_all([system.root])
}

pub fn history_gap_atomically_records_gap_and_starts_safe_disable_test() {
  let system = setup()
  let _ =
    run(system, "attempt:gmail-gap-init", fixture_transport) |> should.be_ok
  let receipt =
    run(system, "attempt:gmail-gap", fn(_, url, _) {
      case string.contains(url, "/history?") {
        True -> response(404, "{}")
        False -> fixture_transport(google_http_client.Gmail, url, 1)
      }
    })
    |> should.be_ok
  receipt.evidence_count |> should.equal(0)
  let assert Ok(Some(checkpoint)) =
    db.get_connector_checkpoint(
      system.db_subject,
      "configuration:gmail-runtime-test",
      system.activation_id,
    )
  checkpoint.gap_code |> should.equal("history_unavailable")
  checkpoint.cursor_value |> should.equal("100")
  let effective =
    db.list_effective_connector_activations(system.db_subject) |> should.be_ok
  list.any(effective, fn(value) { value.activation_id == system.activation_id })
  |> should.be_false
  let _ = simplifile.delete_all([system.root])
}

pub fn malformed_unbounded_and_body_bearing_provider_data_fails_closed_test() {
  gmail_api.decode_metadata_response(
    "{\"id\":\"message-1\",\"threadId\":\"thread-1\",\"historyId\":\"101\",\"internalDate\":\"1770000000000\",\"sizeEstimate\":1,\"payload\":{\"headers\":[],\"body\":{\"data\":\"secret\"}}}",
  )
  |> should.be_error
  gmail_api.decode_history_page_response(
    "{\"history\":[],\"historyId\":\"01\"}",
  )
  |> should.be_error
}

fn run(
  system: System,
  attempt_id: String,
  transport: google_gmail_runtime.ProviderTransport,
) -> Result(google_gmail_runtime.RunReceipt, String) {
  google_gmail_runtime.run_once_with_transports_for_test(
    system.db_subject,
    system.ingest_subject,
    system.paths,
    system.configurations,
    system.authorization.authorization_id,
    system.activation_id,
    attempt_id,
    "worker:gmail-runtime-test",
    google_oauth_runtime_before_dispatch,
    fn(_, _, _, _) { Error("unexpected_forced_refresh") },
    transport,
  )
}

fn google_oauth_runtime_before_dispatch() {
  // The token is fresh, so this callback must not run.
  panic as "fresh Gmail token attempted refresh"
}

fn fixture_transport(_, url: String, _) -> google_http_client.Outcome {
  case string.contains(url, "/profile?") {
    True -> response(200, fixture("gmail-profile.json"))
    False -> fixture_history_transport(url)
  }
}

fn fixture_history_transport(url: String) -> google_http_client.Outcome {
  case string.contains(url, "pageToken=page-2") {
    True -> response(200, fixture("gmail-history-page-2.json"))
    False ->
      case string.contains(url, "/history?") {
        True -> response(200, fixture("gmail-history-page-1.json"))
        False -> fixture_metadata_transport(url)
      }
  }
}

fn fixture_metadata_transport(url: String) -> google_http_client.Outcome {
  case string.contains(url, "/messages/message-1?") {
    True -> response(200, fixture("gmail-message-1.json"))
    False ->
      case string.contains(url, "/messages/message-2?") {
        True -> response(200, fixture("gmail-message-2.json"))
        False ->
          case string.contains(url, "/messages/message-missing?") {
            True -> response(404, "{}")
            False -> google_http_client.BeforeDispatch("unexpected_request")
          }
      }
  }
}

fn response(status: Int, body: String) -> google_http_client.Outcome {
  google_http_client.Response(google_http_client.HttpResponse(
    status:,
    body:,
    retry_after_ms: 0,
  ))
}

fn fixture(name: String) -> String {
  simplifile.read("test/fixtures/google/" <> name) |> should.be_ok
}

fn setup() -> System {
  setup_with_duration(600_000)
}

fn setup_with_duration(duration_ms: Int) -> System {
  let root = "/tmp/aura-gmail-runtime-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([root])
  let _ = simplifile.create_directory_all(root)
  let paths = xdg.resolve_with_home(root)
  let identity_key = string.repeat("i", 32)
  let fingerprint =
    oauth.account_fingerprint(identity_key, "person@example.test")
  let now_ms = time.now_ms()
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
      "gmail-runtime:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(enabled) =
    connector_activation.enable_set(
      db_subject,
      authorization.authorization_id,
      "gmail-runtime:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(activation) =
    list.find(enabled, fn(value) { value.connector_id == "gmail" })
  let token = token(preparation, authorization, identity_key, now_ms)
  oauth.save_scoped_token(paths, token) |> should.be_ok
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
    authorization_id: "authorization:preparation-gmail-runtime-test",
    canary_id: "canary:gmail-runtime-test",
    oauth_client_ref: "oauth-client:gmail-runtime-test",
    oauth_client_hash: string.repeat("a", 64),
    connectors: [
      operating_contracts.PreparationConnectorV1(
        connector_id: "gmail",
        configuration_ref: "configuration:gmail-runtime-test",
        oauth_scope: gmail_scope,
        identity_endpoint_id: "gmail.users.getProfile",
      ),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: now_ms + 700_000,
    authorized_by_ref: "operator:gmail-runtime-test",
  )
}

fn authorization(
  now_ms: Int,
  account_fingerprint: String,
  duration_ms: Int,
) -> operating_contracts.CanaryAuthorizationV1 {
  operating_contracts.CanaryAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:gmail-runtime-test",
    preparation_authorization_id: "authorization:preparation-gmail-runtime-test",
    canary_id: "canary:gmail-runtime-test",
    domain_id: "domain:personal-life",
    concern_id: "concern:domain:personal-life:awareness",
    policy_refs: ["policy:personal-life-canary"],
    connectors: [
      operating_contracts.AuthorizedConnectorV1(
        connector_id: "gmail",
        activation_id: "activation:gmail-runtime-test",
        configuration_ref: "configuration:gmail-runtime-test",
        configuration_hash: hash("configuration:gmail-runtime-test"),
        account_fingerprint:,
        oauth_proof_ref: "proof:gmail-oauth",
        identity_proof_ref: "proof:gmail-identity",
        oauth_scope: gmail_scope,
        capability: "mail.read",
        retention_policy_ref: "retention:gmail-compact",
        poll_interval_ms: 60_000,
        max_pages_per_poll: 2,
        max_items_per_poll: 4,
        max_response_bytes: 100_000,
      ),
    ],
    activation_grants: ["connector.disable", "connector.enable"],
    monitor_id: "monitor:gmail-runtime-test",
    monitor_capability_hash: string.repeat("b", 64),
    monitor_runtime_ref: "runtime:gmail-runtime-test",
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
    authorized_by_ref: "operator:gmail-runtime-test",
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
    session_ref: "session:gmail-runtime-test",
    oauth_effect_ref: "effect:gmail-runtime-test",
    preparation_authorization_id: preparation.authorization_id,
    connector_id: "gmail",
    configuration_ref: connector.configuration_ref,
    configuration_hash: connector.configuration_hash,
    oauth_client_ref: "oauth-client:fixture:gmail",
    oauth_client_hash: hash("oauth-client:gmail"),
    client_set_ref: preparation.oauth_client_ref,
    client_set_hash: preparation.oauth_client_hash,
    oauth_proof_ref: connector.oauth_proof_ref,
    oauth_result_hash: hash("oauth-result:gmail"),
    identity_proof_ref: connector.identity_proof_ref,
    identity_result_hash: hash("identity-result:gmail"),
    token_effect_ref: "effect:token:gmail-runtime-test",
    token_effect_result_hash: hash("token-effect:gmail-runtime-test"),
    account_fingerprint: connector.account_fingerprint,
    granted_scope: gmail_scope,
    issued_at_ms: now_ms,
    expires_at_ms: now_ms + 3_600_000,
    access_token: "synthetic-access-token",
    refresh_token: "synthetic-refresh-token",
    identity_hmac_key: identity_key,
  )
}

fn configuration() -> config.ConnectorConfiguration {
  config.ConnectorConfiguration(
    configuration_ref: "configuration:gmail-runtime-test",
    connector_id: "gmail",
    oauth_client_ref: "oauth-client:fixture:gmail",
    credential_ref: "credential:gmail-runtime-test",
    resource_ref: "resource:gmail-runtime-test",
    oauth_scope: gmail_scope,
    configuration_hash: hash("configuration:gmail-runtime-test"),
  )
}

fn hash(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}
