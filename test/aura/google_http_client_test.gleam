import aura/google_http_client
import aura/google_oauth_http
import fakes/google_http_server
import gleam/int
import gleam/string
import gleeunit
import gleeunit/should

const profile_url = "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId"

pub fn main() {
  gleeunit.main()
}

pub fn invalid_read_is_rejected_before_dispatch_test() {
  google_http_client.validate_get_request(
    google_http_client.Gmail,
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/id?format=full",
    1,
  )
  |> should.equal(Error("google_readonly_query_not_allowed"))
}

pub fn token_post_is_fixed_and_bounded_test() {
  let request =
    google_oauth_http.refresh_request(
      "client.apps.googleusercontent.com",
      "synthetic-client-secret",
      "synthetic-refresh-token",
    )
    |> should.be_ok
  let server =
    google_http_server.start(
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}",
      0,
    )
    |> should.be_ok
  google_http_server.execute_post(request, 1, server)
  |> should.equal(response(200, 0, "{}"))
}

pub fn read_adds_bearer_only_inside_transport_test() {
  let server =
    google_http_server.start(
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
      0,
    )
    |> should.be_ok
  execute_profile(server) |> should.equal(response(200, 0, "{}"))
  google_http_server.last_request()
  |> string.contains("authorization: Bearer synthetic-access-token")
  |> should.be_true
}

pub fn redirects_and_compression_fail_after_dispatch_test() {
  let redirect =
    google_http_server.start(
      "HTTP/1.1 302 Found\r\nLocation: https://example.test/\r\nContent-Length: 0\r\n\r\n",
      0,
    )
    |> should.be_ok
  execute_profile(redirect)
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_redirect_not_allowed",
  ))

  let compressed =
    google_http_server.start(
      "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}",
      0,
    )
    |> should.be_ok
  execute_profile(compressed)
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_content_encoding_not_allowed",
  ))
}

pub fn every_status_has_a_preallocation_body_limit_test() {
  let body = string.repeat("x", 1_048_577)
  let declared =
    google_http_server.start(
      "HTTP/1.1 500 Server Error\r\nContent-Length: 1048577\r\n\r\n" <> body,
      0,
    )
    |> should.be_ok
  execute_profile(declared)
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_response_too_large",
  ))

  let chunked =
    google_http_server.start(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        <> int.to_base16(string.byte_size(body))
        <> "\r\n"
        <> body
        <> "\r\n0\r\n\r\n",
      0,
    )
    |> should.be_ok
  execute_profile(chunked)
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_response_too_large",
  ))
}

pub fn status_and_headers_are_bounded_before_parse_test() {
  let status =
    google_http_server.start(
      "HTTP/1.1 200 " <> string.repeat("x", 1025) <> "\r\n\r\n",
      0,
    )
    |> should.be_ok
  execute_profile(status)
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_status_line_too_large",
  ))

  let headers =
    google_http_server.start(
      "HTTP/1.1 200 OK\r\nX-Large: " <> string.repeat("x", 32_769) <> "\r\n\r\n",
      0,
    )
    |> should.be_ok
  execute_profile(headers)
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_headers_too_large",
  ))
}

pub fn malformed_status_and_header_count_fail_closed_test() {
  let malformed =
    google_http_server.start("NOT HTTP\r\nContent-Length: 0\r\n\r\n", 0)
    |> should.be_ok
  execute_profile(malformed)
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_response_invalid",
  ))

  let many_headers = string.repeat("X-Test: x\r\n", 65)
  let server =
    google_http_server.start(
      "HTTP/1.1 200 OK\r\n" <> many_headers <> "Content-Length: 0\r\n\r\n",
      0,
    )
    |> should.be_ok
  execute_profile(server)
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_headers_too_large",
  ))
}

pub fn retry_after_uses_bounds_and_exponential_fallback_test() {
  google_http_server.retry_after_ms(429, "120", 1000, 1)
  |> should.equal(120_000)
  google_http_server.retry_after_ms(503, "999999999", 1000, 1)
  |> should.equal(3_600_000)
  google_http_server.retry_after_ms(500, "invalid provider text", 1000, 4)
  |> should.equal(8000)
  google_http_server.retry_after_ms(500, "", 1000, 16)
  |> should.equal(60_000)
  google_http_server.retry_after_ms(200, "", 1000, 4)
  |> should.equal(0)
}

pub fn lost_response_is_closed_after_dispatch_test() {
  let lost = google_http_server.start("", 0) |> should.be_ok
  execute_profile(lost)
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_transport_failed",
  ))
}

pub fn slow_response_hits_the_fixed_idle_timeout_test() {
  let slow =
    google_http_server.start(
      "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
      6000,
    )
    |> should.be_ok
  execute_profile(slow)
  |> should.equal(google_http_client.AfterDispatch("google_http_idle_timeout"))
}

pub fn slow_drip_hits_one_absolute_request_deadline_test() {
  let drip =
    google_http_server.start_drip(
      "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
      20,
    )
    |> should.be_ok
  google_http_server.execute_get_with_timeout(
    google_http_client.Gmail,
    profile_url,
    "synthetic-access-token",
    1,
    drip,
    100,
  )
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_request_timeout",
  ))
}

fn execute_profile(origin: String) -> google_http_client.Outcome {
  google_http_server.execute_get(
    google_http_client.Gmail,
    profile_url,
    "synthetic-access-token",
    1,
    origin,
  )
}

fn response(status: Int, retry: Int, body: String) -> google_http_client.Outcome {
  google_http_client.Response(google_http_client.HttpResponse(
    status:,
    retry_after_ms: retry,
    body:,
  ))
}
