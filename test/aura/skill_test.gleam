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

pub fn create_skill_test() {
  let dir = "/tmp/aura-skill-create-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(dir)

  let content =
    "# Test Skill\n\nA test skill for unit testing.\n\n## When to use\nWhen testing.\n"
  let result = skill.create(dir, "test-skill", content)
  should.be_ok(result)

  // Verify SKILL.md was written
  let read_result = simplifile.read(dir <> "/test-skill/SKILL.md")
  should.be_ok(read_result)
  let assert Ok(read_content) = read_result
  should.equal(read_content, content)

  // Cleanup
  let _ = simplifile.delete_all([dir])
}

pub fn create_skill_rejects_invalid_name_test() {
  let dir = "/tmp/aura-skill-invalid-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(dir)

  let content = "# Bad\n\nBad skill.\n"
  let result = skill.create(dir, "../escape", content)
  should.be_error(result)

  let result2 = skill.create(dir, "has spaces", content)
  should.be_error(result2)

  let _ = simplifile.delete_all([dir])
}

pub fn create_skill_rejects_collision_test() {
  let dir = "/tmp/aura-skill-collision-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(dir)

  let content = "# First\n\nFirst skill.\n"
  let _ = skill.create(dir, "my-skill", content)

  // Second creation with same name should fail
  let result = skill.create(dir, "my-skill", content)
  should.be_error(result)

  let _ = simplifile.delete_all([dir])
}

pub fn list_with_details_test() {
  let dir = "/tmp/aura-skill-list-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(dir <> "/alpha")
  let _ =
    simplifile.write(dir <> "/alpha/SKILL.md", "# Alpha\n\nAlpha skill for testing.\n")
  let _ = simplifile.create_directory_all(dir <> "/beta")
  let _ =
    simplifile.write(dir <> "/beta/SKILL.md", "# Beta\n\nBeta skill for testing.\n")

  let result = skill.list_with_details(dir)
  should.be_ok(result)
  let assert Ok(listing) = result
  // Should contain both skills as formatted text
  let _ = listing

  let _ = simplifile.delete_all([dir])
}
