import aura/backoff
import gleeunit/should

/// Backoff starts at `base` on attempt 0. Used by the Discord poller,
/// mcp_client reconnects, and future integrations (IMAP IDLE, Gmail) so
/// a transient outage can't burn through a supervisor's restart budget.
pub fn compute_starts_at_base_test() {
  backoff.compute(0, base: 1000, cap: 60_000) |> should.equal(1000)
}

/// Each subsequent attempt doubles the delay until capped.
pub fn compute_doubles_per_attempt_test() {
  backoff.compute(1, base: 1000, cap: 60_000) |> should.equal(2000)
  backoff.compute(2, base: 1000, cap: 60_000) |> should.equal(4000)
  backoff.compute(4, base: 1000, cap: 60_000) |> should.equal(16_000)
}

/// Large attempt numbers are clamped at the ceiling so the delay
/// never overflows or runs away.
pub fn compute_caps_at_ceiling_test() {
  backoff.compute(10, base: 1000, cap: 60_000) |> should.equal(60_000)
  backoff.compute(50, base: 5000, cap: 60_000) |> should.equal(60_000)
}

/// Negative attempts clamp to 0 so callers can pass `attempt - 1`
/// without defensive checks.
pub fn compute_negative_attempt_clamps_to_zero_test() {
  backoff.compute(-1, base: 1000, cap: 60_000) |> should.equal(1000)
  backoff.compute(-100, base: 5000, cap: 60_000) |> should.equal(5000)
}
