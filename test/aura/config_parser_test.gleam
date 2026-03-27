import aura/config_parser
import gleeunit/should

pub fn resolve_env_var_test() {
  set_env("TEST_AURA_TOKEN", "secret123")

  config_parser.resolve_env_string("${TEST_AURA_TOKEN}")
  |> should.equal(Ok("secret123"))

  config_parser.resolve_env_string("plain-string")
  |> should.equal(Ok("plain-string"))

  config_parser.resolve_env_string("${NONEXISTENT_VAR}")
  |> should.be_error
}

fn set_env(key: String, value: String) -> Nil {
  set_env_ffi(key, value)
  Nil
}

@external(erlang, "aura_test_ffi", "set_env")
fn set_env_ffi(key: String, value: String) -> Bool
