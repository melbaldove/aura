import aura/brain
import aura/models
import aura/skill
import aura/system_prompt
import gleam/string
import gleeunit/should

pub fn route_domain_channel_test() {
  let domains = [
    brain.DomainInfo(name: "cm2", channel_id: "chan-cm2"),
    brain.DomainInfo(name: "hy", channel_id: "chan-hy"),
  ]
  brain.route_message("chan-cm2", domains)
  |> should.equal(brain.DirectRoute("cm2"))
}

pub fn route_domain_channel_second_test() {
  let domains = [
    brain.DomainInfo(name: "cm2", channel_id: "chan-cm2"),
    brain.DomainInfo(name: "hy", channel_id: "chan-hy"),
  ]
  brain.route_message("chan-hy", domains)
  |> should.equal(brain.DirectRoute("hy"))
}

pub fn route_unknown_channel_test() {
  let domains = [
    brain.DomainInfo(name: "cm2", channel_id: "chan-cm2"),
  ]
  brain.route_message("chan-unknown", domains)
  |> should.equal(brain.NeedsClassification)
}

pub fn route_empty_domains_test() {
  brain.route_message("chan-cm2", [])
  |> should.equal(brain.NeedsClassification)
}

pub fn build_system_prompt_test() {
  let skills = [
    skill.SkillInfo(name: "jira", description: "Jira integration", path: ""),
    skill.SkillInfo(name: "google", description: "Google search", path: ""),
  ]
  let prompt =
    system_prompt.build_system_prompt(
      "You are Aura. Direct. Concise.",
      ["cm2", "hy"],
      skills,
      "",
      "",
    )
  prompt |> string.contains("Aura") |> should.be_true
  prompt |> string.contains("Discord") |> should.be_true
  prompt |> string.contains("cm2") |> should.be_true
  prompt |> string.contains("jira") |> should.be_true
}

pub fn build_system_prompt_includes_soul_content_test() {
  let prompt =
    system_prompt.build_system_prompt("Custom personality goes here.", [], [], "", "")
  prompt |> string.contains("Custom personality goes here.") |> should.be_true
  prompt |> string.contains("No domains") |> should.be_true
}

pub fn resolve_model_name_test() {
  models.resolve_model_name("zai/glm-5-turbo")
  |> should.equal("glm-5-turbo")
}

pub fn resolve_model_name_no_prefix_test() {
  models.resolve_model_name("glm-5-turbo")
  |> should.equal("glm-5-turbo")
}

pub fn resolve_model_name_claude_test() {
  models.resolve_model_name("claude/sonnet")
  |> should.equal("sonnet")
}
