import aura/acp/flare_manager
import aura/acp/monitor as acp_monitor
import aura/acp/provider
import aura/acp/transport
import aura/acp/types
import aura/db
import aura/test_helpers
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import gleeunit/should
import poll
import simplifile
import sqlight

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
// work_state_to_string / work_state_from_string roundtrip
// ---------------------------------------------------------------------------

pub fn work_state_serialization_roundtrip_test() {
  let cases = [
    #(flare_manager.Queued, "queued"),
    #(flare_manager.Running, "running"),
    #(flare_manager.Waiting, "waiting"),
    #(flare_manager.Paused, "paused"),
    #(flare_manager.Interrupted, "interrupted"),
    #(flare_manager.Completed, "completed"),
    #(flare_manager.Cancelled, "cancelled"),
    #(flare_manager.WorkStateFailed("boom"), "failed:boom"),
  ]
  list.each(cases, fn(c) {
    let #(state, expected) = c
    flare_manager.work_state_to_string(state) |> should.equal(expected)
    flare_manager.work_state_from_string(expected)
    |> should.equal(Ok(state))
  })
}

pub fn work_state_from_string_invalid_inputs_test() {
  flare_manager.work_state_from_string("nope")
  |> should.equal(Error(Nil))
  flare_manager.work_state_from_string("failed")
  |> should.equal(Error(Nil))
  flare_manager.work_state_from_string("failed:")
  |> should.equal(Ok(flare_manager.WorkStateFailed("")))
}

// ---------------------------------------------------------------------------
// executor_kind_to_string / executor_kind_from_string
// ---------------------------------------------------------------------------

pub fn executor_kind_serialization_roundtrip_test() {
  flare_manager.executor_kind_to_string(flare_manager.Acp)
  |> should.equal("acp")
  flare_manager.executor_kind_to_string(flare_manager.Aura)
  |> should.equal("aura")
  flare_manager.executor_kind_from_string("acp")
  |> should.equal(Ok(flare_manager.Acp))
  flare_manager.executor_kind_from_string("aura")
  |> should.equal(Ok(flare_manager.Aura))
  flare_manager.executor_kind_from_string("nope")
  |> should.equal(Error(Nil))
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

pub fn turn_completed_parks_flare_and_suppresses_stale_monitor_events_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let events = process.new_subject()
  let assert Ok(subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(event) { process.send(events, event) },
      transport.Tmux,
      db_subject,
    )
  let session_name = "acp-cm2-f-handback"
  let assert Ok(_) =
    db.upsert_flare(
      db_subject,
      db.StoredFlare(
        id: "f-handback",
        label: "handback",
        status: "active",
        domain: "cm2",
        thread_id: "thread-1",
        original_prompt: "do work",
        execution: "{}",
        triggers: "[]",
        tools: "[]",
        workspace: "",
        session_id: "run-1",
        created_at_ms: 0,
        updated_at_ms: 0,
        dispatch_id: "",
        executor_kind: "acp",
        capability_manifest: "{}",
        context_manifest: "{}",
        authority_boundary: "{}",
        final_result: "",
        final_proof: "",
        archived: False,
      ),
    )
  flare_manager.register_for_test(
    subject,
    flare_manager.FlareRecord(
      id: "f-handback",
      label: "handback",
      status: flare_manager.Active,
      domain: "cm2",
      thread_id: "thread-1",
      original_prompt: "do work",
      execution_json: "{}",
      triggers_json: "[]",
      tools_json: "[]",
      workspace: "",
      session_id: "run-1",
      session_name: session_name,
      handle: None,
      started_at_ms: 0,
      updated_at_ms: 0,
      awaiting_response: True,
      work_state: flare_manager.Running,
      executor_kind: flare_manager.Acp,
      dispatch_id: "",
      capability_manifest: "{}",
      context_manifest: "{}",
      authority_boundary: "{}",
      final_result: "",
      final_proof: "",
      archived: False,
    ),
  )

  process.send(
    subject,
    flare_manager.MonitorEvent(acp_monitor.AcpTurnCompleted(
      session_name,
      "cm2",
      "Agent's response:\ndone",
    )),
  )

  let assert Ok(acp_monitor.AcpTurnCompleted(_, _, _)) =
    process.receive(events, 1000)

  poll.poll_until(
    fn() {
      case flare_manager.get_flare(subject, "f-handback") {
        Ok(flare) -> flare.status == flare_manager.Parked
        Error(_) -> False
      }
    },
    1000,
  )
  |> should.be_true

  let assert Ok(flares) = db.load_flares(db_subject, False)
  let assert Ok(stored) =
    list.find(flares, fn(flare) { flare.id == "f-handback" })
  stored.status |> should.equal("parked")
  let assert Ok(transition_events) =
    db.list_flare_events(db_subject, "f-handback")
  transition_events
  |> list.any(fn(event) { event.event_type == "flare_parked" })
  |> should.be_true

  process.send(
    subject,
    flare_manager.MonitorEvent(acp_monitor.AcpAlert(
      session_name,
      "cm2",
      types.Blocked,
      "Status: Blocked\nCurrent: stale monitor update",
    )),
  )
  case process.receive(events, 100) {
    Ok(_) -> should.fail()
    Error(_) -> should.be_true(True)
  }
}

