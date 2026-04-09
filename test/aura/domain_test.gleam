import aura/domain
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

pub fn load_context_with_agents_md_test() {
  let dir = "/tmp/aura-domain-test"
  let config_dir = dir <> "/config"
  let data_dir = dir <> "/data"
  let _ = simplifile.create_directory_all(config_dir)
  let _ = simplifile.create_directory_all(data_dir)
  let _ =
    simplifile.write(
      config_dir <> "/AGENTS.md",
      "# Test Project\nUse Swift. JIRA board is TP.",
    )

  let ctx = domain.load_context(config_dir, data_dir, data_dir, [])
  should.be_true(string.contains(ctx.agents_md, "Use Swift"))

  let _ = simplifile.delete(dir)
}

pub fn load_context_no_agents_md_test() {
  let dir = "/tmp/aura-domain-test2"
  let config_dir = dir <> "/config"
  let data_dir = dir <> "/data"
  let _ = simplifile.create_directory_all(config_dir)
  let _ = simplifile.create_directory_all(data_dir)

  let ctx = domain.load_context(config_dir, data_dir, data_dir, [])
  should.equal(ctx.agents_md, "")

  let _ = simplifile.delete(dir)
}

pub fn build_domain_prompt_test() {
  let ctx =
    domain.DomainContext(
      agents_md: "Use Swift. JIRA board is TP.",
      description: "Mobile app project",
      state_md: "Decision: use SwiftUI",
      memory_md: "User prefers dark mode",
      todays_log: "",
      skill_descriptions: "- jira: JIRA integration",
    )
  let prompt = domain.build_domain_prompt(ctx)
  should.be_true(string.contains(prompt, "Use Swift"))
  should.be_true(string.contains(prompt, "Mobile app project"))
  should.be_true(string.contains(prompt, "SwiftUI"))
  should.be_true(string.contains(prompt, "jira"))
  should.be_true(string.contains(prompt, "dark mode"))
}

pub fn build_domain_prompt_empty_test() {
  let ctx =
    domain.DomainContext(
      agents_md: "",
      description: "",
      state_md: "",
      memory_md: "",
      todays_log: "",
      skill_descriptions: "",
    )
  let prompt = domain.build_domain_prompt(ctx)
  should.be_true(string.length(prompt) > 0)
}
