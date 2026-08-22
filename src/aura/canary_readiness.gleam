import gleam/list
import gleam/string

/// An explicit connector activation in a local canary plan.
pub type ConnectorActivation {
  ConnectorActivation(connector_id: String, state: String)
}

/// The local-only controls for a canary readiness check.
pub type CanaryPlan {
  CanaryPlan(
    canary_id: String,
    domain_id: String,
    concern_id: String,
    connectors: List(ConnectorActivation),
    delivery_owner: String,
    delivery_target: String,
    allow_discord: Bool,
    trial_days: Int,
    read_only: Bool,
    live_authorized: Bool,
  )
}

/// Verify that a canary plan cannot activate a connector or deliver externally.
pub fn verify(plan: CanaryPlan) -> Result(String, String) {
  let gmail_disabled =
    list.any(plan.connectors, fn(connector) {
      connector.connector_id == "gmail" && connector.state == "disabled"
    })
  let calendar_disabled =
    list.any(plan.connectors, fn(connector) {
      connector.connector_id == "calendar" && connector.state == "disabled"
    })
  let only_expected_disabled_connectors =
    list.length(plan.connectors) == 2
    && list.all(plan.connectors, fn(connector) {
      list.contains(["gmail", "calendar"], connector.connector_id)
      && connector.state == "disabled"
    })
  let explicit_concern =
    string.starts_with(plan.concern_id, "concern:" <> plan.domain_id <> ":")

  case
    plan.canary_id != "",
    plan.domain_id == "domain:personal-life",
    explicit_concern,
    gmail_disabled,
    calendar_disabled,
    only_expected_disabled_connectors,
    plan.delivery_owner == "codex",
    plan.delivery_target == "codex_monitor",
    plan.allow_discord,
    plan.trial_days == 7,
    plan.read_only,
    plan.live_authorized
  {
    True, True, True, True, True, True, True, True, False, True, True, False ->
      Ok("ready_for_local_simulation")
    _, _, _, _, _, _, _, _, _, _, _, _ -> Error("canary_not_ready")
  }
}
