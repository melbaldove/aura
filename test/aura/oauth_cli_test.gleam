import aura/oauth_cli
import aura/xdg
import gleam/string
import gleeunit/should

pub fn build_auth_url_includes_required_params_test() {
  let url = oauth_cli.build_auth_url("my-client-id")
  string.contains(url, "client_id=my-client-id") |> should.be_true
  string.contains(url, "response_type=code") |> should.be_true
  string.contains(url, "access_type=offline") |> should.be_true
  string.contains(url, "prompt=consent") |> should.be_true
  // Gmail scope URL-encoded:
  string.contains(url, "scope=https%3A%2F%2Fmail.google.com%2F")
  |> should.be_true
  // Loopback redirect:
  string.contains(url, "redirect_uri=http%3A%2F%2Flocalhost%2F")
  |> should.be_true
}

pub fn extract_code_from_full_redirect_url_test() {
  let pasted = "http://localhost/?code=4/abc-xyz&state=unused&scope=mail"
  oauth_cli.extract_code(pasted) |> should.equal(Ok("4/abc-xyz"))
}

pub fn extract_code_from_bare_query_test() {
  let pasted = "code=4/abc&state=s"
  oauth_cli.extract_code(pasted) |> should.equal(Ok("4/abc"))
}

pub fn extract_code_url_decodes_test() {
  let pasted = "http://localhost/?code=4%2Fabc%3D"
  // %2F = /, %3D = =
  oauth_cli.extract_code(pasted) |> should.equal(Ok("4/abc="))
}

pub fn extract_code_missing_returns_error_test() {
  let pasted = "http://localhost/?state=xyz"
  oauth_cli.extract_code(pasted) |> should.be_error
}

pub fn extract_code_empty_value_returns_error_test() {
  let pasted = "http://localhost/?code="
  oauth_cli.extract_code(pasted) |> should.be_error
}

pub fn token_path_for_uses_local_part_test() {
  let paths =
    xdg.Paths(
      config: "/home/u/.config/aura",
      data: "/home/u/.local/share/aura",
      state: "/home/u/.local/state/aura",
    )
  oauth_cli.token_path_for(paths, "alice@example.com")
  |> should.equal("/home/u/.config/aura/tokens/gmail-alice.json")
}

pub fn token_path_for_falls_back_to_full_email_test() {
  let paths =
    xdg.Paths(
      config: "/c",
      data: "/d",
      state: "/s",
    )
  oauth_cli.token_path_for(paths, "no-at-sign")
  |> should.equal("/c/tokens/gmail-no-at-sign.json")
}
