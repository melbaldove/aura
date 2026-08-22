import aura/google_oauth_http
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

const gmail_scope = "https://www.googleapis.com/auth/gmail.readonly"

const calendar_scope = "https://www.googleapis.com/auth/calendar.readonly"

pub fn main() {
  gleeunit.main()
}

pub fn code_exchange_is_fixed_and_includes_optional_desktop_secret_test() {
  let request =
    google_oauth_http.code_exchange_request(
      "client.apps.googleusercontent.com",
      "client-secret",
      "provider-code",
      string.repeat("v", 43),
      "http://127.0.0.1:49152/callback",
    )
    |> should.be_ok
  request.method |> should.equal("POST")
  request.url |> should.equal("https://oauth2.googleapis.com/token")
  request.body
  |> string.contains("grant_type=authorization_code")
  |> should.be_true
  request.body |> string.contains("code=provider-code") |> should.be_true
  request.body
  |> string.contains("code_verifier=" <> string.repeat("v", 43))
  |> should.be_true
  request.body
  |> string.contains("client_secret=client-secret")
  |> should.be_true
  request.headers
  |> should.equal([#("content-type", "application/x-www-form-urlencoded")])

  let without_secret =
    google_oauth_http.code_exchange_request(
      "client.apps.googleusercontent.com",
      "",
      "provider-code",
      string.repeat("v", 43),
      "http://127.0.0.1:49152/callback",
    )
    |> should.be_ok
  without_secret.body |> string.contains("client_secret") |> should.be_false
}

pub fn initial_token_response_requires_exact_one_scope_and_refresh_token_test() {
  let valid =
    google_oauth_http.decode_initial_token_response(
      google_oauth_http.HttpResponse(
        status: 200,
        body: token_json(gmail_scope, "refresh-token"),
      ),
      gmail_scope,
    )
    |> should.be_ok
  valid.granted_scope |> should.equal(gmail_scope)
  valid.refresh_token |> should.equal("refresh-token")

  [
    gmail_scope <> " https://www.googleapis.com/auth/gmail.modify",
    gmail_scope <> " " <> gmail_scope,
    calendar_scope,
    "",
  ]
  |> list.each(fn(scope) {
    google_oauth_http.decode_initial_token_response(
      google_oauth_http.HttpResponse(
        status: 200,
        body: token_json(scope, "refresh-token"),
      ),
      gmail_scope,
    )
    |> should.be_error
  })
  google_oauth_http.decode_initial_token_response(
    google_oauth_http.HttpResponse(
      status: 200,
      body: token_json(gmail_scope, ""),
    ),
    gmail_scope,
  )
  |> should.be_error
}

pub fn token_response_rejects_wrong_type_expiry_and_unbounded_secrets_test() {
  google_oauth_http.decode_initial_token_response(
    google_oauth_http.HttpResponse(
      status: 200,
      body: "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"scope\":\""
        <> gmail_scope
        <> "\",\"token_type\":\"MAC\",\"expires_in\":3600}",
    ),
    gmail_scope,
  )
  |> should.be_error
  google_oauth_http.decode_initial_token_response(
    google_oauth_http.HttpResponse(
      status: 200,
      body: "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"scope\":\""
        <> gmail_scope
        <> "\",\"token_type\":\"Bearer\",\"expires_in\":0}",
    ),
    gmail_scope,
  )
  |> should.be_error
  google_oauth_http.decode_initial_token_response(
    google_oauth_http.HttpResponse(
      status: 200,
      body: token_json(gmail_scope, string.repeat("r", 8193)),
    ),
    gmail_scope,
  )
  |> should.be_error
}

pub fn refresh_keeps_prior_scope_and_refresh_token_only_when_omitted_test() {
  let omitted =
    google_oauth_http.decode_refresh_token_response(
      google_oauth_http.HttpResponse(
        status: 200,
        body: "{\"access_token\":\"new-access\",\"token_type\":\"Bearer\",\"expires_in\":1800}",
      ),
      gmail_scope,
      "old-refresh",
    )
    |> should.be_ok
  omitted.granted_scope |> should.equal(gmail_scope)
  omitted.refresh_token |> should.equal("old-refresh")

  google_oauth_http.decode_refresh_token_response(
    google_oauth_http.HttpResponse(
      status: 200,
      body: "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"scope\":\""
        <> calendar_scope
        <> "\",\"token_type\":\"Bearer\",\"expires_in\":1800}",
    ),
    gmail_scope,
    "old-refresh",
  )
  |> should.be_error
}

pub fn provider_errors_are_closed_and_bounded_test() {
  google_oauth_http.decode_initial_token_response(
    google_oauth_http.HttpResponse(
      status: 400,
      body: "{\"error\":\"invalid_grant\",\"error_description\":\"secret provider text\"}",
    ),
    gmail_scope,
  )
  |> should.equal(Error("google_oauth_invalid_grant"))
  google_oauth_http.decode_initial_token_response(
    google_oauth_http.HttpResponse(
      status: 500,
      body: string.repeat("x", 65_537),
    ),
    gmail_scope,
  )
  |> should.equal(Error("google_oauth_response_too_large"))

  google_oauth_http.decode_initial_token_response(
    google_oauth_http.HttpResponse(
      status: 500,
      body: string.repeat("é", 32_769),
    ),
    gmail_scope,
  )
  |> should.equal(Error("google_oauth_response_too_large"))
}

pub fn identity_reads_are_fixed_and_return_only_the_account_seed_test() {
  let gmail =
    google_oauth_http.identity_request("gmail", "access-token")
    |> should.be_ok
  gmail.method |> should.equal("GET")
  gmail.url
  |> should.equal(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress",
  )
  let calendar =
    google_oauth_http.identity_request("calendar", "access-token")
    |> should.be_ok
  calendar.url
  |> should.equal(
    "https://www.googleapis.com/calendar/v3/calendars/primary?fields=id",
  )
  google_oauth_http.decode_identity_response(
    "gmail",
    google_oauth_http.HttpResponse(
      status: 200,
      body: "{\"emailAddress\":\"person@example.test\",\"messagesTotal\":99}",
    ),
  )
  |> should.equal(Ok("person@example.test"))
  google_oauth_http.decode_identity_response(
    "calendar",
    google_oauth_http.HttpResponse(
      status: 200,
      body: "{\"id\":\"primary-account@example.test\",\"summary\":\"Private\"}",
    ),
  )
  |> should.equal(Ok("primary-account@example.test"))
}

fn token_json(scope: String, refresh_token: String) -> String {
  "{\"access_token\":\"access-token\",\"refresh_token\":\""
  <> refresh_token
  <> "\",\"scope\":\""
  <> scope
  <> "\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
}
