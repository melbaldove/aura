//// Shared polling helper for async test assertions. Step handlers that
//// wait for fake state to settle (Discord events, LLM calls, etc.) use
//// `poll_until` instead of hand-rolling a tail-recursive sleep loop.

import gleam/erlang/process

const default_interval_ms = 10

/// Invoke `check` repeatedly until it returns True or `timeout_ms` elapses.
/// Sleeps `default_interval_ms` between attempts. Returns True on success,
/// False on timeout.
pub fn poll_until(check: fn() -> Bool, timeout_ms: Int) -> Bool {
  loop(check, 0, timeout_ms)
}

fn loop(check: fn() -> Bool, elapsed: Int, timeout_ms: Int) -> Bool {
  case check() {
    True -> True
    False ->
      case elapsed >= timeout_ms {
        True -> False
        False -> {
          process.sleep(default_interval_ms)
          loop(check, elapsed + default_interval_ms, timeout_ms)
        }
      }
  }
}
