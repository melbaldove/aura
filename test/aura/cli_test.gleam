import aura
import aura/ctl
import gleam/string
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

pub fn build_hook_event_maps_fields_test() {
  let ev =
    ctl.build_hook_event(
      "linkedin",
      "hook.event",
      "challenge",
      "lid-9",
      "{\"n\":1}",
      "ev-1-2",
      1000,
    )
  ev.source |> should.equal("linkedin")
  ev.id |> should.equal("ev-1-2")
  ev.type_ |> should.equal("hook.event")
  ev.external_id |> should.equal("lid-9")
  ev.time_ms |> should.equal(1000)
}

pub fn build_external_ask_maps_hook_fields_test() {
  let ask =
    ctl.build_external_ask(
      "linkedin",
      "c1",
      "default",
      "Solve it",
      ["Resolved", "Abort"],
      2000,
    )
  ask.id |> should.equal("c1")
  ask.source |> should.equal("linkedin")
  ask.channel_id |> should.equal("default")
  ask.text |> should.equal("Solve it")
  ask.status |> should.equal("pending")
  ask.buttons_json |> string.contains("Resolved") |> should.be_true
  ask.requested_at_ms |> should.equal(2000)
}

pub fn parse_hook_run_test() {
  aura.parse_args_for_test(["hook", "run", "--rules", "x.toml", "--", "python", "c.py"])
  |> should.equal(aura.CliHookRun("x.toml", "python c.py"))
}

pub fn parse_hook_passthrough_test() {
  aura.parse_args_for_test(["decision", "run-42-ch-1"])
  |> should.equal(aura.CliCtl("decision run-42-ch-1"))
}

pub fn parse_event_passthrough_test() {
  aura.parse_args_for_test(["event", "{\"source\":\"x\"}"])
  |> should.equal(aura.CliCtl("event {\"source\":\"x\"}"))
}

pub fn parse_notify_passthrough_test() {
  aura.parse_args_for_test(["notify", "{\"source\":\"x\"}"])
  |> should.equal(aura.CliCtl("notify {\"source\":\"x\"}"))
}

pub fn parse_ask_passthrough_test() {
  aura.parse_args_for_test(["ask", "{\"source\":\"x\"}"])
  |> should.equal(aura.CliCtl("ask {\"source\":\"x\"}"))
}

pub fn parse_asks_passthrough_test() {
  aura.parse_args_for_test(["asks"])
  |> should.equal(aura.CliCtl("asks"))
}

pub fn parse_hooks_passthrough_test() {
  aura.parse_args_for_test(["hooks"])
  |> should.equal(aura.CliCtl("hooks"))
}
