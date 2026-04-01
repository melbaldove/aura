import aura/heartbeat
import aura/notification
import aura/skill
import gleam/io
import gleam/list
import gleam/string

/// Default heartbeat check configurations
/// TODO: Parse from config.toml heartbeat sections
pub fn default_checks() -> List(heartbeat.CheckConfig) {
  [
    heartbeat.CheckConfig(
      name: "jira",
      interval_ms: 900_000,
      skill_name: "jira",
      skill_args: ["--action", "assigned-to-me"],
      domains: ["cm2", "hy"],
      model: "zai/glm-5-turbo",
    ),
    heartbeat.CheckConfig(
      name: "calendar",
      interval_ms: 1_800_000,
      skill_name: "google",
      skill_args: ["--action", "calendar-today"],
      domains: [],
      model: "zai/glm-5-turbo",
    ),
    heartbeat.CheckConfig(
      name: "pr_review",
      interval_ms: 1_800_000,
      skill_name: "jira",
      skill_args: ["--action", "pending-reviews"],
      domains: ["cm2", "hy"],
      model: "zai/glm-5-turbo",
    ),
  ]
}

/// Start all heartbeat check actors
pub fn start_all(
  checks: List(heartbeat.CheckConfig),
  all_skills: List(skill.SkillInfo),
  on_finding: fn(notification.Finding) -> Nil,
) -> List(heartbeat.CheckConfig) {
  let started =
    checks
    |> list.filter_map(fn(check) {
      case heartbeat.start(check, all_skills, on_finding) {
        Ok(_subject) -> Ok(check)
        Error(err) -> {
          io.println("[heartbeat_sup] Failed to start " <> check.name <> ": " <> err)
          Error(Nil)
        }
      }
    })

  io.println(
    "[heartbeat_sup] Started "
    <> string.inspect(list.length(started))
    <> " checks",
  )

  started
}
