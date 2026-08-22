import aura/oauth
import aura/test_helpers
import aura/xdg
import gleam/bit_array
import gleam/crypto
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn v2_tokens_require_exact_connector_scope_and_complete_proofs_test() {
  let gmail = token("gmail")
  oauth.validate_scoped_token(gmail) |> should.equal(Ok(gmail))
  oauth.validate_scoped_token(
    oauth.ScopedTokenSetV2(..gmail, granted_scope: "https://mail.google.com/"),
  )
  |> should.equal(Error("gmail_rest_scope_mismatch"))
  oauth.validate_scoped_token(
    oauth.ScopedTokenSetV2(..gmail, identity_proof_ref: ""),
  )
  |> should.equal(Error("scoped_token_v2_invalid"))

  let calendar = token("calendar")
  oauth.validate_scoped_token(calendar) |> should.equal(Ok(calendar))
  oauth.validate_scoped_token(
    oauth.ScopedTokenSetV2(
      ..calendar,
      granted_scope: "https://www.googleapis.com/auth/calendar.events.readonly",
    ),
  )
  |> should.equal(Error("calendar_rest_scope_mismatch"))
}

pub fn v2_codecs_reject_v1_and_cross_connector_records_test() {
  let gmail = token("gmail")
  oauth.scoped_token_to_json(gmail)
  |> oauth.scoped_token_from_json
  |> should.equal(Ok(gmail))
  oauth.scoped_token_from_json(
    "{\"schema_version\":1,\"access_token\":\"old\",\"refresh_token\":\"old\"}",
  )
  |> should.equal(Error("scoped_token_v2_invalid"))
  oauth.scoped_token_to_json(token("calendar"))
  |> oauth.scoped_token_from_json
  |> should.equal(Error("scoped_token_connector_mismatch"))
}

pub fn pending_token_is_separate_from_the_final_loader_test() {
  let root = "/tmp/aura-pending-token-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let pending = pending_token("gmail")
  oauth.save_pending_token(paths, pending) |> should.be_ok
  oauth.load_pending_token(paths, pending.configuration_ref)
  |> should.equal(Ok(pending))
  oauth.load_scoped_token(paths, pending.configuration_ref) |> should.be_error
  oauth.remove_pending_token(paths, pending) |> should.be_ok
  oauth.load_pending_token(paths, pending.configuration_ref) |> should.be_error
  let _ = simplifile.delete_all([root])
}

pub fn final_token_files_are_bound_idempotent_and_ignore_legacy_paths_test() {
  let root = "/tmp/aura-v2-token-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let gmail = token("gmail")
  let legacy_path = paths.config <> "/tokens/gmail.json"
  let assert Ok(_) = simplifile.create_directory_all(paths.config <> "/tokens")
  let assert Ok(_) = simplifile.write(legacy_path, "{\"access_token\":\"old\"}")
  oauth.save_scoped_token(paths, gmail) |> should.be_ok
  oauth.save_scoped_token(paths, gmail) |> should.be_ok
  oauth.load_scoped_token(paths, gmail.configuration_ref)
  |> should.equal(Ok(gmail))
  oauth.save_scoped_token(
    paths,
    oauth.ScopedTokenSetV2(..gmail, access_token: "changed"),
  )
  |> should.equal(Error("secret_already_exists"))
  let calendar = token("calendar")
  oauth.save_calendar_token(paths, calendar) |> should.be_ok
  oauth.load_calendar_token(paths, calendar.configuration_ref)
  |> should.equal(Ok(calendar))
  let _ = simplifile.delete_all([root])
}

pub fn refresh_replaces_only_the_exact_bound_token_test() {
  let root = "/tmp/aura-v2-refresh-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let current = token("gmail")
  let refreshed =
    oauth.ScopedTokenSetV2(
      ..current,
      issued_at_ms: 2,
      expires_at_ms: 7_200_002,
      access_token: "refreshed-access",
      refresh_token: "refreshed-refresh",
    )
  oauth.save_scoped_token(paths, current) |> should.be_ok
  oauth.replace_scoped_token(paths, current, refreshed) |> should.be_ok
  oauth.load_scoped_token(paths, current.configuration_ref)
  |> should.equal(Ok(refreshed))
  oauth.replace_scoped_token(
    paths,
    current,
    oauth.ScopedTokenSetV2(..refreshed, access_token: "stale-replace"),
  )
  |> should.equal(Error("secret_hash_mismatch"))
  oauth.replace_scoped_token(
    paths,
    refreshed,
    oauth.ScopedTokenSetV2(..refreshed, account_fingerprint: hash("other")),
  )
  |> should.equal(Error("scoped_token_refresh_binding_mismatch"))
  let _ = simplifile.delete_all([root])
}

