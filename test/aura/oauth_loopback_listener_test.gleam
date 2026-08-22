import aura/oauth_loopback
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should

pub fn one_shot_listener_accepts_only_exact_callback_test() {
  let assert Ok(listener) =
    oauth_loopback.listen_once(fn(kind, state, value) {
      #(kind, state, value) |> should.equal(#("code", "state-123", "code-456"))
      True
    })
  let host = "127.0.0.1:" <> int.to_string(listener.port)
  let assert Ok(response) =
    oauth_loopback.request_once(
      listener.port,
      "GET /callback?state=state-123&code=code-456 HTTP/1.1\r\nHost: "
        <> host
        <> "\r\n\r\n",
    )
  response |> string.contains("200 OK") |> should.be_true
  response |> string.contains("Cache-Control: no-store") |> should.be_true
  response |> string.contains("Referrer-Policy: no-referrer") |> should.be_true
  response
  |> string.contains("Content-Security-Policy: default-src 'none'")
  |> should.be_true

  oauth_loopback.request_once(
    listener.port,
    "GET /callback?state=state-123&code=second HTTP/1.1\r\nHost: "
      <> host
      <> "\r\n\r\n",
  )
  |> should.be_error
}

pub fn listener_rejects_wrong_host_method_path_and_duplicates_test() {
  let cases = [
    "POST /callback?state=s&code=c HTTP/1.1\r\nHost: {host}\r\n\r\n",
    "GET /wrong?state=s&code=c HTTP/1.1\r\nHost: {host}\r\n\r\n",
    "GET /callback?state=s&state=x&code=c HTTP/1.1\r\nHost: {host}\r\n\r\n",
    "GET /callback?state=s&code=c&code=x HTTP/1.1\r\nHost: {host}\r\n\r\n",
    "GET /callback?state=s&code=c HTTP/1.1\r\nHost: attacker.invalid\r\n\r\n",
  ]
  cases
  |> list.each(fn(template) {
    let assert Ok(listener) = oauth_loopback.listen_once(fn(_, _, _) { True })
    let host = "127.0.0.1:" <> int.to_string(listener.port)
    let request = string.replace(template, "{host}", host)
    let assert Ok(response) =
      oauth_loopback.request_once(listener.port, request)
    response |> string.contains("400 Bad Request") |> should.be_true
  })
}

pub fn listener_rejects_oversized_target_and_header_test() {
  let assert Ok(target_listener) =
    oauth_loopback.listen_once(fn(_, _, _) { True })
  let target_host = "127.0.0.1:" <> int.to_string(target_listener.port)
  let assert Ok(target_response) =
    oauth_loopback.request_once(
      target_listener.port,
      "GET /callback?state=s&code="
        <> string.repeat("a", 2050)
        <> " HTTP/1.1\r\nHost: "
        <> target_host
        <> "\r\n\r\n",
    )
  target_response |> string.contains("400 Bad Request") |> should.be_true

  let assert Ok(header_listener) =
    oauth_loopback.listen_once(fn(_, _, _) { True })
  let header_host = "127.0.0.1:" <> int.to_string(header_listener.port)
  let assert Ok(header_response) =
    oauth_loopback.request_once(
      header_listener.port,
      "GET /callback?state=s&code=c HTTP/1.1\r\nHost: "
        <> header_host
        <> "\r\nX-Bounded: "
        <> string.repeat("b", 4097)
        <> "\r\n\r\n",
    )
  header_response |> string.contains("400 Bad Request") |> should.be_true
}

pub fn listener_rejects_malformed_encoding_and_excess_headers_test() {
  let assert Ok(encoding_listener) =
    oauth_loopback.listen_once(fn(_, _, _) { True })
  let encoding_host = "127.0.0.1:" <> int.to_string(encoding_listener.port)
  let assert Ok(encoding_response) =
    oauth_loopback.request_once(
      encoding_listener.port,
      "GET /callback?state=s&code=%ZZ HTTP/1.1\r\nHost: "
        <> encoding_host
        <> "\r\n\r\n",
    )
  encoding_response |> string.contains("400 Bad Request") |> should.be_true

  let assert Ok(headers_listener) =
    oauth_loopback.listen_once(fn(_, _, _) { True })
  let headers_host = "127.0.0.1:" <> int.to_string(headers_listener.port)
  let extra_headers = test_headers(65)
  let assert Ok(headers_response) =
    oauth_loopback.request_once(
      headers_listener.port,
      "GET /callback?state=s&code=c HTTP/1.1\r\nHost: "
        <> headers_host
        <> "\r\n"
        <> extra_headers
        <> "\r\n",
    )
  headers_response |> string.contains("400 Bad Request") |> should.be_true
}

pub fn incomplete_request_expires_at_the_absolute_listener_deadline_test() {
  let expired = process.new_subject()
  let assert Ok(listener) =
    oauth_loopback.listen_once_with_timeout_for_test(
      fn(kind, _, _) {
        process.send(expired, kind)
        False
      },
      50,
    )
  let host = "127.0.0.1:" <> int.to_string(listener.port)
  let assert Ok(response) =
    oauth_loopback.request_once(
      listener.port,
      "GET /callback?state=s&code=c HTTP/1.1\r\nHost: " <> host,
    )
  response |> string.contains("400 Bad Request") |> should.be_true
  process.receive(expired, 500) |> should.equal(Ok("expired"))
}

pub fn access_denied_is_bounded_and_never_returns_provider_values_test() {
  let assert Ok(listener) =
    oauth_loopback.listen_once(fn(kind, state, value) {
      #(kind, state, value)
      |> should.equal(#("error", "state-secret", "access_denied"))
      False
    })
  let host = "127.0.0.1:" <> int.to_string(listener.port)
  let assert Ok(response) =
    oauth_loopback.request_once(
      listener.port,
      "GET /callback?state=state-secret&error=access_denied HTTP/1.1\r\nHost: "
        <> host
        <> "\r\n\r\n",
    )
  response |> string.contains("400 Bad Request") |> should.be_true
  response |> string.contains("state-secret") |> should.be_false
  response |> string.contains("access_denied") |> should.be_false
}

pub fn forced_listener_crash_stops_its_linked_owner_test() {
  let listener_subject = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(listener) = oauth_loopback.listen_once(fn(_, _, _) { True })
      process.send(listener_subject, listener.pid)
      process.sleep_forever()
    })
  let monitor = process.monitor(owner)
  let assert Ok(listener_pid) = process.receive(listener_subject, 1000)
  process.kill(listener_pid)
  process.selector_receive(
    process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down }),
    1000,
  )
  |> should.be_ok
}

fn test_headers(count: Int) -> String {
  case count {
    0 -> ""
    _ ->
      "X-Test-" <> int.to_string(count) <> ": x\r\n" <> test_headers(count - 1)
  }
}
