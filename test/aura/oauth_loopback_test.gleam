import aura/oauth_loopback
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn owner_creates_exact_loopback_pkce_session_test() {
  let assert Ok(started) = oauth_loopback.start()
  let handle =
    oauth_loopback.begin(
      started.data,
      "authorization:prep",
      "configuration:gmail",
      "oauth-client:gmail",
      45_678,
    )
    |> should.be_ok
  handle.redirect_uri |> should.equal("http://127.0.0.1:45678/callback")
  handle.scope
  |> should.equal("https://www.googleapis.com/auth/gmail.readonly")
  handle.state |> should.not_equal("")
  handle.code_challenge |> should.not_equal("")
}

pub fn owner_creates_distinct_exact_calendar_session_test() {
  let assert Ok(started) = oauth_loopback.start()
  let handle =
    oauth_loopback.begin_calendar(
      started.data,
      "authorization:prep",
      "configuration:calendar",
      "oauth-client:google",
      45_679,
    )
    |> should.be_ok
  handle.scope
  |> should.equal("https://www.googleapis.com/auth/calendar.readonly")
  let grant =
    oauth_loopback.consume(
      started.data,
      handle.session_ref,
      handle.redirect_uri,
      handle.state,
      "opaque-code",
    )
    |> should.be_ok
  let request = oauth_loopback.token_exchange_request(grant) |> should.be_ok
  request.connector_id |> should.equal("calendar")
  request.configuration_ref |> should.equal("configuration:calendar")
  request.scope
  |> should.equal("https://www.googleapis.com/auth/calendar.readonly")
}

pub fn callback_requires_exact_state_and_is_consumed_once_test() {
  let assert Ok(started) = oauth_loopback.start()
  let first =
    oauth_loopback.begin(
      started.data,
      "authorization:prep",
      "configuration:gmail",
      "oauth-client:gmail",
      45_678,
    )
    |> should.be_ok
  oauth_loopback.consume(
    started.data,
    first.session_ref,
    first.redirect_uri,
    "wrong-state",
    "opaque-code",
  )
  |> should.equal(Error("oauth_loopback_state_mismatch"))
  oauth_loopback.consume(
    started.data,
    first.session_ref,
    first.redirect_uri,
    first.state,
    "opaque-code",
  )
  |> should.equal(Error("oauth_loopback_session_not_usable"))

  let second =
    oauth_loopback.begin(
      started.data,
      "authorization:prep",
      "configuration:gmail",
      "oauth-client:gmail",
      45_678,
    )
    |> should.be_ok
  let grant =
    oauth_loopback.consume(
      started.data,
      second.session_ref,
      second.redirect_uri,
      second.state,
      "opaque-code",
    )
    |> should.be_ok
  let request = oauth_loopback.token_exchange_request(grant) |> should.be_ok
  request.endpoint |> should.equal("https://oauth2.googleapis.com/token")
  request.preparation_authorization_id
  |> should.equal("authorization:prep")
  request.connector_id |> should.equal("gmail")
  request.configuration_ref |> should.equal("configuration:gmail")
  request.oauth_client_ref |> should.equal("oauth-client:gmail")
  request.scope
  |> should.equal("https://www.googleapis.com/auth/gmail.readonly")
  request.code |> should.equal("opaque-code")
  oauth_loopback.consume(
    started.data,
    second.session_ref,
    second.redirect_uri,
    second.state,
    "opaque-code",
  )
  |> should.equal(Error("oauth_loopback_session_not_usable"))
}

pub fn callback_rejects_redirect_and_code_without_leaking_values_test() {
  let assert Ok(started) = oauth_loopback.start()
  let redirect_handle =
    oauth_loopback.begin(
      started.data,
      "authorization:prep",
      "configuration:gmail",
      "oauth-client:gmail",
      45_678,
    )
    |> should.be_ok
  oauth_loopback.consume(
    started.data,
    redirect_handle.session_ref,
    "http://localhost:45678/callback",
    redirect_handle.state,
    "opaque-code",
  )
  |> should.equal(Error("oauth_loopback_redirect_mismatch"))
  let code_handle =
    oauth_loopback.begin(
      started.data,
      "authorization:prep",
      "configuration:gmail",
      "oauth-client:gmail",
      45_678,
    )
    |> should.be_ok
  oauth_loopback.consume(
    started.data,
    code_handle.session_ref,
    code_handle.redirect_uri,
    code_handle.state,
    "code with spaces",
  )
  |> should.equal(Error("oauth_loopback_session_not_usable"))
}

pub fn random_sessions_have_distinct_state_and_pkce_test() {
  let assert Ok(started) = oauth_loopback.start()
  let first =
    oauth_loopback.begin(
      started.data,
      "authorization:prep",
      "configuration:gmail",
      "oauth-client:gmail",
      45_678,
    )
    |> should.be_ok
  let second =
    oauth_loopback.begin(
      started.data,
      "authorization:prep",
      "configuration:gmail",
      "oauth-client:gmail",
      45_678,
    )
    |> should.be_ok
  first.state |> should.not_equal(second.state)
  first.code_challenge |> should.not_equal(second.code_challenge)
}
