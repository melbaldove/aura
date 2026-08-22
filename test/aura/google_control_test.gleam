import aura/config
import aura/connector_activation
import aura/connector_runtime
import aura/ctl
import aura/db
import aura/google_execution_fixture
import aura/google_oauth_client
import aura/google_oauth_runtime
import aura/operating_contracts
import aura/secret
import aura/test_helpers
import aura/time
import aura/xdg
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlight

const gmail_scope = "https://www.googleapis.com/auth/gmail.readonly"

pub fn main() {
  gleeunit.main()
}

pub fn oauth_start_uses_durable_preparation_and_returns_no_secret_test() {
  let #(root, paths, subject, configuration, preparation, gmail_ref) = setup()
  let name = process.new_name("google_control_oauth")
  let assert Ok(started) =
    google_oauth_runtime.start_named(name, subject, paths, [configuration])
  let output =
    ctl.process_google_oauth_start(
      paths,
      subject,
      started.data,
      [configuration],
      "gmail",
      preparation.authorization_id,
      configuration.configuration_ref,
      gmail_ref,
    )
  string.contains(output, "\"ok\":true") |> should.be_true
  string.contains(output, "oauth-session:") |> should.be_true
  string.contains(output, "authorization_url") |> should.be_true
  string.contains(output, "gmail.readonly") |> should.be_true
  string.contains(output, "client_secret") |> should.be_false
  string.contains(output, "code_verifier") |> should.be_false
  string.contains(output, "synthetic-control-secret") |> should.be_false
  let _ = simplifile.delete_all([root])
}

pub fn oauth_start_rejects_substitution_and_status_is_compact_test() {
  let #(root, paths, subject, configuration, preparation, gmail_ref) = setup()
  let name = process.new_name("google_control_binding")
  let assert Ok(started) =
    google_oauth_runtime.start_named(name, subject, paths, [configuration])
  ctl.process_google_oauth_start(
    paths,
    subject,
    started.data,
    [configuration],
    "imap",
    preparation.authorization_id,
    configuration.configuration_ref,
    gmail_ref,
  )
  |> should.equal("{\"ok\":false,\"error\":\"google_oauth_connector_invalid\"}")
  ctl.process_google_oauth_start(
    paths,
    subject,
    started.data,
    [configuration],
    "gmail",
    preparation.authorization_id,
    configuration.configuration_ref,
    "oauth-client:gmail:sha256:wrong",
  )
  |> should.equal(
    "{\"ok\":false,\"error\":\"google_oauth_client_set_binding_mismatch\"}",
  )
  let output =
    ctl.process_google_oauth_start(
      paths,
      subject,
      started.data,
      [configuration],
      "gmail",
      preparation.authorization_id,
      configuration.configuration_ref,
      gmail_ref,
    )
  let assert [_, rest] = string.split(output, "\"session_ref\":\"")
  let assert [session_ref, ..] = string.split(rest, "\"")
  let status = ctl.process_google_oauth_status(subject, session_ref)
  status
  |> should.equal("{\"ok\":true,\"phase\":\"waiting\",\"error_class\":null}")
  string.contains(status, "state") |> should.be_false
  string.contains(status, "code") |> should.be_false
  let _ = simplifile.delete_all([root])
}

pub fn connector_read_control_fails_before_runtime_for_unknown_authority_test() {
  let assert Ok(subject) = db.start(":memory:")
  ctl.process_connector_read_once(
    subject,
    process.new_subject(),
    "authorization:missing",
    "gmail",
  )
  |> should.equal("{\"ok\":false,\"error\":\"canary_authorization_not_found\"}")
  ctl.process_connector_read_once(
    subject,
    process.new_subject(),
    "authorization:missing",
    "imap",
  )
  |> should.equal("{\"ok\":false,\"error\":\"connector_runner_unavailable\"}")
}

