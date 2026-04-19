import gleam/string
import gleeunit/should
import test_harness

pub fn fresh_system_constructs_without_panic_test() {
  let system = test_harness.fresh_system()
  // Destructure must succeed (compile-time shape check)
  let _ = case system {
    test_harness.TestSystem(..) -> Nil
  }
  // Meaningful assertion: db_path points at /tmp/aura-test-
  string.contains(system.db_path, "/tmp/aura-test-") |> should.be_true
  test_harness.teardown(system)
}
