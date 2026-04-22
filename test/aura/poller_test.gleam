import aura/poller
import gleeunit/should

/// Backoff starts small, doubles, and caps at the ceiling.
/// Used by the poller's reconnect loop so a network outage can't burn
/// through the root supervisor's restart budget.
pub fn compute_backoff_ms_exponential_with_cap_test() {
  poller.compute_backoff_ms(0) |> should.equal(5000)
  poller.compute_backoff_ms(1) |> should.equal(10_000)
  poller.compute_backoff_ms(2) |> should.equal(20_000)
  poller.compute_backoff_ms(3) |> should.equal(40_000)
  poller.compute_backoff_ms(4) |> should.equal(60_000)
  poller.compute_backoff_ms(10) |> should.equal(60_000)
}

pub fn compute_backoff_ms_handles_negative_attempt_test() {
  poller.compute_backoff_ms(-1) |> should.equal(5000)
}

/// Fatal errors stop retry so a bad token or API change doesn't spin
/// forever. Everything else — network, TLS, 5xx, rate limits, WS handshake
/// failure — is transient and retried.
pub fn is_fatal_error_auth_and_parse_test() {
  poller.is_fatal_error("Unexpected status 401 from gateway/bot")
  |> should.be_true
  poller.is_fatal_error("Unexpected status 403 from gateway/bot")
  |> should.be_true
  poller.is_fatal_error("Failed to parse gateway URL from response")
  |> should.be_true
}

pub fn is_fatal_error_network_is_transient_test() {
  poller.is_fatal_error("HTTP request failed") |> should.be_false
  poller.is_fatal_error("HTTP request failed: FailedToConnect(...)")
  |> should.be_false
  poller.is_fatal_error("Gateway failed: connect_failed") |> should.be_false
  poller.is_fatal_error("Unexpected status 500 from gateway/bot")
  |> should.be_false
  poller.is_fatal_error("Unexpected status 503 from gateway/bot")
  |> should.be_false
}
