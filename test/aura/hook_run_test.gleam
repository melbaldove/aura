import aura/hook_protocol
import aura/hook_run
import aura/hook_rules
import aura/xdg
import gleam/string
import gleeunit/should

fn paths() {
  xdg.Paths(
    config: "/tmp/aura-hook-test/config",
    data: "/tmp/aura-hook-test/data",
    state: "/tmp/aura-hook-test/state",
  )
}

fn fire_ask() -> hook_rules.Fire {
  hook_rules.FireAsk(
    rule_name: "challenge",
    target: "domain:one-mil-in-five",
    text: "LinkedIn challenge: unusual activity. Solve it in the browser window.",
    buttons: ["Resolved", "Abort"],
    ttl_minutes: 60,
    correlation_id: "linkedin-challenge-1700000000",
  )
}

pub fn fires_to_commands_event_roundtrips_test() {
  let fire =
    hook_rules.FireEvent(
      rule_name: "progress",
      subject: "Collector progress: 340",
      external_id: "linkedin:progress:Collector progress: 340",
      data: "{\"line\":\"PROGRESS 340\"}",
    )
  let assert [#(line, hook_run.NonBlocking)] = hook_run.fires_to_commands([fire])
  let assert Ok(hook_protocol.HookEvent(
    source: "hook",
    subject: "Collector progress: 340",
    external_id: "linkedin:progress:Collector progress: 340",
    ..
  )) = hook_protocol.parse(line)
  Nil
}

pub fn fires_to_commands_notify_roundtrips_with_rule_test() {
  let fire =
    hook_rules.FireNotify(
      rule_name: "n",
      target: "default",
      text: "Saw: backup done",
      external_id: "src-noted-backup done",
    )
  let assert [#(
    line,
    hook_run.NonBlocking,
  )] = hook_run.fires_to_commands([fire])
  string.starts_with(line, "notify ") |> should.equal(True)
  let assert Ok(hook_protocol.HookNotify(
    source: "hook",
    rule: "n",
    target: "default",
    text: "Saw: backup done",
    external_id: "src-noted-backup done",
  )) = hook_protocol.parse(line)
  Nil
}

pub fn fires_to_commands_ask_is_blocking_and_roundtrips_test() {
  let assert [#(line, flag)] = hook_run.fires_to_commands([fire_ask()])
  flag |> should.equal(hook_run.Blocking)
  let assert Ok(hook_protocol.HookAsk(
    correlation_id: "linkedin-challenge-1700000000",
    target: "domain:one-mil-in-five",
    text: "LinkedIn challenge: unusual activity. Solve it in the browser window.",
    buttons: ["Resolved", "Abort"],
    ttl_minutes: 60,
    ..
  )) = hook_protocol.parse(line)
  Nil
}

pub fn decision_file_path_test() {
  hook_run.decision_file_path(paths(), "run-1")
  |> should.equal("/tmp/aura-hook-test/state/hooks/decisions/run-1")
}

pub fn is_retryable_ask_error_retries_socket_and_not_running_test() {
  hook_run.is_retryable_ask_error("ERROR: Aura is not running (socket not found)")
  |> should.equal(True)
  hook_run.is_retryable_ask_error("ERROR: Aura is not running (connection refused)")
  |> should.equal(True)
}

pub fn is_retryable_ask_error_stops_on_protocol_errors_test() {
  hook_run.is_retryable_ask_error("ERROR: invalid ask payload")
  |> should.equal(False)
  hook_run.is_retryable_ask_error(hook_protocol.resp_expired("cid"))
  |> should.equal(False)
  hook_run.is_retryable_ask_error("RESOLVED cid yes")
  |> should.equal(False)
}