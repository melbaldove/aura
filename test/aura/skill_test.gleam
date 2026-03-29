import aura/skill
import aura/test_helpers
import gleam/list
import gleam/string
import gleeunit/should
import simplifile

pub fn discover_skills_test() {
  let base = "/tmp/aura-skill-test-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base <> "/skills/jira")
  let _ =
    simplifile.write(
      base <> "/skills/jira/SKILL.md",
      "# Jira\nManage Jira tickets.",
    )
  let _ = simplifile.write(base <> "/skills/jira/jira.sh", "#!/bin/bash\necho done")
  let _ = simplifile.create_directory_all(base <> "/skills/google")
  let _ =
    simplifile.write(
      base <> "/skills/google/SKILL.md",
      "# Google\nGoogle workspace.",
    )
  let _ =
    simplifile.write(base <> "/skills/google/google.sh", "#!/bin/bash\necho done")

  let skills = skill.discover(base <> "/skills") |> should.be_ok
  list.length(skills) |> should.equal(2)

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn discover_skills_empty_test() {
  let base = "/tmp/aura-skill-empty-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base <> "/skills")
  let skills = skill.discover(base <> "/skills") |> should.be_ok
  list.length(skills) |> should.equal(0)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn filter_skills_by_allowed_test() {
  let all = [
    skill.SkillInfo(name: "jira", description: "Jira", path: "/p/jira"),
    skill.SkillInfo(name: "google", description: "Google", path: "/p/google"),
    skill.SkillInfo(name: "slack", description: "Slack", path: "/p/slack"),
  ]
  skill.filter_allowed(all, ["jira", "google"]) |> list.length |> should.equal(2)
}

pub fn skill_description_for_prompt_test() {
  let skills = [
    skill.SkillInfo(name: "jira", description: "Manage tickets.", path: "/p"),
    skill.SkillInfo(name: "google", description: "Google workspace.", path: "/p"),
  ]
  let prompt = skill.descriptions_for_prompt(skills)
  prompt |> string.contains("jira") |> should.be_true
  prompt |> string.contains("Manage tickets") |> should.be_true
}

pub fn descriptions_empty_test() {
  skill.descriptions_for_prompt([]) |> should.equal("No tools available.")
}
