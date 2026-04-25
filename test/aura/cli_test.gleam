import aura
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn parse_args_dispatches_cognitive_smoke_test() {
  aura.parse_args_for_test(["cognitive-smoke", "gmail-rel42"])
  |> should.equal(aura.CliCtl("cognitive-smoke gmail-rel42"))
}

pub fn parse_args_tolerates_leading_dash_dash_test() {
  aura.parse_args_for_test(["--", "cognitive-smoke", "gmail-rel42"])
  |> should.equal(aura.CliCtl("cognitive-smoke gmail-rel42"))
}

pub fn parse_args_dispatches_start_explicitly_test() {
  aura.parse_args_for_test(["start"])
  |> should.equal(aura.CliStart)
}