pub fn handback_audit_failure_does_not_park_flare_test() {
  let path =
    "/tmp/aura-flare-handback-audit-" <> test_helpers.random_suffix() <> ".db"
  let _ = simplifile.delete(path)
  let assert Ok(db_subject) = db.start(path)
  let events = process.new_subject()
  let assert Ok(subject) =
    flare_manager.start(
      1,
      "synthetic-monitor",
      fn(event) { process.send(events, event) },
      transport.Tmux,
      db_subject,
    )
  let flare =
    sample_flare(
      session_id: "run-audit-failure",
      execution_json: "{}",
      handle: None,
      workspace: "",
    )
  let assert Ok(Nil) =
    db.upsert_flare(
      db_subject,
      db.StoredFlare(
        id: flare.id,
        label: flare.label,
        status: "active",
        domain: flare.domain,
        thread_id: flare.thread_id,
        original_prompt: flare.original_prompt,
        execution: flare.execution_json,
        triggers: flare.triggers_json,
        tools: flare.tools_json,
        workspace: flare.workspace,
        session_id: flare.session_id,
        created_at_ms: 0,
        updated_at_ms: 0,
        dispatch_id: "",
        executor_kind: "acp",
        capability_manifest: "{}",
        context_manifest: "{}",
        authority_boundary: "{}",
        final_result: "",
        final_proof: "",
        archived: False,
      ),
    )
  flare_manager.register_for_test(subject, flare)
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) = sqlight.exec("DROP TABLE flare_events", on: conn)

  process.send(
    subject,
    flare_manager.MonitorEvent(acp_monitor.AcpTurnCompleted(
      flare.session_name,
      flare.domain,
      "synthetic outcome",
    )),
  )

  let assert Ok(acp_monitor.AcpFailed(_, _, reason)) =
    process.receive(events, 1000)
  reason |> string.contains("could not persist") |> should.be_true
  let assert Ok(current) = flare_manager.get_flare(subject, flare.id)
  current.status |> should.equal(flare_manager.Active)
  let assert Ok([stored]) = db.load_flares(db_subject, False)
  stored.status |> should.equal("active")

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete(path)
  Nil
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
    work_state: flare_manager.Running,
    executor_kind: flare_manager.Acp,
    dispatch_id: "",
    capability_manifest: "{}",
    context_manifest: "{}",
    authority_boundary: "{}",
    final_result: "",
    final_proof: "",
    archived: False,
  )
}

