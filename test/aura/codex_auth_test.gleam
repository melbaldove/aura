import aura/codex_auth
import gleeunit/should

pub fn parse_auth_json_reads_nested_codex_cli_tokens_test() {
  let raw = "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"id_token\":\"id-000\",\"access_token\":\"access-123\",\"account_id\":\"acct-456\",\"refresh_token\":\"refresh-789\"}}"

  let auth = codex_auth.parse_auth_json(raw) |> should.be_ok

  auth.access_token |> should.equal("access-123")
  auth.account_id |> should.equal("acct-456")

  let auth_file = codex_auth.parse_auth_json_file(raw) |> should.be_ok
  auth_file.tokens.id_token |> should.equal("id-000")
  auth_file.tokens.refresh_token |> should.equal("refresh-789")
}

pub fn parse_auth_json_allows_missing_account_id_test() {
  let raw = "{\"tokens\":{\"access_token\":\"access-123\"}}"

  let auth = codex_auth.parse_auth_json(raw) |> should.be_ok

  auth.access_token |> should.equal("access-123")
  auth.account_id |> should.equal("")
}

pub fn parse_auth_json_rejects_missing_access_token_test() {
  let raw = "{\"tokens\":{\"account_id\":\"acct-456\"}}"

  codex_auth.parse_auth_json(raw)
  |> should.be_error
}

pub fn encode_decode_preserves_account_header_context_test() {
  let auth =
    codex_auth.CodexAuth(access_token: "access-123", account_id: "acct-456")

  let decoded = codex_auth.encode(auth) |> codex_auth.decode

  decoded.access_token |> should.equal("access-123")
  decoded.account_id |> should.equal("acct-456")
}

pub fn jwt_expires_at_ms_reads_exp_claim_test() {
  let jwt = "eyJhbGciOiJub25lIn0.eyJleHAiOjIwMDB9.sig"

  codex_auth.jwt_expires_at_ms(jwt)
  |> should.be_ok
  |> should.equal(2_000_000)
}

pub fn access_token_is_expired_uses_exp_with_buffer_test() {
  let jwt = "eyJhbGciOiJub25lIn0.eyJleHAiOjIwMDB9.sig"

  codex_auth.access_token_is_expired(jwt, 1_939_999)
  |> should.be_false
  codex_auth.access_token_is_expired(jwt, 1_940_000)
  |> should.be_true
}

pub fn apply_refresh_response_rotates_tokens_and_updates_timestamp_test() {
  let raw = "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":null,\"tokens\":{\"id_token\":\"old-id\",\"access_token\":\"old-access\",\"account_id\":\"acct-456\",\"refresh_token\":\"old-refresh\"},\"last_refresh\":\"2026-01-01T00:00:00Z\"}"
  let auth_file = codex_auth.parse_auth_json_file(raw) |> should.be_ok
  let body =
    "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\"}"

  let updated =
    codex_auth.apply_refresh_response(auth_file, body, 0) |> should.be_ok

  updated.tokens.access_token |> should.equal("new-access")
  updated.tokens.refresh_token |> should.equal("new-refresh")
  updated.tokens.id_token |> should.equal("old-id")
  updated.tokens.account_id |> should.equal("acct-456")
  updated.last_refresh |> should.equal("1970-01-01T00:00:00Z")
}
