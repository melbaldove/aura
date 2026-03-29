import aura/prompt
import gleeunit/should

pub fn module_compiles_test() {
  // Verify the module is importable and functions exist
  // Can't test stdin interactively in automated tests
  let _ = prompt.ask
  let _ = prompt.ask_secret
  let _ = prompt.choose
  should.be_true(True)
}
