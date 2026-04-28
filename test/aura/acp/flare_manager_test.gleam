import aura/acp/flare_manager
import aura/acp/provider
import aura/acp/transport
import aura/acp/types
import gleam/option.{type Option, None}
import gleeunit/should

// ---------------------------------------------------------------------------
// status_to_string / status_from_string roundtrip
// ---------------------------------------------------------------------------

pub fn status_active_roundtrip_test() {
  flare_manager.Active
  |> flare_manager.status_to_string
  |> flare_manager.status_from_string
  |> should.equal(flare_manager.Active)
}

pub fn status_parked_roundtrip_test() {
  flare_manager.Parked
  |> flare_manager.status_to_string
  |> flare_manager.status_from_string
  |> should.equal(flare_manager.Parked)
}

pub fn status_archived_roundtrip_test() {
  flare_manager.Archived
  |> flare_manager.status_to_string
  |> flare_manager.status_from_string
  |> should.equal(flare_manager.Archived)
}

pub fn status_failed_with_reason_roundtrip_test() {
  flare_manager.Failed("timed_out")
  |> flare_manager.status_to_string
  |> flare_manager.status_from_string
  |> should.equal(flare_manager.Failed("timed_out"))
}

pub fn status_failed_with_complex_reason_roundtrip_test() {
  flare_manager.Failed("killed:by:user")
  |> flare_manager.status_to_string
  |> flare_manager.status_from_string
  |> should.equal(flare_manager.Failed("killed:by:user"))
}

// ---------------------------------------------------------------------------
// status_to_string output
// ---------------------------------------------------------------------------

pub fn status_to_string_active_test() {
  flare_manager.status_to_string(flare_manager.Active)
  |> should.equal("active")
}

pub fn status_to_string_parked_test() {
  flare_manager.status_to_string(flare_manager.Parked)
  |> should.equal("parked")
}

pub fn status_to_string_archived_test() {
  flare_manager.status_to_string(flare_manager.Archived)
  |> should.equal("archived")
}

pub fn status_to_string_failed_test() {
  flare_manager.status_to_string(flare_manager.Failed("oops"))
  |> should.equal("failed:oops")
}

// ---------------------------------------------------------------------------
// status_from_string edge cases
// ---------------------------------------------------------------------------

pub fn status_from_string_active_test() {
  flare_manager.status_from_string("active")
  |> should.equal(flare_manager.Active)
}

pub fn status_from_string_parked_test() {
  flare_manager.status_from_string("parked")
  |> should.equal(flare_manager.Parked)
}

pub fn status_from_string_archived_test() {
  flare_manager.status_from_string("archived")
  |> should.equal(flare_manager.Archived)
}

pub fn status_from_string_failed_with_reason_test() {
  flare_manager.status_from_string("failed:connection refused")
  |> should.equal(flare_manager.Failed("connection refused"))
}

pub fn status_from_string_plain_failed_test() {
  // "failed" without a colon should be treated as Failed with "failed" as reason
  flare_manager.status_from_string("failed")
  |> should.equal(flare_manager.Failed("failed"))
}

pub fn status_from_string_unknown_string_test() {
  // Unknown strings become Failed with the full string as reason
  flare_manager.status_from_string("something_weird")
  |> should.equal(flare_manager.Failed("something_weird"))
}

pub fn status_from_string_empty_failed_reason_test() {
  // "failed:" with empty reason
  flare_manager.status_from_string("failed:")
  |> should.equal(flare_manager.Failed(""))
}

// ---------------------------------------------------------------------------
// resolve_prompt_action — policy for flare prompt tool action
// ---------------------------------------------------------------------------

pub fn resolve_prompt_active_sends_to_live_test() {
  flare_manager.resolve_prompt_action(
    flare_manager.Active,
    "f-123",
    "acp-cm2-f-123",
    "do the thing",
  )
  |> should.equal(flare_manager.SendToLive("acp-cm2-f-123"))
}

pub fn resolve_prompt_parked_rekindles_test() {
  flare_manager.resolve_prompt_action(
    flare_manager.Parked,
    "f-123",
    "",
    "pick it back up",
  )
  |> should.equal(flare_manager.RekindleFlare("f-123", "pick it back up"))
}

pub fn resolve_prompt_failed_rejects_test() {
  let action =
    flare_manager.resolve_prompt_action(
      flare_manager.Failed("killed"),
      "f-123",
      "",
      "please continue",
    )
  case action {
    flare_manager.RejectPrompt(_) -> Nil
    _ -> should.fail()
  }
}