pub fn ignite_persists_neutral_fields_and_creation_event_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_) { Nil },
      transport.Tmux,
      db_subject,
    )
  let assert Ok(flare_id) =
    flare_manager.ignite(
      subject,
      "label",
      "domain",
      "thread",
      "prompt",
      flare_manager.execution_to_json(flare_manager.FlareExecution(
        provider: "p",
        binary: "b",
        worktree: True,
        timeout_ms: 1,
        transport: flare_manager.LegacyTransport,
      )),
      "{}",
      "{}",
      "cwd",
    )
  let assert Ok(flare) = flare_manager.get_flare(subject, flare_id)
  flare.executor_kind |> should.equal(flare_manager.Acp)
  flare.dispatch_id |> should.equal("")
  flare.work_state |> should.equal(flare_manager.Queued)
  let assert Ok(events) = db.list_flare_events(db_subject, flare_id)
  list.length(events) |> should.equal(1)
  let assert Ok(event) = list.first(events)
  event.event_type |> should.equal("flare_created")
}

// ---------------------------------------------------------------------------
// startup backfill — legacy flares become ACP attempt records
// ---------------------------------------------------------------------------

pub fn startup_backfills_attempt_records_for_legacy_flares_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  // Archived legacy flares also need durable attempt history.
  let assert Ok(Nil) =
    db.upsert_flare(
      db_subject,
      db.StoredFlare(
        id: "legacy-1",
        label: "old",
        status: "archived",
        domain: "d",
        thread_id: "t",
        original_prompt: "p",
        execution: "{\"provider\":\"claude-code\",\"binary\":\"claude\",\"worktree\":true,\"timeout_ms\":60000,\"transport\":\"tmux\"}",
        triggers: "{}",
        tools: "{}",
        workspace: "repos/x",
        session_id: "run-123",
        created_at_ms: 1,
        updated_at_ms: 2,
        dispatch_id: "",
        executor_kind: "acp",
        capability_manifest: "{}",
        context_manifest: "{}",
        authority_boundary: "{}",
        final_result: "",
        final_proof: "",
        archived: True,
      ),
    )
  let assert Ok(_subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_) { Nil },
      transport.Tmux,
      db_subject,
    )
  let assert Ok(attempts) = db.list_flare_attempts(db_subject, "legacy-1")
  case attempts {
    [attempt] -> {
      attempt.executor_kind |> should.equal("acp")
      attempt.status |> should.equal("completed")
      attempt.ended_at_ms |> should.equal(2)
    }
    _ -> should.fail()
  }
  let assert Ok(events) = db.list_flare_events(db_subject, "legacy-1")
  let backfilled =
    list.filter(events, fn(event) { event.event_type == "attempt_backfilled" })
  list.length(backfilled) |> should.equal(1)
}

pub fn manual_park_and_archive_write_audit_events_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_) { Nil },
      transport.Tmux,
      db_subject,
    )
  let assert Ok(park_id) =
    flare_manager.ignite(
      subject,
      "park",
      "domain",
      "thread",
      "prompt",
      "{}",
      "{}",
      "{}",
      "",
    )
  let assert Ok(Nil) = flare_manager.park(subject, park_id, "{}")
  let assert Ok(park_events) = db.list_flare_events(db_subject, park_id)
  park_events
  |> list.any(fn(event) { event.event_type == "flare_parked" })
  |> should.be_true

  let assert Ok(archive_id) =
    flare_manager.ignite(
      subject,
      "archive",
      "domain",
      "thread",
      "prompt",
      "{}",
      "{}",
      "{}",
      "",
    )
  let assert Ok(Nil) = flare_manager.archive(subject, archive_id)
  let assert Ok(archive_events) = db.list_flare_events(db_subject, archive_id)
  archive_events
  |> list.any(fn(event) { event.event_type == "flare_archived" })
  |> should.be_true
}

