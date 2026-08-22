import aura/db
import aura/google_execution_fixture
import aura/operating_contracts
import aura/test_helpers
import aura/time
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlight

pub fn main() {
  gleeunit.main()
}

pub fn oauth_session_claim_and_terminal_replay_are_one_shot_test() {
  let assert Ok(subject) = db.start(":memory:")
  let preparation = preparation_authorization()
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, preparation)
  let assert Ok(_) =
    google_execution_fixture.register_client_set(subject, preparation)
  let session = oauth_session(preparation.authorization_id)

  db.create_google_oauth_session(subject, session) |> should.be_ok
  db.claim_google_oauth_session(subject, session.session_ref) |> should.be_ok
  db.claim_google_oauth_session(subject, session.session_ref)
  |> should.equal(Error("oauth_session_not_waiting"))
  db.finish_google_oauth_session(subject, session.session_ref, "succeeded", "")
  |> should.be_ok
  db.finish_google_oauth_session(subject, session.session_ref, "succeeded", "")
  |> should.be_ok
}

pub fn oauth_session_claim_rejects_an_expired_callback_deadline_test() {
  let assert Ok(subject) = db.start(":memory:")
  let preparation = preparation_authorization()
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, preparation)
  let assert Ok(_) =
    google_execution_fixture.register_client_set(subject, preparation)
  let session = oauth_session(preparation.authorization_id)
  let assert Ok(_) = db.create_google_oauth_session(subject, session)
  db.claim_google_oauth_session_before(subject, session.session_ref, 1)
  |> should.equal(Error("oauth_callback_deadline_expired"))
}

pub fn oauth_session_transaction_rejects_enabled_activation_test() {
  let path =
    "/tmp/aura-google-enabled-oauth-" <> test_helpers.random_suffix() <> ".db"
  let assert Ok(subject) = db.start(path)
  let preparation = preparation_authorization()
  db.create_canary_preparation_authorization(subject, preparation)
  |> should.be_ok
  google_execution_fixture.register_client_set(subject, preparation)
  |> should.be_ok
  let assert Ok(conn) = sqlight.open(path)
  let now_ms = time.now_ms()
  sqlight.query(
    "INSERT INTO canary_authorizations (authorization_id, preparation_authorization_id, schema_version, canary_id, canonical_json, payload_hash, monitor_capability_hash, starts_at_ms, ends_at_ms, created_at_ms) VALUES (?, ?, 1, ?, '{}', ?, ?, ?, ?, ?)",
    on: conn,
    with: [
      sqlight.text("authorization:enabled-google-db-test"),
      sqlight.text(preparation.authorization_id),
      sqlight.text("canary:enabled-google-db-test"),
      sqlight.text(hash("authorization")),
      sqlight.text(hash("capability")),
      sqlight.int(now_ms - 1000),
      sqlight.int(now_ms + 300_000),
      sqlight.int(now_ms),
    ],
    expecting: decode.success(Nil),
  )
  |> should.be_ok
  sqlight.query(
    "INSERT INTO connector_activations (activation_id, authorization_id, connector_id, domain_id, concern_id, configuration_ref, oauth_scope, state, version, updated_at_ms) VALUES (?, ?, 'gmail', 'domain:personal-life', 'concern:domain:personal-life:awareness', 'configuration:gmail-test', 'https://www.googleapis.com/auth/gmail.readonly', 'enabled', 1, ?)",
    on: conn,
    with: [
      sqlight.text("activation:enabled-google-db-test"),
      sqlight.text("authorization:enabled-google-db-test"),
      sqlight.int(now_ms),
    ],
    expecting: decode.success(Nil),
  )
  |> should.be_ok
  let _ = sqlight.close(conn)
  db.create_google_oauth_session(
    subject,
    oauth_session(preparation.authorization_id),
  )
  |> should.equal(Error("connector_activation_already_enabled"))
  let _ = simplifile.delete(path)
}

