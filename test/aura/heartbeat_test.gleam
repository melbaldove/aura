import aura/heartbeat
import gleeunit/should

pub fn check_config_test() {
  let config =
    heartbeat.CheckConfig(
      name: "jira",
      interval_ms: 900_000,
      skill_name: "jira",
      skill_args: ["--action", "assigned-to-me"],
      workstreams: ["cm2", "hy"],
      model: "zai/glm-5-turbo",
    )
  config.name |> should.equal("jira")
  config.interval_ms |> should.equal(900_000)
  config.skill_name |> should.equal("jira")
  config.skill_args |> should.equal(["--action", "assigned-to-me"])
  config.workstreams |> should.equal(["cm2", "hy"])
  config.model |> should.equal("zai/glm-5-turbo")
}
