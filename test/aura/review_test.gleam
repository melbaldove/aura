import aura/review
import aura/xdg
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
