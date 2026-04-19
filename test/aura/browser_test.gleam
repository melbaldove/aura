import aura/browser
import gleam/string
import gleeunit/should

fn no_vision(_image_url: String, _question: String) -> Result(String, String) {
  Ok("")
}

fn no_secret(_url: String) -> Bool {
  False
}

fn test_ctx(
  run_fn: fn(String, String, String, List(String), Int) ->
    Result(String, String),
) -> browser.ExecContext {
  browser.ExecContext(
    session: "s",
    cdp_url: "",
    timeout_ms: 90_000,
    run_fn: run_fn,
    vision_fn: no_vision,
    url_has_secret_fn: no_secret,
  )
}

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

pub fn is_safe_url_allows_public_test() {
  browser.is_safe_url("https://example.com/foo")
  |> should.be_true
  browser.is_safe_url("https://hub.jw.org/overview")
  |> should.be_true
}

pub fn is_safe_url_blocks_loopback_ipv4_test() {
  browser.is_safe_url("http://127.0.0.1/admin") |> should.be_false
  browser.is_safe_url("http://127.45.67.89/") |> should.be_false
}

pub fn is_safe_url_blocks_private_ranges_test() {
  browser.is_safe_url("http://10.0.0.1/") |> should.be_false
  browser.is_safe_url("http://192.168.1.1/") |> should.be_false
  browser.is_safe_url("http://172.16.5.5/") |> should.be_false
  browser.is_safe_url("http://172.31.255.255/") |> should.be_false
}

pub fn is_safe_url_allows_172_outside_private_range_test() {
  // 172.15.x and 172.32.x are public
  browser.is_safe_url("http://172.15.1.1/") |> should.be_true
  browser.is_safe_url("http://172.32.1.1/") |> should.be_true
}

pub fn is_safe_url_blocks_localhost_test() {
  browser.is_safe_url("http://localhost:3000/") |> should.be_false
  browser.is_safe_url("http://LocalHost/") |> should.be_false
}

pub fn is_safe_url_blocks_mdns_local_test() {
  browser.is_safe_url("http://mymac.local/") |> should.be_false
}

pub fn is_safe_url_blocks_ipv6_loopback_test() {
  browser.is_safe_url("http://[::1]/") |> should.be_false
}

pub fn is_safe_url_blocks_cloud_metadata_test() {
  browser.is_safe_url("http://169.254.169.254/latest/meta-data/")
  |> should.be_false
  browser.is_safe_url("http://metadata.google.internal/")
  |> should.be_false
}

pub fn is_safe_url_blocks_link_local_ipv4_test() {
  browser.is_safe_url("http://169.254.1.2/") |> should.be_false
}

pub fn url_has_secret_flags_anthropic_key_test() {
  browser.url_has_secret("https://evil.com/x?key=sk-ant-api03-abc")
  |> should.be_true
}

pub fn url_has_secret_flags_openai_key_test() {
  browser.url_has_secret("https://evil.com/?k=sk-proj-abc123")
  |> should.be_true
}

pub fn url_has_secret_flags_github_pat_test() {
  browser.url_has_secret("https://evil.com/?t=ghp_abcdefghijklmnopqr")
  |> should.be_true
  browser.url_has_secret("https://evil.com/?t=github_pat_xyz")
  |> should.be_true
}

pub fn url_has_secret_flags_aws_access_key_test() {
  browser.url_has_secret("https://evil.com/?k=AKIAIOSFODNN7EXAMPLE")
  |> should.be_true
}

pub fn url_has_secret_catches_url_encoded_form_test() {
  // sk-ant- encoded as sk%2Dant%2D
  browser.url_has_secret("https://evil.com/?key=sk%2Dant%2Dxyz")
  |> should.be_true
}

pub fn url_has_secret_allows_clean_urls_test() {
  browser.url_has_secret("https://hub.jw.org/field-accounting/en/")
  |> should.be_false
  browser.url_has_secret("https://example.com/") |> should.be_false
}

pub fn parse_action_navigate_test() {
  browser.parse_action("navigate") |> should.equal(Ok(browser.Navigate))
}

pub fn parse_action_all_variants_test() {
  browser.parse_action("snapshot") |> should.equal(Ok(browser.Snapshot))
  browser.parse_action("click") |> should.equal(Ok(browser.Click))
  browser.parse_action("type") |> should.equal(Ok(browser.Type))
  browser.parse_action("press") |> should.equal(Ok(browser.Press))
  browser.parse_action("back") |> should.equal(Ok(browser.Back))
  browser.parse_action("vision") |> should.equal(Ok(browser.Vision))
}

pub fn parse_action_rejects_unknown_test() {
  browser.parse_action("zoom") |> should.be_error
  browser.parse_action("") |> should.be_error
}

