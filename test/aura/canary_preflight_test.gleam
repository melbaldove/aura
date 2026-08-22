import aura/canary_preflight
import gleam/option.{None, Some}
import gleeunit/should

pub fn current_personal_life_live_preflight_requires_separate_live_authorization_test() {
  let report =
    canary_preflight.verify(canary_preflight.Preflight(
      domain_id: "domain:personal-life",
      concern_id: "concern:domain:personal-life:weekly-awareness",
      gmail_scope: "https://www.googleapis.com/auth/gmail.readonly",
      gmail_executor_available: True,
      calendar_scope: "https://www.googleapis.com/auth/calendar.readonly",
      calendar_executor_available: True,
      activation_loader_available: True,
      delivery_owner: "codex",
      delivery_target: "codex_monitor",
      allow_discord: False,
      monitor_runtime_available: True,
      monitor_id: "monitor:personal-life-canary",
      monitor_authority_grants: ["attention.read", "attention.claim"],
      monitor_outcome_grants: ["attention.acknowledge", "attention.defer"],
      trial_days: 7,
      read_only: True,
      live_authorization_ref: None,
      rollback_preserves_evidence: True,
    ))

  report.status |> should.equal("ready_for_separate_live_authorization")
  report.gaps
  |> should.equal(["explicit_live_authorization_record_required"])
}

pub fn complete_preflight_requires_exact_monitor_authority_test() {
  let base = complete_preflight()
  canary_preflight.verify(base).status
  |> should.equal("ready_for_separate_live_authorization")
  canary_preflight.verify(
    canary_preflight.Preflight(..base, monitor_authority_grants: [
      "attention.read",
    ]),
  ).gaps
  |> should.equal(["codex_monitor_authority_invalid"])
  canary_preflight.verify(
    canary_preflight.Preflight(..base, monitor_outcome_grants: [
      "attention.acknowledge",
    ]),
  ).gaps
  |> should.equal(["codex_monitor_authority_invalid"])
}

fn complete_preflight() -> canary_preflight.Preflight {
  canary_preflight.Preflight(
    domain_id: "domain:personal-life",
    concern_id: "concern:domain:personal-life:weekly-awareness",
    gmail_scope: "https://www.googleapis.com/auth/gmail.readonly",
    gmail_executor_available: True,
    calendar_scope: "https://www.googleapis.com/auth/calendar.readonly",
    calendar_executor_available: True,
    activation_loader_available: True,
    delivery_owner: "codex",
    delivery_target: "codex_monitor",
    allow_discord: False,
    monitor_runtime_available: True,
    monitor_id: "monitor:personal-life-canary",
    monitor_authority_grants: ["attention.read", "attention.claim"],
    monitor_outcome_grants: ["attention.acknowledge", "attention.defer"],
    trial_days: 7,
    read_only: True,
    live_authorization_ref: Some("authorization:future-user-confirmation"),
    rollback_preserves_evidence: True,
  )
}
