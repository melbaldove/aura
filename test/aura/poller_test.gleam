import aura/poller
import gleeunit/should

/// Backoff starts small, grows exponentially, and caps at the ceiling.
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
