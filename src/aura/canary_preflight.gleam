import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A source-grounded capability snapshot for one future canary activation.
pub type Preflight {
  Preflight(
    domain_id: String,
    concern_id: String,
    gmail_scope: String,
    gmail_executor_available: Bool,
    calendar_scope: String,
    calendar_executor_available: Bool,
    activation_loader_available: Bool,
    delivery_owner: String,
    delivery_target: String,
    allow_discord: Bool,
    monitor_runtime_available: Bool,
    monitor_id: String,
    monitor_authority_grants: List(String),
    monitor_outcome_grants: List(String),
    trial_days: Int,
    read_only: Bool,
    live_authorization_ref: Option(String),
    rollback_preserves_evidence: Bool,
  )
}

/// The local result of a preflight check. It does not authorize activation.
pub type Report {
  Report(status: String, gaps: List(String))
}

/// Verify the controls and capabilities required before live authorization.
pub fn verify(value: Preflight) -> Report {
  let gaps = []
  let gaps =
    add_unless(
      gaps,
      value.domain_id == "domain:personal-life"
        && string.starts_with(
        value.concern_id,
        "concern:" <> value.domain_id <> ":",
      ),
      "personal_life_selection_invalid",
    )
  let gaps =
    add_unless(
      gaps,
      value.gmail_executor_available
        && value.gmail_scope == "https://www.googleapis.com/auth/gmail.readonly",
      "gmail_read_only_scope_unavailable",
    )
  let gaps =
    add_unless(
      gaps,
      value.calendar_executor_available
        && value.calendar_scope
        == "https://www.googleapis.com/auth/calendar.readonly",
      "calendar_read_only_executor_unavailable",
    )
  let gaps =
    add_unless(
      gaps,
      value.activation_loader_available,
      "connector_activation_loader_unavailable",
    )
  let gaps =
    add_unless(
      gaps,
      value.delivery_owner == "codex"
        && value.delivery_target == "codex_monitor"
        && !value.allow_discord,
      "no_discord_delivery_boundary_invalid",
    )
  let gaps =
    add_unless(
      gaps,
      value.monitor_runtime_available,
      "codex_monitor_runtime_unavailable",
    )
  let monitor_authority_valid =
    value.monitor_id != ""
    && list.length(value.monitor_authority_grants) == 2
    && list.contains(value.monitor_authority_grants, "attention.read")
    && list.contains(value.monitor_authority_grants, "attention.claim")
    && list.length(value.monitor_outcome_grants) == 2
    && list.contains(value.monitor_outcome_grants, "attention.acknowledge")
    && list.contains(value.monitor_outcome_grants, "attention.defer")
  let gaps = case value.monitor_runtime_available {
    True ->
      add_unless(
        gaps,
        monitor_authority_valid,
        "codex_monitor_authority_invalid",
      )
    False -> gaps
  }
  let gaps =
    add_unless(
      gaps,
      value.trial_days == 7 && value.read_only,
      "one_week_read_only_trial_invalid",
    )
  let gaps =
    add_unless(
      gaps,
      value.rollback_preserves_evidence,
      "non_destructive_rollback_invalid",
    )
  let gaps =
    add_unless(
      gaps,
      case value.live_authorization_ref {
        Some(reference) -> string.trim(reference) != ""
        None -> False
      },
      "explicit_live_authorization_record_required",
    )
  let only_live_authorization_remains =
    gaps == ["explicit_live_authorization_record_required"]
  case gaps, only_live_authorization_remains {
    [], _ -> Report(status: "ready_for_separate_live_authorization", gaps: [])
    _, True ->
      Report(status: "ready_for_separate_live_authorization", gaps: gaps)
    _, False -> Report(status: "blocked", gaps: gaps)
  }
}

fn add_unless(gaps: List(String), condition: Bool, gap: String) -> List(String) {
  case condition {
    True -> gaps
    False -> list.append(gaps, [gap])
  }
}
