import aura/hook_protocol
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn parse_event_command_test() {
  let line =
    "event {\"source\":\"linkedin\",\"type\":\"collector.progress\",\"subject\":\"340 profiles\",\"external_id\":\"run-42:p340\",\"data\":{\"count\":340}}"
  let assert Ok(hook_protocol.HookEvent(source: "linkedin", ..) as cmd) =
    hook_protocol.parse(line)
  cmd.external_id |> should.equal("run-42:p340")
  cmd.subject |> should.equal("340 profiles")
}

pub fn parse_ask_command_test() {
  let line =
    "ask {\"source\":\"linkedin\",\"correlation_id\":\"run-42-ch-1\",\"target\":\"domain:one-mil-in-five\",\"text\":\"Challenge up\",\"buttons\":[\"Resolved\",\"Abort\"],\"ttl_minutes\":60}"
  let assert Ok(hook_protocol.HookAsk(..) as cmd) = hook_protocol.parse(line)
  cmd.buttons |> should.equal(["Resolved", "Abort"])
  cmd.ttl_minutes |> should.equal(60)
  cmd.rule |> should.equal("")
}

pub fn parse_ask_defaults_ttl_test() {
  let line =
    "ask {\"source\":\"linkedin\",\"correlation_id\":\"run-42-ch-1\",\"target\":\"t\",\"text\":\"hello\"}"
  let assert Ok(hook_protocol.HookAsk(..) as cmd) = hook_protocol.parse(line)
  cmd.ttl_minutes |> should.equal(60)
  cmd.buttons |> should.equal(["Resolved", "Abort"])
}

pub fn parse_rejects_pipe_in_correlation_id_test() {
  let line =
    "ask {\"source\":\"linkedin\",\"correlation_id\":\"a|b\",\"target\":\"t\",\"text\":\"hello\"}"
  hook_protocol.parse(line)
  |> should.be_error
}

pub fn parse_rejects_empty_source_test() {
  let line =
    "event {\"source\":\"\",\"type\":\"t\",\"subject\":\"s\",\"external_id\":\"e\"}"
  hook_protocol.parse(line)
  |> should.be_error
}

pub fn parse_notify_requires_target_test() {
  let line =
    "notify {\"source\":\"linkedin\",\"text\":\"hello\",\"external_id\":\"e\"}"
  hook_protocol.parse(line)
  |> should.be_error
}

pub fn parse_decision_command_test() {
  hook_protocol.parse("decision run-42-ch-1")
  |> should.equal(Ok(hook_protocol.HookDecision("run-42-ch-1")))
}

pub fn parse_unknown_command_test() {
  hook_protocol.parse("bogus run-42")
  |> should.be_error
}

pub fn provenance_prefix_test() {
  hook_protocol.apply_provenance("linkedin", "challenge", "Solve it now")
  |> should.equal("[hook:linkedin/challenge] Solve it now")
  hook_protocol.apply_provenance("linkedin", "", "Solve it now")
  |> should.equal("[hook:linkedin] Solve it now")
}

pub fn parse_notify_with_rule_field_test() {
  let line =
    "notify {\"source\":\"linkedin\",\"rule\":\"challenge\",\"target\":\"t\",\"text\":\"x\",\"external_id\":\"e\"}"
  let assert Ok(hook_protocol.HookNotify(..) as cmd1) = hook_protocol.parse(line)
  cmd1.rule |> should.equal("challenge")
  cmd1.text |> should.equal("x")

  let line2 =
    "notify {\"source\":\"linkedin\",\"target\":\"t\",\"text\":\"x\",\"external_id\":\"e\"}"
  let assert Ok(hook_protocol.HookNotify(..) as cmd2) = hook_protocol.parse(line2)
  cmd2.rule |> should.equal("")
}

pub fn custom_id_roundtrip_test() {
  let cid = hook_protocol.encode_ask_custom_id("run-42-ch-1", "Resolved")
  hook_protocol.decode_ask_custom_id(cid)
  |> should.equal(Ok(#("run-42-ch-1", "Resolved")))
}

pub fn custom_id_rejects_non_ask_test() {
  hook_protocol.decode_ask_custom_id("approve:123:sh123-456")
  |> should.be_error
}