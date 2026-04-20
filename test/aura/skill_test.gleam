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
  let _ =
    simplifile.write(base <> "/skills/jira/jira.sh", "#!/bin/bash\necho done")
  let _ = simplifile.create_directory_all(base <> "/skills/google")
  let _ =
    simplifile.write(
      base <> "/skills/google/SKILL.md",
      "# Google\nGoogle workspace.",
    )
  let _ =
    simplifile.write(
      base <> "/skills/google/google.sh",
      "#!/bin/bash\necho done",
    )

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
  skill.filter_allowed(all, ["jira", "google"])
  |> list.length
  |> should.equal(2)
}

pub fn skill_description_for_prompt_test() {
  let skills = [
    skill.SkillInfo(name: "jira", description: "Manage tickets.", path: "/p"),
    skill.SkillInfo(
      name: "google",
      description: "Google workspace.",
      path: "/p",
    ),
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

pub fn discover_uses_frontmatter_description_test() {
  let base = "/tmp/aura-skill-frontmatter-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base <> "/skills/google")
  let content =
    "---\nname: google\ndescription: Google Workspace CLI (Gmail, Calendar, Drive). Pass args as JSON array.\n---\n\n# Google Workspace\n\nBody content here.\n"
  let _ = simplifile.write(base <> "/skills/google/SKILL.md", content)
  let _ =
    simplifile.write(base <> "/skills/google/google.sh", "#!/bin/bash\necho ok")

  let skills = skill.discover(base <> "/skills") |> should.be_ok
  let assert Ok(google) = list.find(skills, fn(s) { s.name == "google" })
  google.description
  |> should.equal(
    "Google Workspace CLI (Gmail, Calendar, Drive). Pass args as JSON array.",
  )

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn discover_frontmatter_without_description_falls_back_to_body_test() {
  let base =
    "/tmp/aura-skill-frontmatter-fallback-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base <> "/skills/alpha")
  let content =
    "---\ntier: 2\nentrypoint: scripts/run.py\n---\n\n# Alpha\n\nAlpha body description.\n"
  let _ = simplifile.write(base <> "/skills/alpha/SKILL.md", content)
  let _ =
    simplifile.write(base <> "/skills/alpha/run.sh", "#!/bin/bash\necho ok")

  let skills = skill.discover(base <> "/skills") |> should.be_ok
  let assert Ok(alpha) = list.find(skills, fn(s) { s.name == "alpha" })
  alpha.description |> should.equal("Alpha body description.")

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn discover_no_frontmatter_uses_first_paragraph_test() {
  let base = "/tmp/aura-skill-nofm-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base <> "/skills/plain")
  let content = "# Plain\n\nPlain description text.\n"
  let _ = simplifile.write(base <> "/skills/plain/SKILL.md", content)
  let _ =
    simplifile.write(base <> "/skills/plain/run.sh", "#!/bin/bash\necho ok")

  let skills = skill.discover(base <> "/skills") |> should.be_ok
  let assert Ok(plain) = list.find(skills, fn(s) { s.name == "plain" })
  plain.description |> should.equal("Plain description text.")

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn discover_frontmatter_with_quoted_description_test() {
  let base = "/tmp/aura-skill-quoted-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base <> "/skills/slack")
  let content =
    "---\nname: slack\ndescription: \"Read Slack, draft replies. Multi-workspace.\"\n---\n\n# Slack\n"
  let _ = simplifile.write(base <> "/skills/slack/SKILL.md", content)
  let _ =
    simplifile.write(base <> "/skills/slack/run.sh", "#!/bin/bash\necho ok")

  let skills = skill.discover(base <> "/skills") |> should.be_ok
  let assert Ok(slack) = list.find(skills, fn(s) { s.name == "slack" })
  slack.description
  |> should.equal("Read Slack, draft replies. Multi-workspace.")

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn patch_skill_replaces_unique_substring_test() {
  let dir = "/tmp/aura-skill-patch-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(dir)
  let _ = skill.create(dir, "p", "# P\n\nversion: 1.0\n")
  skill.patch(dir, "p", "version: 1.0", "version: 2.0") |> should.be_ok
  let assert Ok(read) = simplifile.read(dir <> "/p/SKILL.md")
  read |> string.contains("version: 2.0") |> should.be_true
  read |> string.contains("version: 1.0") |> should.be_false
  let _ = simplifile.delete_all([dir])
}

pub fn patch_skill_rejects_missing_substring_test() {
  let dir = "/tmp/aura-skill-patch-miss-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(dir)
  let _ = skill.create(dir, "p", "# P\n")
  skill.patch(dir, "p", "not there", "x") |> should.be_error
  let _ = simplifile.delete_all([dir])
}

pub fn patch_skill_rejects_ambiguous_match_test() {
  let dir = "/tmp/aura-skill-patch-amb-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(dir)
  let _ = skill.create(dir, "p", "# P\n\nfoo\nfoo\n")
  skill.patch(dir, "p", "foo", "bar") |> should.be_error
  let _ = simplifile.delete_all([dir])
}

pub fn delete_skill_removes_directory_test() {
  let dir = "/tmp/aura-skill-delete-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(dir)
  let _ = skill.create(dir, "gone", "# Gone\n")
  skill.delete(dir, "gone") |> should.be_ok
  let exists = simplifile.is_directory(dir <> "/gone")
  exists |> should.equal(Ok(False))
  let _ = simplifile.delete_all([dir])
}

pub fn delete_skill_rejects_missing_test() {
  let dir = "/tmp/aura-skill-delete-miss-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(dir)
  skill.delete(dir, "ghost") |> should.be_error
  let _ = simplifile.delete_all([dir])
}

pub fn list_with_details_test() {
  let dir = "/tmp/aura-skill-list-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(dir <> "/alpha")
  let _ =
    simplifile.write(
      dir <> "/alpha/SKILL.md",
      "# Alpha\n\nAlpha skill for testing.\n",
    )
  let _ = simplifile.create_directory_all(dir <> "/beta")
  let _ =
    simplifile.write(
      dir <> "/beta/SKILL.md",
      "# Beta\n\nBeta skill for testing.\n",
    )

  let result = skill.list_with_details(dir)
  should.be_ok(result)
  let assert Ok(listing) = result
  // Should contain both skills as formatted text
  let _ = listing

  let _ = simplifile.delete_all([dir])
}