pub fn connector_read_control_calls_shared_runtime_with_derived_activation_test() {
  let #(subject, authorization, activation_id, configuration) =
    authorized_read_setup()
  let calls = process.new_subject()
  let runner = fn(
    connector_id,
    authorization_id,
    received_activation,
    attempt_id,
    _,
  ) {
    process.send(calls, #(authorization_id, received_activation))
    Ok(connector_runtime.RunReceipt(connector_id, attempt_id, 2))
  }
  let name = process.new_name("google_control_connector_runtime")
  let started =
    connector_runtime.start_named_with_runner_for_test(
      name,
      subject,
      [configuration],
      runner,
    )
    |> should.be_ok
  process.unlink(started.pid)
  process.receive(calls, 1000) |> should.be_ok
  process.sleep(20)
  ctl.process_connector_read_once(
    subject,
    started.data,
    authorization.authorization_id,
    "gmail",
  )
  |> fn(output) {
    string.contains(output, "\"ok\":true") |> should.be_true
    string.contains(output, "\"connector_id\":\"gmail\"")
    |> should.be_true
    string.contains(output, "\"evidence_count\":2") |> should.be_true
  }
  process.receive(calls, 1000)
  |> should.equal(Ok(#(authorization.authorization_id, activation_id)))
  process.kill(started.pid)
}

pub fn connector_read_control_rejects_preserved_authority_without_v17_proofs_test() {
  let path =
    "/tmp/aura-google-control-preserved-"
    <> test_helpers.random_suffix()
    <> ".db"
  let assert Ok(subject) = db.start(path)
  let #(preparation, authorization) = read_authorizations()
  db.create_canary_preparation_authorization(subject, preparation)
  |> should.be_ok
  let assert Ok(conn) = sqlight.open(path)
  let canonical = operating_contracts.encode_canary_authorization(authorization)
  sqlight.query(
    "INSERT INTO canary_authorizations (authorization_id, preparation_authorization_id, schema_version, canary_id, canonical_json, payload_hash, monitor_capability_hash, starts_at_ms, ends_at_ms, created_at_ms) VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text(authorization.authorization_id),
      sqlight.text(preparation.authorization_id),
      sqlight.text(authorization.canary_id),
      sqlight.text(canonical),
      sqlight.text(secret.sha256(canonical)),
      sqlight.text(authorization.monitor_capability_hash),
      sqlight.int(authorization.starts_at_ms),
      sqlight.int(authorization.ends_at_ms),
      sqlight.int(time.now_ms()),
    ],
    expecting: decode.success(Nil),
  )
  |> should.be_ok
  let assert [connector] = authorization.connectors
  sqlight.query(
    "INSERT INTO connector_activations (activation_id, authorization_id, connector_id, domain_id, concern_id, configuration_ref, oauth_scope, state, version, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, 'enabled', 1, ?)",
    on: conn,
    with: [
      sqlight.text(connector.activation_id),
      sqlight.text(authorization.authorization_id),
      sqlight.text(connector.connector_id),
      sqlight.text(authorization.domain_id),
      sqlight.text(authorization.concern_id),
      sqlight.text(connector.configuration_ref),
      sqlight.text(connector.oauth_scope),
      sqlight.int(time.now_ms()),
    ],
    expecting: decode.success(Nil),
  )
  |> should.be_ok
  let _ = sqlight.close(conn)
  let called = process.new_subject()
  let runtime = process.new_subject()
  process.spawn(fn() {
    let _ = process.receive_forever(runtime)
    process.send(called, Nil)
  })
  ctl.process_connector_read_once(
    subject,
    runtime,
    authorization.authorization_id,
    "gmail",
  )
  |> should.equal(
    "{\"ok\":false,\"error\":\"canary_connector_proof_mismatch\"}",
  )
  process.receive(called, 50) |> should.equal(Error(Nil))
  let _ = simplifile.delete(path)
}

fn setup() {
  let root = "/tmp/aura-google-control-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let assert Ok(subject) = db.start(":memory:")
  let gmail = install(paths, root, "gmail", "gmail-control")
  let calendar = install(paths, root, "calendar", "calendar-control")
  let set =
    google_oauth_client.create_client_set(
      paths,
      gmail.client_ref,
      calendar.client_ref,
    )
    |> should.be_ok
  db.register_google_oauth_client_set(
    subject,
    db.GoogleOAuthClientSet(
      client_set_ref: set.client_set_ref,
      client_set_hash: set.client_set_hash,
      gmail_client_ref: set.gmail_client_ref,
      gmail_client_hash: set.gmail_client_hash,
      calendar_client_ref: set.calendar_client_ref,
      calendar_client_hash: set.calendar_client_hash,
    ),
  )
  |> should.be_ok
  let configuration_ref = "configuration:google-control-gmail"
  let configuration =
    config.ConnectorConfiguration(
      configuration_ref:,
      connector_id: "gmail",
      oauth_client_ref: gmail.client_ref,
      credential_ref: "credential:google-control-gmail",
      resource_ref: "resource:google-control-mailbox",
      oauth_scope: gmail_scope,
      configuration_hash: config.connector_configuration_hash(
        configuration_ref,
        "gmail",
        gmail.client_ref,
        "credential:google-control-gmail",
        "resource:google-control-mailbox",
        gmail_scope,
      ),
    )
  let preparation =
    operating_contracts.CanaryPreparationAuthorizationV1(
      schema_version: 1,
      authorization_id: "preparation:google-control",
      canary_id: "canary:google-control",
      oauth_client_ref: set.client_set_ref,
      oauth_client_hash: set.client_set_hash,
      connectors: [
        operating_contracts.PreparationConnectorV1(
          connector_id: "gmail",
          configuration_ref:,
          oauth_scope: gmail_scope,
          identity_endpoint_id: "gmail-profile-v1",
        ),
      ],
      grants: ["connector.identity.read", "oauth.authorize"],
      expires_at_ms: time.now_ms() + 300_000,
      authorized_by_ref: "operator:google-control",
    )
  db.create_canary_preparation_authorization(subject, preparation)
  |> should.be_ok
  #(root, paths, subject, configuration, preparation, gmail.client_ref)
}

fn install(paths, root: String, connector: String, name: String) {
  let source = root <> "/" <> connector <> ".json"
  let raw =
    "{\"installed\":{\"client_id\":\""
    <> name
    <> ".apps.googleusercontent.com\",\"client_secret\":\"synthetic-control-secret\"}}"
  secret.atomic_write(source, raw) |> should.be_ok
  let digest = google_oauth_client.sha256_file(source) |> should.be_ok
  google_oauth_client.install(paths, connector, source, digest) |> should.be_ok
}

fn authorized_read_setup() {
  let assert Ok(subject) = db.start(":memory:")
  let #(preparation, authorization) = read_authorizations()
  db.create_canary_preparation_authorization(subject, preparation)
  |> should.be_ok
  google_execution_fixture.seed_authorization_proofs(
    subject,
    preparation,
    authorization,
  )
  |> should.be_ok
  db.create_canary_authorization(subject, authorization) |> should.be_ok
  connector_activation.prepare_disabled(
    subject,
    authorization.authorization_id,
    "google-control:prepare",
    authorization.authorized_by_ref,
  )
  |> should.be_ok
  let enabled =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "google-control:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
    |> should.be_ok
  let activation =
    list.find(enabled, fn(value) { value.connector_id == "gmail" })
    |> should.be_ok
  let connector = authorization.connectors |> list.first |> should.be_ok
  let configuration =
    config.ConnectorConfiguration(
      configuration_ref: connector.configuration_ref,
      connector_id: connector.connector_id,
      oauth_client_ref: "oauth-client:fixture:gmail",
      credential_ref: "credential:google-control-read",
      resource_ref: "resource:google-control-read",
      oauth_scope: connector.oauth_scope,
      configuration_hash: connector.configuration_hash,
    )
  #(subject, authorization, activation.activation_id, configuration)
}

fn read_authorizations() {
  let now_ms = time.now_ms()
  let preparation =
    operating_contracts.CanaryPreparationAuthorizationV1(
      schema_version: 1,
      authorization_id: "preparation:google-control-read",
      canary_id: "canary:google-control-read",
      oauth_client_ref: "oauth-client-set:google-control-read",
      oauth_client_hash: secret.sha256("client-set"),
      connectors: [
        operating_contracts.PreparationConnectorV1(
          connector_id: "gmail",
          configuration_ref: "configuration:google-control-read",
          oauth_scope: gmail_scope,
          identity_endpoint_id: "gmail.users.getProfile",
        ),
      ],
      grants: ["connector.identity.read", "oauth.authorize"],
      expires_at_ms: now_ms + 600_000,
      authorized_by_ref: "operator:google-control-read",
    )
  let authorization =
    operating_contracts.CanaryAuthorizationV1(
      schema_version: 1,
      authorization_id: "authorization:google-control-read",
      preparation_authorization_id: preparation.authorization_id,
      canary_id: preparation.canary_id,
      domain_id: "domain:personal-life",
      concern_id: "concern:domain:personal-life:awareness",
      policy_refs: ["policy:personal-life-canary"],
      connectors: [
        operating_contracts.AuthorizedConnectorV1(
          connector_id: "gmail",
          activation_id: "activation:google-control-read",
          configuration_ref: "configuration:google-control-read",
          configuration_hash: secret.sha256("configuration"),
          account_fingerprint: secret.sha256("account"),
          oauth_proof_ref: "proof:google-control-oauth",
          identity_proof_ref: "proof:google-control-identity",
          oauth_scope: gmail_scope,
          capability: "mail.read",
          retention_policy_ref: "retention:compact",
          poll_interval_ms: 60_000,
          max_pages_per_poll: 2,
          max_items_per_poll: 4,
          max_response_bytes: 100_000,
        ),
      ],
      activation_grants: ["connector.disable", "connector.enable"],
      monitor_id: "monitor:google-control-read",
      monitor_capability_hash: secret.sha256("monitor-capability"),
      monitor_runtime_ref: "runtime:google-control-read",
      monitor_prompt_hash: secret.sha256("monitor-prompt"),
      monitor_interval_ms: 60_000,
      monitor_grants: ["attention.claim", "attention.read"],
      attention_owner: "codex",
      attention_target: "codex_monitor",
      discord_delivery_allowed: False,
      starts_at_ms: now_ms - 1000,
      ends_at_ms: now_ms + 300_000,
      metric_ids: ["metric:evidence-captured"],
      metric_review_owner_ref: "operator:metrics",
      authorized_by_ref: "operator:google-control-read",
      rollback_owner_ref: "operator:rollback",
    )
  #(preparation, authorization)
}
