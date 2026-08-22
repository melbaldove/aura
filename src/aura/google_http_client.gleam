//// Bounded HTTPS transport for the two Google read-only connectors.
////
//// This module applies the reviewed Google request guards and then sends only
//// to a fixed Google origin. It does not return a credential-bearing request.
//// Local tests use a separate test module.

import aura/google_oauth_http
import aura/google_readonly_http
import gleam/result
import gleam/string

const provider_body_limit = 1_048_576

const oauth_body_limit = 65_536

/// The request guard for one Google read-only GET.
pub type ReadGuard {
  Gmail
  GmailIdentity
  CalendarIdentity
  CalendarEvents(time_min: String, time_max: String, maximum: Int)
}

/// One bounded provider response.
pub type HttpResponse {
  HttpResponse(status: Int, retry_after_ms: Int, body: String)
}

/// The dispatch classification for one HTTP operation.
pub type Outcome {
  BeforeDispatch(error_class: String)
  AfterDispatch(error_class: String)
  Response(response: HttpResponse)
}

/// Validate one Google read-only GET without a socket effect.
///
/// This function returns no request value and no credential data.
pub fn validate_get_request(
  guard: ReadGuard,
  url: String,
  attempt_number: Int,
) -> Result(Nil, String) {
  use _ <- result.try(validate_get(guard, url))
  validate_attempt(attempt_number)
}

/// Validate one fixed Google OAuth POST without a socket effect.
///
/// This function returns no request value and no credential data.
pub fn validate_post_request(
  request: google_oauth_http.HttpRequest,
  attempt_number: Int,
) -> Result(Nil, String) {
  use _ <- result.try(google_oauth_http.validate_transport_request(request))
  validate_attempt(attempt_number)
}

/// Execute one validated production Google read-only GET.
pub fn get(
  guard: ReadGuard,
  url: String,
  access_token: String,
  attempt_number: Int,
) -> Outcome {
  case
    validate_get_request(guard, url, attempt_number),
    validate_token(access_token)
  {
    Error(error), _ -> BeforeDispatch(error)
    _, Error(error) -> BeforeDispatch(error)
    Ok(_), Ok(_) ->
      ffi_request(
        "GET",
        url,
        access_token,
        "",
        "",
        provider_body_limit,
        attempt_number,
      )
  }
}

/// Execute one validated production Google OAuth POST.
pub fn post(
  request: google_oauth_http.HttpRequest,
  attempt_number: Int,
) -> Outcome {
  case validate_post_request(request, attempt_number) {
    Error(error) -> BeforeDispatch(error)
    Ok(_) ->
      ffi_request(
        request.method,
        request.url,
        "",
        "application/x-www-form-urlencoded",
        request.body,
        oauth_body_limit,
        attempt_number,
      )
  }
}

fn validate_get(guard: ReadGuard, url: String) -> Result(Nil, String) {
  case guard {
    Gmail -> google_readonly_http.validate_request("GET", url)
    GmailIdentity ->
      google_oauth_http.validate_identity_transport_request("gmail", url)
    CalendarIdentity ->
      google_readonly_http.validate_calendar_identity_request("GET", url)
    CalendarEvents(time_min, time_max, maximum) ->
      google_readonly_http.validate_calendar_request(
        "GET",
        url,
        time_min,
        time_max,
        maximum,
      )
  }
}

fn validate_token(value: String) -> Result(Nil, String) {
  case
    value != ""
    && string.byte_size(value) <= 8192
    && !string.contains(value, "\n")
    && !string.contains(value, "\r")
  {
    True -> Ok(Nil)
    False -> Error("google_http_access_token_invalid")
  }
}

fn validate_attempt(value: Int) -> Result(Nil, String) {
  case value > 0 && value <= 16 {
    True -> Ok(Nil)
    False -> Error("google_http_attempt_invalid")
  }
}

@external(erlang, "aura_google_http_ffi", "request")
fn ffi_request(
  method: String,
  url: String,
  bearer: String,
  content_type: String,
  body: String,
  body_limit: Int,
  attempt_number: Int,
) -> Outcome
