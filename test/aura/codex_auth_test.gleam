import aura/codex_auth
import gleeunit/should

pub fn parse_auth_json_reads_nested_codex_cli_tokens_test() {
  let raw =
    "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"access-123\",\"account_id\":\"acct-456\",\"refresh_token\":\"refresh-789\"}}"

  let auth = codex_auth.parse_auth_json(raw) |> should.be_ok

  auth.access_token |> should.equal("access-123")
  auth.account_id |> should.equal("acct-456")
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