pub fn external_effect_is_idempotent_and_changed_request_conflicts_test() {
  let assert Ok(subject) = db.start(":memory:")
  let preparation = preparation_authorization()
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, preparation)
  let assert Ok(_) =
    google_execution_fixture.register_client_set(subject, preparation)
  let effect = oauth_effect(preparation.authorization_id)

  db.begin_google_external_effect(subject, effect) |> should.equal(Ok(effect))
  db.begin_google_external_effect(subject, effect) |> should.equal(Ok(effect))
  db.begin_google_external_effect(
    subject,
    db.GoogleExternalEffect(..effect, request_hash: hash("changed")),
  )
  |> should.equal(Error("idempotency_conflict"))
  let assert Ok(done) =
    db.finish_google_external_effect(
      subject,
      effect.effect_id,
      "succeeded",
      "proof:oauth:gmail-test",
      "",
      hash("result"),
      "",
    )
  done.phase |> should.equal("succeeded")
  db.finish_google_external_effect(
    subject,
    effect.effect_id,
    "succeeded",
    "proof:oauth:gmail-test",
    "",
    hash("result"),
    "",
  )
  |> should.equal(Ok(done))
}

pub fn connector_read_lease_is_capped_test() {
  let assert Ok(subject) = db.start(":memory:")
  db.reserve_connector_read(
    subject,
    "attempt:too-long",
    "activation:missing",
    "authorization:missing",
    "worker:test",
    300_001,
  )
  |> should.equal(Error("invalid_connector_read_lease"))
}

pub fn oauth_session_rejects_expiry_and_wrong_preparation_binding_test() {
  let assert Ok(subject) = db.start(":memory:")
  let preparation = preparation_authorization()
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, preparation)
  let assert Ok(_) =
    google_execution_fixture.register_client_set(subject, preparation)
  let session = oauth_session(preparation.authorization_id)
  db.create_google_oauth_session(
    subject,
    db.GoogleOAuthSession(..session, expires_at_ms: 1),
  )
  |> should.equal(Error("invalid_google_oauth_session"))
  db.create_google_oauth_session(
    subject,
    db.GoogleOAuthSession(
      ..session,
      session_ref: "oauth-session:wrong-config",
      configuration_ref: "configuration:calendar-test",
    ),
  )
  |> should.equal(Error("preparation_connector_mismatch"))
}

pub fn oauth_session_requires_the_exact_preparation_connector_scope_test() {
  let assert Ok(subject) = db.start(":memory:")
  let preparation = preparation_authorization()
  let wrong_scope =
    operating_contracts.CanaryPreparationAuthorizationV1(
      ..preparation,
      authorization_id: "authorization:preparation-wrong-scope",
      connectors: [
        operating_contracts.PreparationConnectorV1(
          connector_id: "gmail",
          configuration_ref: "configuration:gmail-test",
          oauth_scope: "https://www.googleapis.com/auth/calendar.readonly",
          identity_endpoint_id: "gmail.users.getProfile",
        ),
      ],
    )
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, wrong_scope)
  let assert Ok(_) =
    google_execution_fixture.register_client_set(subject, wrong_scope)
  db.create_google_oauth_session(
    subject,
    oauth_session(wrong_scope.authorization_id),
  )
  |> should.equal(Error("preparation_connector_mismatch"))
}

pub fn external_effect_retry_requires_terminal_unknown_and_next_attempt_test() {
  let assert Ok(subject) = db.start(":memory:")
  let preparation = preparation_authorization()
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, preparation)
  let assert Ok(_) =
    google_execution_fixture.register_client_set(subject, preparation)
  let first =
    db.GoogleExternalEffect(
      ..oauth_effect(preparation.authorization_id),
      effect_id: "effect:identity:1",
      effect_kind: "identity_read",
      logical_effect_key: "identity:gmail-test",
    )
  let assert Ok(_) = db.begin_google_external_effect(subject, first)
  let assert Ok(_) =
    db.finish_google_external_effect(
      subject,
      first.effect_id,
      "effect_unknown",
      "",
      "",
      "",
      "transport_after_dispatch",
    )
  let second =
    db.GoogleExternalEffect(
      ..first,
      effect_id: "effect:identity:2",
      attempt_number: 2,
      request_hash: hash("identity-retry"),
    )
  let assert Ok(_) = db.begin_google_external_effect(subject, second)
  db.finish_google_external_effect(
    subject,
    second.effect_id,
    "succeeded",
    "proof:identity:gmail-test",
    "",
    hash("identity-result"),
    "",
  )
  |> should.equal(Error("identity_account_fingerprint_required"))
  db.finish_google_external_effect(
    subject,
    second.effect_id,
    "succeeded",
    "proof:identity:gmail-test",
    hash("account"),
    hash("identity-result"),
    "",
  )
  |> should.be_ok
  db.begin_google_external_effect(
    subject,
    db.GoogleExternalEffect(
      ..second,
      effect_id: "effect:identity:3",
      attempt_number: 3,
      request_hash: hash("identity-third"),
    ),
  )
  |> should.equal(Error("google_effect_attempt_sequence_conflict"))
}

