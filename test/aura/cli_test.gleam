import aura
import aura/ctl
import aura/google_oauth_client
import gleam/erlang/process
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn monitor_cli_preserves_machine_payloads_test() {
  aura.parse_args_for_test(["monitor", "capability", "prepare"])
  |> should.equal(aura.CliCtl("monitor capability prepare"))
  aura.parse_args_for_test(["monitor", "claim", "{\"schema_version\":1}"])
  |> should.equal(aura.CliCtl("monitor claim {\"schema_version\":1}"))
  aura.parse_args_for_test(["monitor", "outcome", "{\"schema_version\":1}"])
  |> should.equal(aura.CliCtl("monitor outcome {\"schema_version\":1}"))
}

pub fn monitor_runtime_cli_has_narrow_typed_commands_test() {
  aura.parse_args_for_test(["monitor", "run-once"])
  |> should.equal(aura.CliMonitorRunOnce)
  aura.parse_args_for_test([
    "monitor",
    "acknowledge",
    "codex:outcome:one",
    "attention:event-one",
    "attention:event-one:1:monitor:synthetic",
    "codex:task:one",
  ])
  |> should.equal(aura.CliMonitorAcknowledge(
    outcome_id: "codex:outcome:one",
    queue_id: "attention:event-one",
    lease_token: "attention:event-one:1:monitor:synthetic",
    task_ref: "codex:task:one",
  ))
  aura.parse_args_for_test([
    "monitor",
    "defer",
    "codex:outcome:two",
    "attention:event-two",
    "attention:event-two:1:monitor:synthetic",
    "1786211000000",
    "codex:task:two",
  ])
  |> should.equal(aura.CliMonitorDefer(
    outcome_id: "codex:outcome:two",
    queue_id: "attention:event-two",
    lease_token: "attention:event-two:1:monitor:synthetic",
    defer_until: 1_786_211_000_000,
    task_ref: "codex:task:two",
  ))
  aura.parse_args_for_test(["monitor", "run-once", "unexpected"])
  |> should.equal(aura.CliInvalid("Invalid monitor command"))
}

pub fn wait_for_supervisor_exit_returns_after_forced_stop_test() {
  let pid = process.spawn_unlinked(fn() { process.sleep_forever() })
  let returned = process.new_subject()
  process.spawn(fn() {
    aura.wait_for_supervisor_exit(pid)
    process.send(returned, Nil)
  })
  process.kill(pid)
  process.receive(returned, 1000) |> should.equal(Ok(Nil))
}

pub fn root_supervisor_failure_uses_error_exit_code_test() {
  aura.service_failure_exit_code |> should.equal(1)
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

pub fn retired_gmail_oauth_command_does_not_start_aura_test() {
  aura.parse_args_for_test(["oauth", "gmail", "fixture@example.test"])
  |> should.equal(aura.CliInvalid(
    "The legacy Gmail OAuth command is retired. Gmail REST authorization is disabled until an approved read-only activation is available.",
  ))
}

pub fn google_oauth_client_commands_route_without_secret_arguments_test() {
  aura.parse_args_for_test([
    "oauth",
    "google-client",
    "install",
    "--connector",
    "gmail",
    "--source",
    "/tmp/client.json",
    "--sha256",
    string.repeat("a", 64),
  ])
  |> should.equal(aura.CliCtl(
    "oauth google-client install "
    <> google_oauth_client.encode_install_command(
      "gmail",
      "/tmp/client.json",
      string.repeat("a", 64),
    ),
  ))
  aura.parse_args_for_test([
    "oauth",
    "google-client-set",
    "create",
    "--gmail",
    "oauth-client:gmail:sha256:g",
    "--calendar",
    "oauth-client:calendar:sha256:c",
  ])
  |> should.equal(aura.CliCtl(
    "oauth google-client-set create "
    <> google_oauth_client.encode_client_set_command(
      "oauth-client:gmail:sha256:g",
      "oauth-client:calendar:sha256:c",
    ),
  ))
}

pub fn google_readonly_control_commands_have_narrow_arguments_test() {
  aura.parse_args_for_test([
    "oauth",
    "start",
    "--connector",
    "gmail",
    "--preparation",
    "preparation:one",
    "--configuration",
    "configuration:gmail",
    "--client",
    "oauth-client:gmail:sha256:abc",
  ])
  |> should.equal(aura.CliCtl(
    "oauth start gmail preparation:one configuration:gmail oauth-client:gmail:sha256:abc",
  ))
  aura.parse_args_for_test([
    "oauth",
    "status",
    "--session",
    "oauth-session:one",
  ])
  |> should.equal(aura.CliCtl("oauth status oauth-session:one"))
  aura.parse_args_for_test([
    "connector-read",
    "run-once",
    "--authorization",
    "authorization:one",
    "--connector",
    "calendar",
  ])
  |> should.equal(aura.CliCtl(
    "connector-read run-once authorization:one calendar",
  ))
}

pub fn google_readonly_control_commands_reject_overrides_and_legacy_terms_test() {
  aura.parse_args_for_test([
    "connector-read",
    "run-once",
    "--authorization",
    "authorization:one",
    "--connector",
    "gmail",
    "--url",
    "https://example.test",
  ])
  |> should.equal(aura.CliInvalid("Invalid connector read command"))
  aura.parse_args_for_test([
    "oauth",
    "start",
    "--connector",
    "imap",
    "--preparation",
    "preparation:one",
    "--configuration",
    "configuration:gmail",
    "--client",
    "oauth-client:gmail:sha256:abc",
  ])
  |> should.equal(aura.CliInvalid("Invalid Google OAuth command"))
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
  aura.parse_args_for_test([
    "hook",
    "run",
    "--rules",
    "x.toml",
    "--",
    "python",
    "c.py",
  ])
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

pub fn parse_generic_evidence_and_tool_result_submission_test() {
  aura.parse_args_for_test(["evidence", "submit", "{\"schema_version\":1}"])
  |> should.equal(aura.CliCtl("evidence submit {\"schema_version\":1}"))
  aura.parse_args_for_test(["tool-result", "submit", "{\"schema_version\":1}"])
  |> should.equal(aura.CliCtl("tool-result submit {\"schema_version\":1}"))
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

pub fn parse_structured_mutation_passthrough_test() {
  aura.parse_args_for_test(["mutate", "{\"schema_version\":1}"])
  |> should.equal(aura.CliCtl("mutate {\"schema_version\":1}"))
}

pub fn parse_explicit_legacy_migrations_test() {
  aura.parse_args_for_test(["domain-migrate", "personal-os", "migration-key"])
  |> should.equal(aura.CliCtl("domain-migrate personal-os migration-key"))
  aura.parse_args_for_test([
    "concern-migrate",
    "monthly-close",
    "personal-life",
    "concern-migration-key",
  ])
  |> should.equal(aura.CliCtl(
    "concern-migrate monthly-close personal-life concern-migration-key",
  ))
}