pub fn manual_transition_audit_failure_prevents_terminal_state_test() {
  let path =
    "/tmp/aura-flare-manual-audit-" <> test_helpers.random_suffix() <> ".db"
  let _ = simplifile.delete(path)
  let assert Ok(db_subject) = db.start(path)
  let assert Ok(subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_) { Nil },
      transport.Tmux,
      db_subject,
    )
  let assert Ok(flare_id) =
    flare_manager.ignite(
      subject,
      "archive",
      "domain",
      "thread",
      "prompt",
      "{}",
      "{}",
      "{}",
      "",
    )
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) = sqlight.exec("DROP TABLE flare_events", on: conn)

  flare_manager.archive(subject, flare_id) |> should.be_error
  let assert Ok(current) = flare_manager.get_flare(subject, flare_id)
  let is_archived = current.status == flare_manager.Archived
  is_archived |> should.be_false
  let assert Ok([stored]) = db.load_flares(db_subject, False)
  stored.status |> should.equal("active")

  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete(path)
}

pub fn startup_does_not_duplicate_attempts_for_flares_with_existing_rows_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(Nil) =
    db.upsert_flare(
      db_subject,
      db.StoredFlare(
        id: "legacy-2",
        label: "old",
        status: "parked",
        domain: "d",
        thread_id: "t",
        original_prompt: "p",
        execution: "{}",
        triggers: "{}",
        tools: "{}",
        workspace: "repos/x",
        session_id: "run-456",
        created_at_ms: 1,
        updated_at_ms: 2,
        dispatch_id: "",
        executor_kind: "acp",
        capability_manifest: "{}",
        context_manifest: "{}",
        authority_boundary: "{}",
        final_result: "",
        final_proof: "",
        archived: False,
      ),
    )
  let assert Ok(_) =
    db.create_flare_attempt(
      db_subject,
      db.StoredFlareAttempt(
        id: 0,
        flare_id: "legacy-2",
        executor_kind: "acp",
        status: "running",
        runtime_reference: "run-456",
        checkpoint: "",
        started_at_ms: 1,
        ended_at_ms: 0,
        failure: "",
      ),
    )
  let assert Ok(_subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_) { Nil },
      transport.Tmux,
      db_subject,
    )
  let assert Ok(attempts) = db.list_flare_attempts(db_subject, "legacy-2")
  list.length(attempts) |> should.equal(1)
}

pub fn recovery_audit_failure_prevents_manager_start_test() {
  let path =
    "/tmp/aura-flare-recovery-audit-" <> test_helpers.random_suffix() <> ".db"
  let _ = simplifile.delete(path)
  let assert Ok(db_subject) = db.start(path)
  let assert Ok(Nil) =
    db.upsert_flare(
      db_subject,
      db.StoredFlare(
        id: "invalid-active",
        label: "invalid",
        status: "active",
        domain: "d",
        thread_id: "t",
        original_prompt: "p",
        execution: "{invalid",
        triggers: "{}",
        tools: "{}",
        workspace: "",
        session_id: "",
        created_at_ms: 1,
        updated_at_ms: 2,
        dispatch_id: "",
        executor_kind: "acp",
        capability_manifest: "{}",
        context_manifest: "{}",
        authority_boundary: "{}",
        final_result: "",
        final_proof: "",
        archived: False,
      ),
    )
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) = sqlight.exec("DROP TABLE flare_events", on: conn)

  flare_manager.start(
    1,
    "zai/glm-5-turbo",
    fn(_) { Nil },
    transport.Tmux,
    db_subject,
  )
  |> should.be_error

  let assert Ok([stored]) = db.load_flares(db_subject, False)
  stored.status |> should.equal("active")
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete(path)
}

pub fn ignite_with_dispatch_id_threads_grouping_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(subject) =
    flare_manager.start(
      1,
      "zai/glm-5-turbo",
      fn(_) { Nil },
      transport.Tmux,
      db_subject,
    )
  let assert Ok(flare_id) =
    flare_manager.ignite_with_dispatch_id(
      subject,
      "label",
      "domain",
      "thread",
      "prompt",
      "group-42",
      "{}",
      "{}",
      "{}",
      "cwd",
    )
  let assert Ok(flare) = flare_manager.get_flare(subject, flare_id)
  flare.dispatch_id |> should.equal("group-42")
}