pub fn authorization_code_exchange_has_one_attempt_test() {
  let assert Ok(subject) = db.start(":memory:")
  let preparation = preparation_authorization()
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, preparation)
  let assert Ok(_) =
    google_execution_fixture.register_client_set(subject, preparation)
  let first = oauth_effect(preparation.authorization_id)
  let assert Ok(_) = db.begin_google_external_effect(subject, first)
  let assert Ok(_) =
    db.finish_google_external_effect(
      subject,
      first.effect_id,
      "effect_unknown",
      "",
      "",
      "",
      "transport_after_dispatch",
    )
  db.begin_google_external_effect(
    subject,
    db.GoogleExternalEffect(
      ..first,
      effect_id: "effect:oauth:gmail-retry",
      attempt_number: 2,
      request_hash: hash("retry"),
    ),
  )
  |> should.equal(Error("oauth_exchange_attempt_rejected"))
}

pub fn public_google_db_boundary_rejects_unbounded_or_transcript_like_fields_test() {
  let assert Ok(subject) = db.start(":memory:")
  let preparation = preparation_authorization()
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, preparation)
  let assert Ok(_) =
    google_execution_fixture.register_client_set(subject, preparation)
  let session = oauth_session(preparation.authorization_id)
  db.create_google_oauth_session(
    subject,
    db.GoogleOAuthSession(
      ..session,
      session_ref: "oauth session includes prose",
    ),
  )
  |> should.equal(Error("invalid_google_oauth_session"))
  db.create_google_oauth_session(
    subject,
    db.GoogleOAuthSession(
      ..session,
      redirect_uri: "http://127.0.0.1:49152/callback?code=secret",
    ),
  )
  |> should.equal(Error("invalid_google_oauth_session"))
  let assert Ok(_) = db.create_google_oauth_session(subject, session)
  let assert Ok(_) = db.claim_google_oauth_session(subject, session.session_ref)
  db.finish_google_oauth_session(
    subject,
    session.session_ref,
    "failed_before_effect",
    "provider returned a token in this free text",
  )
  |> should.equal(Error("invalid_oauth_session_error_class"))
  db.finish_google_oauth_session(
    subject,
    session.session_ref,
    "failed_before_effect",
    "authorization_denied",
  )
  |> should.be_ok
  let effect = oauth_effect(preparation.authorization_id)
  db.begin_google_external_effect(
    subject,
    db.GoogleExternalEffect(
      ..effect,
      logical_effect_key: "assistant said this is the transcript",
    ),
  )
  |> should.equal(Error("invalid_google_external_effect_intent"))
  let assert Ok(_) = db.begin_google_external_effect(subject, effect)
  db.finish_google_external_effect(
    subject,
    effect.effect_id,
    "effect_unknown",
    "",
    "",
    "",
    "provider returned a token in this free text",
  )
  |> should.equal(Error("invalid_google_external_effect_outcome"))
}

