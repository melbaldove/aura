// test/aura/browser_test.gleam
import aura/browser
import gleam/string
import gleeunit/should

pub fn browser_module_compiles_test() {
  browser.Navigate |> should.equal(browser.Navigate)
}

pub fn resolve_session_uses_channel_when_arg_empty_test() {
  browser.resolve_session("", "1234567890")
  |> should.equal(Ok("aura-ch-1234567890"))
}

pub fn resolve_session_prefixes_named_session_test() {
  browser.resolve_session("hub-jw-org", "1234567890")
  |> should.equal(Ok("aura-named-hub-jw-org"))
}

pub fn resolve_session_named_ignores_channel_test() {
  browser.resolve_session("shared", "")
  |> should.equal(Ok("aura-named-shared"))
}

pub fn resolve_session_errors_when_both_empty_test() {
  browser.resolve_session("", "")
  |> should.be_error
}

pub fn truncate_snapshot_returns_input_when_under_threshold_test() {
  let text = "line 1\nline 2\nline 3"
  browser.truncate_snapshot(text, 8000)
  |> should.equal(text)
}

pub fn truncate_snapshot_cuts_at_line_boundary_test() {
  let text = "aaaaaaaa\nbbbbbbbb\ncccccccc\ndddddddd"
  let result = browser.truncate_snapshot(text, 20)
  result
  |> string.contains("aaaaaaaa")
  |> should.be_true
  // Should not split a line mid-way — "bbbb\n" means line was cut
  result
  |> string.contains("bbbb\n")
  |> should.be_false
}

pub fn truncate_snapshot_appends_footer_when_cut_test() {
  let text = "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\ndddddddddd"
  let result = browser.truncate_snapshot(text, 25)
  result
  |> string.contains("more lines truncated")
  |> should.be_true
}

pub fn truncate_snapshot_no_footer_when_not_cut_test() {
  let text = "short"
  browser.truncate_snapshot(text, 8000)
  |> string.contains("truncated")
  |> should.be_false
}

pub fn detect_auth_required_catches_signin_url_test() {
  browser.detect_auth_required(
    "https://example.com/signin",
    "Sign In",
  )
  |> should.be_true
}

pub fn detect_auth_required_catches_oauth_redirect_test() {
  browser.detect_auth_required(
    "https://auth.example.com/oauth/authorize?client_id=x",
    "Log In",
  )
  |> should.be_true
}

pub fn detect_auth_required_catches_oidc_test() {
  browser.detect_auth_required(
    "https://hub.jw.org/signin-oidc",
    "Redirecting...",
  )
  |> should.be_true
}

pub fn detect_auth_required_false_for_normal_page_test() {
  browser.detect_auth_required(
    "https://example.com/dashboard",
    "Dashboard — My App",
  )
  |> should.be_false
}

pub fn detect_auth_required_title_case_insensitive_test() {
  browser.detect_auth_required("https://example.com/home", "LOGIN")
  |> should.be_true
}