pub fn account_fingerprint_is_keyed_and_does_not_retain_identity_test() {
  let first = oauth.account_fingerprint("key-one", "person@example.test")
  let second = oauth.account_fingerprint("key-two", "person@example.test")
  first |> should.not_equal(second)
  string.length(first) |> should.equal(64)
  first |> should.equal(string.lowercase(first))
  string.contains(first, "person") |> should.be_false
  string.contains(first, "example.test") |> should.be_false
}

pub fn identity_keys_are_random_and_sufficiently_large_test() {
  let first = oauth.new_identity_hmac_key() |> should.be_ok
  let second = oauth.new_identity_hmac_key() |> should.be_ok
  first |> should.not_equal(second)
  { string.length(first) >= 43 } |> should.be_true
}

fn token(connector_id: String) -> oauth.ScopedTokenSetV2 {
  let scope = scope(connector_id)
  oauth.ScopedTokenSetV2(
    session_ref: "oauth-session:" <> connector_id,
    oauth_effect_ref: "effect:oauth:" <> connector_id,
    preparation_authorization_id: "authorization:preparation-token-test",
    connector_id:,
    configuration_ref: "configuration:" <> connector_id <> "-token-test",
    configuration_hash: hash("configuration:" <> connector_id),
    oauth_client_ref: "oauth-client:" <> connector_id <> ":fixture",
    oauth_client_hash: hash("client:" <> connector_id),
    client_set_ref: "oauth-client-set:fixture",
    client_set_hash: hash("client-set"),
    oauth_proof_ref: "proof:oauth:" <> connector_id,
    oauth_result_hash: hash("oauth-result:" <> connector_id),
    identity_proof_ref: "proof:identity:" <> connector_id,
    identity_result_hash: hash("identity-result:" <> connector_id),
    token_effect_ref: "proof:oauth:" <> connector_id,
    token_effect_result_hash: hash("oauth-result:" <> connector_id),
    account_fingerprint: oauth.account_fingerprint(
      identity_key(),
      connector_id <> "@example.test",
    ),
    granted_scope: scope,
    issued_at_ms: 1,
    expires_at_ms: 3_600_001,
    access_token: "access-token",
    refresh_token: "refresh-token",
    identity_hmac_key: identity_key(),
  )
}

fn pending_token(connector_id: String) -> oauth.PendingTokenV1 {
  oauth.PendingTokenV1(
    session_ref: "oauth-session:" <> connector_id,
    effect_id: "effect:oauth:" <> connector_id,
    preparation_authorization_id: "authorization:preparation-token-test",
    connector_id:,
    configuration_ref: "configuration:" <> connector_id <> "-token-test",
    configuration_hash: hash("configuration:" <> connector_id),
    oauth_client_ref: "oauth-client:" <> connector_id <> ":fixture",
    oauth_client_hash: hash("client:" <> connector_id),
    client_set_ref: "oauth-client-set:fixture",
    client_set_hash: hash("client-set"),
    oauth_proof_ref: "proof:oauth:" <> connector_id,
    oauth_result_hash: hash("oauth-result:" <> connector_id),
    token_effect_ref: "effect:oauth:" <> connector_id,
    token_effect_result_hash: hash("oauth-result:" <> connector_id),
    granted_scope: scope(connector_id),
    issued_at_ms: 1,
    expires_at_ms: 3_600_001,
    access_token: "access-token",
    refresh_token: "refresh-token",
    identity_hmac_key: identity_key(),
  )
}

fn scope(connector_id: String) -> String {
  case connector_id {
    "gmail" -> "https://www.googleapis.com/auth/gmail.readonly"
    _ -> "https://www.googleapis.com/auth/calendar.readonly"
  }
}

fn identity_key() -> String {
  string.repeat("k", 32)
}

fn hash(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}
