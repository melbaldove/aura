import aura/clients/discord as discord_client
import gleam/string
import gleeunit/should

pub fn production_client_fields_are_functions_test() {
  // Smoke: production() returns a record with function-typed fields.
  // We call trigger_typing and assert we get a Result(Nil, String) shape back
  // (the actual HTTP call may succeed or fail at the network level, but the
  // return type proves the function exists and has the right signature).
  let client = discord_client.production("fake-token")
  let result = client.trigger_typing("")
  case result {
    Ok(nil_val) -> {
      nil_val |> should.equal(Nil)
    }
    Error(reason) -> {
      { string.length(reason) > 0 } |> should.be_true
    }
  }
}