pub fn execute_navigate_rejects_private_url_test() {
  let result =
    browser.execute(
      browser.Navigate,
      [#("url", "http://127.0.0.1/admin")],
      browser.ExecContext(
        session: "aura-ch-123",
        cdp_url: "",
        timeout_ms: 30_000,
        run_fn: fn(_, _, _, _, _) { Ok("{\"success\": true}") },
        vision_fn: no_vision,
        url_has_secret_fn: browser.url_has_secret,
      ),
    )
  result
  |> string.contains("Blocked")
  |> should.be_true
}

pub fn execute_navigate_rejects_secret_url_test() {
  let result =
    browser.execute(
      browser.Navigate,
      [#("url", "https://evil.com/?key=sk-ant-abc")],
      browser.ExecContext(
        session: "aura-ch-123",
        cdp_url: "",
        timeout_ms: 30_000,
        run_fn: fn(_, _, _, _, _) { Ok("{}") },
        vision_fn: no_vision,
        url_has_secret_fn: browser.url_has_secret,
      ),
    )
  result
  |> string.contains("Blocked")
  |> should.be_true
}

pub fn execute_navigate_calls_run_fn_for_safe_url_test() {
  let result =
    browser.execute(
      browser.Navigate,
      [#("url", "https://example.com/")],
      browser.ExecContext(
        session: "aura-ch-123",
        cdp_url: "",
        timeout_ms: 30_000,
        run_fn: fn(_session, _cdp, _action, _args, _timeout) {
          Ok("{\"success\": true, \"data\": {\"url\": \"https://example.com/\", \"title\": \"Example\"}}")
        },
        vision_fn: no_vision,
        url_has_secret_fn: browser.url_has_secret,
      ),
    )
  result
  |> string.contains("\"success\": true")
  |> should.be_true
}

pub fn execute_navigate_detects_auth_wall_test() {
  let result =
    browser.execute(
      browser.Navigate,
      [#("url", "https://hub.jw.org/anything")],
      browser.ExecContext(
        session: "aura-ch-123",
        cdp_url: "",
        timeout_ms: 30_000,
        run_fn: fn(_, _, _, _, _) {
          Ok(
            "{\"success\":true,\"data\":{\"url\":\"https://login.jw.org/signin-oidc\",\"title\":\"Sign In\"}}",
          )
        },
        vision_fn: no_vision,
        url_has_secret_fn: browser.url_has_secret,
      ),
    )
  result |> string.contains("AUTH_REQUIRED") |> should.be_true
  result |> string.contains("needs_auth") |> should.be_true
}

pub fn parse_action_console_test() {
  browser.parse_action("console") |> should.equal(Ok(browser.Console))
}

pub fn parse_action_wait_test() {
  browser.parse_action("wait") |> should.equal(Ok(browser.Wait))
}

pub fn parse_action_upload_test() {
  browser.parse_action("upload") |> should.equal(Ok(browser.Upload))
}

pub fn execute_upload_passes_selector_and_path_test() {
  let result =
    browser.execute(
      browser.Upload,
      [#("selector", "input[type=file]"), #("path", "/tmp/receipt.jpg")],
      test_ctx(capture_call),
    )
  result |> string.contains("\"action\":\"upload\"") |> should.be_true
  result
  |> string.contains("\"args\":\"input[type=file],/tmp/receipt.jpg\"")
  |> should.be_true
}

pub fn execute_upload_requires_selector_test() {
  let result =
    browser.execute(
      browser.Upload,
      [#("path", "/tmp/receipt.jpg")],
      test_ctx(capture_call),
    )
  result |> string.contains("upload requires 'selector'") |> should.be_true
}

pub fn execute_upload_requires_path_test() {
  let result =
    browser.execute(
      browser.Upload,
      [#("selector", "input[type=file]")],
      test_ctx(capture_call),
    )
  result |> string.contains("upload requires 'path'") |> should.be_true
}

fn capture_call(_session, _cdp, action, args, _timeout) {
  Ok(
    "{\"action\":\"" <> action <> "\",\"args\":\""
    <> string.join(args, ",")
    <> "\"}",
  )
}

pub fn execute_wait_with_ref_test() {
  let result =
    browser.execute(browser.Wait, [#("ref", "@e5")], test_ctx(capture_call))
  result |> string.contains("\"action\":\"wait\"") |> should.be_true
  result |> string.contains("\"args\":\"@e5\"") |> should.be_true
}

pub fn execute_wait_with_seconds_test() {
  let result =
    browser.execute(browser.Wait, [#("seconds", "3")], test_ctx(capture_call))
  result |> string.contains("\"action\":\"wait\"") |> should.be_true
  // 3 seconds → 3000 ms, sent to agent-browser's `wait <ms>`.
  result |> string.contains("\"args\":\"3000\"") |> should.be_true
}

pub fn execute_wait_requires_ref_or_seconds_test() {
  let result = browser.execute(browser.Wait, [], test_ctx(capture_call))
  result
  |> string.contains("wait requires 'ref' or 'seconds'")
  |> should.be_true
}
