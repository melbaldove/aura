//// Loopback-only Google HTTP protocol fixture.
////
//// Production code cannot select this origin. A test must first obtain an
//// opaque request from the production request guard.

import aura/google_http_client
import aura/google_oauth_http

/// Start one loopback response fixture.
pub fn start(raw_response: String, delay_ms: Int) -> Result(String, String) {
  ffi_start(raw_response, delay_ms)
}

/// Start one loopback fixture that sends one response byte per interval.
pub fn start_drip(
  raw_response: String,
  interval_ms: Int,
) -> Result(String, String) {
  ffi_start_drip(raw_response, interval_ms)
}

/// Execute one validated GET against a loopback fixture.
pub fn execute_get(
  guard: google_http_client.ReadGuard,
  url: String,
  bearer: String,
  attempt_number: Int,
  origin: String,
) -> google_http_client.Outcome {
  case google_http_client.validate_get_request(guard, url, attempt_number) {
    Error(error) -> google_http_client.BeforeDispatch(error)
    Ok(_) ->
      ffi_request("GET", url, bearer, "", "", 1_048_576, attempt_number, origin)
  }
}

/// Execute one validated GET with a shorter test-only absolute deadline.
pub fn execute_get_with_timeout(
  guard: google_http_client.ReadGuard,
  url: String,
  bearer: String,
  attempt_number: Int,
  origin: String,
  timeout_ms: Int,
) -> google_http_client.Outcome {
  case google_http_client.validate_get_request(guard, url, attempt_number) {
    Error(error) -> google_http_client.BeforeDispatch(error)
    Ok(_) ->
      ffi_request_with_timeout(
        "GET",
        url,
        bearer,
        "",
        "",
        1_048_576,
        attempt_number,
        origin,
        timeout_ms,
      )
  }
}

/// Execute one validated OAuth POST against a loopback fixture.
pub fn execute_post(
  request: google_oauth_http.HttpRequest,
  attempt_number: Int,
  origin: String,
) -> google_http_client.Outcome {
  case google_http_client.validate_post_request(request, attempt_number) {
    Error(error) -> google_http_client.BeforeDispatch(error)
    Ok(_) ->
      ffi_request(
        request.method,
        request.url,
        "",
        "application/x-www-form-urlencoded",
        request.body,
        65_536,
        attempt_number,
        origin,
      )
  }
}

/// Return the last request captured by the fixture.
pub fn last_request() -> String {
  ffi_last_request()
}

/// Parse one Retry-After value with the production policy.
pub fn retry_after_ms(
  status: Int,
  value: String,
  now_ms: Int,
  attempt_number: Int,
) -> Int {
  ffi_retry_after_ms(status, value, now_ms, attempt_number)
}

@external(erlang, "aura_google_http_fake_ffi", "start")
fn ffi_start(raw_response: String, delay_ms: Int) -> Result(String, String)

@external(erlang, "aura_google_http_fake_ffi", "start_drip")
fn ffi_start_drip(
  raw_response: String,
  interval_ms: Int,
) -> Result(String, String)

@external(erlang, "aura_google_http_fake_ffi", "last_request")
fn ffi_last_request() -> String

@external(erlang, "aura_google_http_ffi", "request_for_test")
fn ffi_request(
  method: String,
  url: String,
  bearer: String,
  content_type: String,
  body: String,
  body_limit: Int,
  attempt_number: Int,
  origin: String,
) -> google_http_client.Outcome

@external(erlang, "aura_google_http_ffi", "request_for_test_with_timeout")
fn ffi_request_with_timeout(
  method: String,
  url: String,
  bearer: String,
  content_type: String,
  body: String,
  body_limit: Int,
  attempt_number: Int,
  origin: String,
  timeout_ms: Int,
) -> google_http_client.Outcome

@external(erlang, "aura_google_http_ffi", "retry_after_ms")
fn ffi_retry_after_ms(
  status: Int,
  value: String,
  now_ms: Int,
  attempt_number: Int,
) -> Int
