import aura/poller
import gleeunit/should

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