pub fn client_set_binding_and_active_record_bindings_are_immutable_test() {
  let path =
    "/tmp/aura-google-binding-" <> string.inspect(time.now_ms()) <> ".db"
  let _ = simplifile.delete(path)
  let assert Ok(subject) = db.start(path)
  let preparation = preparation_authorization()
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, preparation)
  let assert Ok(_) =
    google_execution_fixture.register_client_set(subject, preparation)
  let effect = oauth_effect(preparation.authorization_id)
  db.begin_google_external_effect(
    subject,
    db.GoogleExternalEffect(
      ..effect,
      effect_id: "effect:wrong-client",
      oauth_client_ref: "oauth-client:forged:gmail",
      oauth_client_hash: hash("forged-client"),
    ),
  )
  |> should.equal(Error("oauth_client_binding_mismatch"))
  let session = oauth_session(preparation.authorization_id)
  let assert Ok(_) = db.create_google_oauth_session(subject, session)
  let assert Ok(_) = db.begin_google_external_effect(subject, effect)
  let assert Ok(conn) = sqlight.open(path)
  sqlight.query(
    "UPDATE connector_oauth_sessions SET configuration_ref = 'configuration:forged' WHERE session_ref = ?",
    on: conn,
    with: [sqlight.text(session.session_ref)],
    expecting: decode.success(Nil),
  )
  |> should.be_error
  sqlight.query(
    "UPDATE connector_external_effects SET request_hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' WHERE effect_id = ?",
    on: conn,
    with: [sqlight.text(effect.effect_id)],
    expecting: decode.success(Nil),
  )
  |> should.be_error
  sqlight.query(
    "DELETE FROM connector_oauth_client_sets WHERE client_set_ref = ?",
    on: conn,
    with: [sqlight.text(preparation.oauth_client_ref)],
    expecting: decode.success(Nil),
  )
  |> should.be_error
  let _ = sqlight.close(conn)
  let _ = simplifile.delete(path)
}

fn oauth_session(preparation_id: String) -> db.GoogleOAuthSession {
  let now_ms = time.now_ms()
  db.GoogleOAuthSession(
    session_ref: "oauth-session:gmail-test",
    connector_id: "gmail",
    preparation_authorization_id: preparation_id,
    configuration_ref: "configuration:gmail-test",
    configuration_hash: hash("configuration"),
    oauth_client_ref: "oauth-client:fixture:gmail",
    oauth_client_hash: hash("oauth-client:gmail"),
    client_set_ref: "oauth-client-set:test",
    client_set_hash: hash("client-set"),
    state_hash: hash("state"),
    pkce_challenge: string.repeat("a", 43),
    redirect_uri: "http://127.0.0.1:49152/callback",
    phase: "waiting",
    expires_at_ms: now_ms + 300_000,
  )
}

fn oauth_effect(preparation_id: String) -> db.GoogleExternalEffect {
  db.GoogleExternalEffect(
    effect_id: "effect:oauth:gmail-test",
    preparation_authorization_id: preparation_id,
    authorization_id: "",
    activation_id: "",
    configuration_ref: "configuration:gmail-test",
    configuration_hash: hash("configuration"),
    connector_id: "gmail",
    oauth_client_ref: "oauth-client:fixture:gmail",
    oauth_client_hash: hash("oauth-client:gmail"),
    client_set_ref: "oauth-client-set:test",
    client_set_hash: hash("client-set"),
    effect_kind: "oauth_exchange",
    logical_effect_key: "oauth-session:gmail-test",
    attempt_number: 1,
    request_hash: hash("request"),
    phase: "intent",
    proof_ref: "",
    oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
    account_fingerprint: "",
    result_hash: "",
    error_class: "",
  )
}

fn preparation_authorization() -> operating_contracts.CanaryPreparationAuthorizationV1 {
  operating_contracts.CanaryPreparationAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:preparation-google-db-test",
    canary_id: "canary:google-db-test",
    oauth_client_ref: "oauth-client-set:test",
    oauth_client_hash: hash("client-set"),
    connectors: [
      operating_contracts.PreparationConnectorV1(
        connector_id: "gmail",
        configuration_ref: "configuration:gmail-test",
        oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
        identity_endpoint_id: "gmail.users.getProfile",
      ),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: 9_999_999_999_999,
    authorized_by_ref: "operator:google-db-test",
  )
}

fn hash(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}
