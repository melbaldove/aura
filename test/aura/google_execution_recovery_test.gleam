import aura/db
import aura/google_execution_fixture
import aura/operating_contracts
import aura/test_helpers
import aura/time
import fakes/file_scan
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

const secret_sentinel = "task9-secret-sentinel-must-not-persist"

pub fn main() {
  gleeunit.main()
}

pub fn claimed_session_recovery_terminalizes_its_unresolved_effect_test() {
  let assert Ok(subject) = db.start(":memory:")
  let preparation = preparation_authorization()
  db.create_canary_preparation_authorization(subject, preparation)
  |> should.be_ok
  google_execution_fixture.register_client_set(subject, preparation)
  |> should.be_ok
  let session = oauth_session(preparation.authorization_id)
  db.create_google_oauth_session(subject, session) |> should.be_ok
  db.claim_google_oauth_session(subject, session.session_ref) |> should.be_ok
  let effect = oauth_effect(session, preparation.authorization_id)
  db.begin_google_external_effect(subject, effect) |> should.be_ok

  db.recover_google_oauth_session(subject, session.session_ref)
  |> should.be_ok
  db.recover_google_oauth_session(subject, session.session_ref)
  |> should.be_ok
  let assert Ok(Some(recovered)) =
    db.get_google_external_effect(subject, effect.effect_id)
  recovered.phase |> should.equal("effect_unknown")
  recovered.error_class |> should.equal("transport_after_dispatch")
  let audits =
    db.list_operational_audit(
      subject,
      "connector_external_effect",
      effect.effect_id,
    )
    |> should.be_ok
  audits
  |> list.filter(fn(record) {
    record.action == "google.external_effect.effect_unknown"
  })
  |> list.length
  |> should.equal(1)
}

pub fn rejected_secret_text_is_absent_from_sqlite_and_wal_test() {
  let path =
    "/tmp/aura-google-leak-proof-" <> test_helpers.random_suffix() <> ".db"
  let _ = simplifile.delete_all([path, path <> "-wal", path <> "-shm"])
  let assert Ok(subject) = db.start(path)
  let preparation = preparation_authorization()
  db.create_canary_preparation_authorization(subject, preparation)
  |> should.be_ok
  google_execution_fixture.register_client_set(subject, preparation)
  |> should.be_ok
  let session =
    db.GoogleOAuthSession(
      ..oauth_session(preparation.authorization_id),
      session_ref: "oauth-session:leak-proof",
    )
  db.create_google_oauth_session(subject, session) |> should.be_ok
  db.claim_google_oauth_session(subject, session.session_ref) |> should.be_ok
  db.finish_google_oauth_session(
    subject,
    session.session_ref,
    "failed_before_effect",
    secret_sentinel,
  )
  |> should.equal(Error("invalid_oauth_session_error_class"))
  process.send(subject, db.Shutdown)
  process.sleep(20)
  [path, path <> "-wal", path <> "-shm"]
  |> list.each(fn(candidate) {
    case simplifile.is_file(candidate) {
      Ok(True) ->
        file_scan.contains(candidate, secret_sentinel) |> should.be_false
      _ -> Nil
    }
  })
  let _ = simplifile.delete_all([path, path <> "-wal", path <> "-shm"])
}

fn oauth_session(preparation_id: String) -> db.GoogleOAuthSession {
  let session_ref = "oauth-session:recovery-proof"
  db.GoogleOAuthSession(
    session_ref:,
    connector_id: "gmail",
    preparation_authorization_id: preparation_id,
    configuration_ref: "configuration:gmail-recovery-proof",
    configuration_hash: hash("configuration:gmail-recovery-proof"),
    oauth_client_ref: "oauth-client:fixture:gmail",
    oauth_client_hash: hash("oauth-client:gmail"),
    client_set_ref: "oauth-client-set:recovery-proof",
    client_set_hash: hash("client-set:recovery-proof"),
    state_hash: hash("state:recovery-proof"),
    pkce_challenge: string.repeat("a", 43),
    redirect_uri: "http://127.0.0.1:49152/callback",
    phase: "waiting",
    expires_at_ms: time.now_ms() + 300_000,
  )
}

fn oauth_effect(
  session: db.GoogleOAuthSession,
  preparation_id: String,
) -> db.GoogleExternalEffect {
  db.GoogleExternalEffect(
    effect_id: "effect:oauth:" <> hash(session.session_ref),
    preparation_authorization_id: preparation_id,
    authorization_id: "",
    activation_id: "",
    configuration_ref: session.configuration_ref,
    configuration_hash: session.configuration_hash,
    connector_id: "gmail",
    oauth_client_ref: session.oauth_client_ref,
    oauth_client_hash: session.oauth_client_hash,
    client_set_ref: session.client_set_ref,
    client_set_hash: session.client_set_hash,
    effect_kind: "oauth_exchange",
    logical_effect_key: "oauth:" <> hash(session.session_ref),
    attempt_number: 1,
    request_hash: hash("request:recovery-proof"),
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
    authorization_id: "authorization:preparation-recovery-proof",
    canary_id: "canary:recovery-proof",
    oauth_client_ref: "oauth-client-set:recovery-proof",
    oauth_client_hash: hash("client-set:recovery-proof"),
    connectors: [
      operating_contracts.PreparationConnectorV1(
        connector_id: "gmail",
        configuration_ref: "configuration:gmail-recovery-proof",
        oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
        identity_endpoint_id: "gmail.users.getProfile",
      ),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: 9_999_999_999_999,
    authorized_by_ref: "operator:recovery-proof",
  )
}

fn hash(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}