pub fn resolve_prompt_archived_rejects_test() {
  let action =
    flare_manager.resolve_prompt_action(
      flare_manager.Archived,
      "f-123",
      "",
      "hello",
    )
  case action {
    flare_manager.RejectPrompt(_) -> Nil
    _ -> should.fail()
  }
}

// ---------------------------------------------------------------------------
// execution persistence + recovery helpers
// ---------------------------------------------------------------------------

pub fn execution_roundtrip_preserves_provider_binary_worktree_and_timeout_test() {
  let execution =
    flare_manager.FlareExecution(
      provider: "generic",
      binary: "codex",
      worktree: False,
      timeout_ms: 45 * 60_000,
      transport: flare_manager.HttpTransport(
        server_url: "https://acp.example.test",
        agent_name: "codex",
      ),
    )

  let json = flare_manager.execution_to_json(execution)

  flare_manager.execution_from_json(json)
  |> should.equal(Ok(execution))
}

pub fn execution_from_legacy_payload_uses_defaults_test() {
  flare_manager.execution_from_json("{}")
  |> should.equal(Ok(flare_manager.default_execution()))
}

pub fn execution_from_malformed_payload_fails_test() {
  flare_manager.execution_from_json("{not-json")
  |> should.be_error
}

pub fn control_handle_for_flare_recovers_http_handle_from_session_id_test() {
  let flare =
    sample_flare(
      session_id: "run-123",
      execution_json: "{}",
      handle: None,
      workspace: "/tmp/repo",
    )

  flare_manager.control_handle_for_flare(
    transport.Http("https://example.test", "codex"),
    flare,
  )
  |> should.equal(Ok(transport.HttpHandle(run_id: "run-123")))
}

pub fn task_spec_for_rekindle_preserves_execution_settings_test() {
  let execution_json =
    flare_manager.execution_to_json(flare_manager.FlareExecution(
      provider: "generic",
      binary: "codex",
      worktree: False,
      timeout_ms: 45 * 60_000,
      transport: flare_manager.LegacyTransport,
    ))
  let flare =
    sample_flare(
      session_id: "run-123",
      execution_json: execution_json,
      handle: None,
      workspace: "/tmp/repo",
    )

  flare_manager.task_spec_for_rekindle(flare, "continue")
  |> should.equal(
    Ok(types.TaskSpec(
      id: "f-123",
      domain: "demo",
      prompt: "continue",
      cwd: "/tmp/repo",
      timeout_ms: 45 * 60_000,
      acceptance_criteria: [],
      provider: provider.Generic("codex"),
      worktree: False,
    )),
  )
}

pub fn task_spec_for_rekindle_uses_legacy_defaults_test() {
  let flare =
    sample_flare(
      session_id: "run-123",
      execution_json: "{}",
      handle: None,
      workspace: "",
    )

  flare_manager.task_spec_for_rekindle(flare, "continue")
  |> should.equal(
    Ok(types.TaskSpec(
      id: "f-123",
      domain: "demo",
      prompt: "continue",
      cwd: ".",
      timeout_ms: 30 * 60_000,
      acceptance_criteria: [],
      provider: provider.ClaudeCode,
      worktree: True,
    )),
  )
}

pub fn control_session_for_flare_uses_persisted_http_transport_test() {
  let execution_json =
    flare_manager.execution_to_json(flare_manager.FlareExecution(
      provider: "generic",
      binary: "codex",
      worktree: False,
      timeout_ms: 45 * 60_000,
      transport: flare_manager.HttpTransport(
        server_url: "https://original.example.test",
        agent_name: "codex",
      ),
    ))
  let flare =
    sample_flare(
      session_id: "run-123",
      execution_json: execution_json,
      handle: None,
      workspace: "/tmp/repo",
    )

  flare_manager.control_session_for_flare(transport.Tmux, flare)
  |> should.equal(
    Ok(flare_manager.ControlSession(
      transport: transport.Http("https://original.example.test", "codex"),
      handle: transport.HttpHandle(run_id: "run-123"),
    )),
  )
}

fn sample_flare(
  session_id session_id: String,
  execution_json execution_json: String,
  handle handle: Option(transport.SessionHandle),
  workspace workspace: String,
) -> flare_manager.FlareRecord {
  flare_manager.FlareRecord(
    id: "f-123",
    label: "demo",
    status: flare_manager.Active,
    domain: "demo",
    thread_id: "thread-1",
    original_prompt: "fix it",
    execution_json: execution_json,
    triggers_json: "{}",
    tools_json: "{}",
    workspace: workspace,
    session_id: session_id,
    session_name: "demo-f-123",
    handle: handle,
    started_at_ms: 0,
    updated_at_ms: 0,
    awaiting_response: False,
  )
}
