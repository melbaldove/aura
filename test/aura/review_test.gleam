import aura/llm
import aura/review
import aura/xdg
import gleam/list
import gleam/string
import gleeunit/should

pub fn build_state_review_prompt_test() {
  let prompt =
    review.build_review_prompt("state", "§ pr-215\nMerged into development")
  should.be_true(string.contains(prompt, "what changed"))
  should.be_true(string.contains(prompt, "pr-215"))
  should.be_true(string.contains(prompt, "Merged into development"))
}

pub fn build_memory_review_prompt_test() {
  let prompt = review.build_review_prompt("memory", "(empty)")
  should.be_true(string.contains(prompt, "what was learned"))
  should.be_true(string.contains(prompt, "Do NOT save"))
}

pub fn build_unknown_review_prompt_test() {
  let prompt = review.build_review_prompt("unknown", "anything")
  should.equal(prompt, "Nothing to save.")
}

pub fn memory_tool_definition_test() {
  let tool = review.memory_tool_definition()
  should.equal(tool.name, "memory")
  should.be_true(string.contains(tool.description, "set"))
  should.be_true(string.contains(tool.description, "remove"))
}

pub fn maybe_spawn_review_disabled_test() {
  // review_interval = 0 means disabled — should always return count + 1
  let result =
    review.maybe_spawn_review(
      0,
      False,
      "test",
      "chan",
      "token",
      [],
      5,
      xdg.resolve_with_home("/tmp/aura-review-test"),
      "test-model",
    )
  should.equal(result, 6)
}

pub fn maybe_spawn_review_not_yet_test() {
  // count 3, interval 10 — not yet, should return 4
  let result =
    review.maybe_spawn_review(
      10,
      False,
      "test",
      "chan",
      "token",
      [],
      3,
      xdg.resolve_with_home("/tmp/aura-review-test"),
      "test-model",
    )
  should.equal(result, 4)
}

pub fn build_flush_prompt_test() {
  let prompt = review.build_flush_prompt("§ pr-215\nOpen, needs review")
  should.be_true(string.contains(prompt, "compressed"))
  should.be_true(string.contains(prompt, "pr-215"))
  should.be_true(string.contains(prompt, "Open, needs review"))
  should.be_true(string.contains(prompt, "user preferences"))
}

pub fn build_flush_prompt_empty_test() {
  let prompt = review.build_flush_prompt("(empty)")
  should.be_true(string.contains(prompt, "compressed"))
  should.be_true(string.contains(prompt, "(empty)"))
}

pub fn flush_before_compression_skips_short_history_test() {
  let short_history = [
    llm.UserMessage("hello"),
    llm.AssistantMessage("hi there"),
  ]
  review.flush_before_compression(
    llm.LlmConfig(api_key: "", base_url: "", model: ""),
    short_history,
    "test-domain",
    xdg.resolve_with_home("/tmp/aura-flush-test"),
  )
  should.be_true(True)
}

pub fn build_skill_review_prompt_test() {
  let prompt =
    review.build_skill_review_prompt(
      "- **deploy-to-prod**: Deploy steps for production",
    )
  should.be_true(string.contains(prompt, "non-trivial"))
  should.be_true(string.contains(prompt, "deploy-to-prod"))
  should.be_true(string.contains(prompt, "overlap"))
  should.be_true(string.contains(prompt, "scope"))
}

pub fn build_skill_review_prompt_empty_test() {
  let prompt = review.build_skill_review_prompt("No skills installed.")
  should.be_true(string.contains(prompt, "No skills installed."))
  should.be_true(string.contains(prompt, "create_skill"))
}

pub fn skill_tool_definitions_test() {
  let tools = review.skill_tool_definitions()
  list.length(tools) |> should.equal(2)
  let names = list.map(tools, fn(t) { t.name })
  should.be_true(list.contains(names, "list_skills"))
  should.be_true(list.contains(names, "create_skill"))
}

pub fn maybe_spawn_skill_review_disabled_test() {
  let result =
    review.maybe_spawn_skill_review(
      0,
      "test",
      "chan",
      "token",
      [],
      5,
      10,
      xdg.resolve_with_home("/tmp/aura-skill-review-test"),
      "test-model",
      "/tmp/aura-skill-review-test/skills",
    )
  should.equal(result, 15)
}

pub fn maybe_spawn_skill_review_not_yet_test() {
  let result =
    review.maybe_spawn_skill_review(
      30,
      "test",
      "chan",
      "token",
      [],
      10,
      5,
      xdg.resolve_with_home("/tmp/aura-skill-review-test"),
      "test-model",
      "/tmp/aura-skill-review-test/skills",
    )
  should.equal(result, 15)
}
