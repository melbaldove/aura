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

pub fn parse_args_dispatches_cognitive_eval_test() {
  aura.parse_args_for_test(["cognitive-eval", "fixtures"])
  |> should.equal(aura.CliCtl("cognitive-eval fixtures"))
}

pub fn parse_args_dispatches_cognitive_replay_test() {
  aura.parse_args_for_test(["cognitive-replay", "labels"])
  |> should.equal(aura.CliCtl("cognitive-replay labels"))
}

pub fn parse_args_dispatches_cognitive_replay_propose_patches_test() {
  aura.parse_args_for_test(["cognitive-replay", "propose-patches"])
  |> should.equal(aura.CliCtl("cognitive-replay propose-patches"))
}

pub fn parse_args_dispatches_cognitive_improve_propose_test() {
  aura.parse_args_for_test(["cognitive-improve", "propose"])
  |> should.equal(aura.CliCtl("cognitive-improve propose"))
}

pub fn parse_args_dispatches_cognitive_delivery_probe_test() {
  aura.parse_args_for_test(["cognitive-test", "deliver-now"])
  |> should.equal(aura.CliCtl("cognitive-test deliver-now"))
}

pub fn parse_args_dispatches_cognitive_digest_flush_test() {
  aura.parse_args_for_test(["cognitive-digest", "flush"])
  |> should.equal(aura.CliCtl("cognitive-digest flush"))
}

pub fn parse_args_dispatches_cognitive_delivery_retry_test() {
  aura.parse_args_for_test(["cognitive-delivery", "retry-dead-letter"])
  |> should.equal(aura.CliCtl("cognitive-delivery retry-dead-letter"))
}

pub fn parse_args_dispatches_cognitive_label_test() {
  aura.parse_args_for_test([
    "cognitive-label",
    "ev-1",
    "false_interrupt",
    "digest",
    "too noisy",
  ])
  |> should.equal(aura.CliCtl(
    "cognitive-label ev-1 false_interrupt digest too noisy",
  ))
}

pub fn parse_args_tolerates_leading_dash_dash_test() {
  aura.parse_args_for_test(["--", "cognitive-smoke", "gmail-rel42"])
  |> should.equal(aura.CliCtl("cognitive-smoke gmail-rel42"))
}

pub fn parse_args_dispatches_start_explicitly_test() {
  aura.parse_args_for_test(["start"])
  |> should.equal(aura.CliStart)
}
