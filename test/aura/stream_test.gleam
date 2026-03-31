import aura/compressor
import aura/llm
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Token estimation (chars/4 heuristic — same as Hermes)
// ---------------------------------------------------------------------------

pub fn estimate_tokens_empty_test() {
  compressor.estimate_tokens("")
  |> should.equal(0)
}

pub fn estimate_tokens_short_test() {
  compressor.estimate_tokens("abcd")
  |> should.equal(1)
}

pub fn estimate_tokens_long_test() {
  compressor.estimate_tokens(string.repeat("x", 400))
  |> should.equal(100)
}

pub fn estimate_messages_tokens_test() {
  let messages = [
    llm.UserMessage(string.repeat("a", 40)),
    llm.AssistantMessage(string.repeat("b", 40)),
  ]
  compressor.estimate_messages_tokens(messages)
  |> should.equal(20)
}

// ---------------------------------------------------------------------------
// Summary token budget: max(2000, min(tokens*0.20, 12000))
// ---------------------------------------------------------------------------

pub fn summary_budget_small_content_test() {
  // Small content → floor at 2000
  compressor.summary_token_budget(100)
  |> should.equal(2000)
}

pub fn summary_budget_medium_content_test() {
  // 20000 tokens * 0.20 = 4000
  compressor.summary_token_budget(20_000)
  |> should.equal(4000)
}

pub fn summary_budget_large_content_test() {
  // 100000 * 0.20 = 20000 → capped at 12000
  compressor.summary_token_budget(100_000)
  |> should.equal(12_000)
}

// ---------------------------------------------------------------------------
// Message serialization for compression prompts
// ---------------------------------------------------------------------------

pub fn serialize_skips_system_messages_test() {
  let messages = [
    llm.SystemMessage("secret system prompt"),
    llm.UserMessage("hello"),
    llm.AssistantMessage("hi"),
  ]
  let result = compressor.serialize_messages(messages)
  should.be_false(string.contains(result, "secret system prompt"))
  should.be_true(string.contains(result, "[user]: hello"))
  should.be_true(string.contains(result, "[assistant]: hi"))
}

pub fn serialize_includes_tool_results_test() {
  let messages = [
    llm.ToolResultMessage("call_1", "file contents here"),
  ]
  let result = compressor.serialize_messages(messages)
  should.be_true(string.contains(result, "[tool]: file contents here"))
}

pub fn serialize_truncates_long_content_test() {
  let long_msg = string.repeat("x", 1000)
  let messages = [llm.UserMessage(long_msg)]
  let result = compressor.serialize_messages(messages)
  // Should be truncated to 500 chars + "..."
  should.be_true(string.length(result) < 600)
  should.be_true(string.contains(result, "..."))
}

pub fn serialize_tool_call_message_test() {
  let messages = [
    llm.AssistantToolCallMessage("", [
      llm.ToolCall(id: "call_1", name: "read_file", arguments: "{\"path\":\".\"}"),
    ]),
  ]
  let result = compressor.serialize_messages(messages)
  should.be_true(string.contains(result, "read_file"))
  should.be_true(string.contains(result, "Tool calls"))
}

// ---------------------------------------------------------------------------
// Compression prompt building
// ---------------------------------------------------------------------------

pub fn build_first_compression_prompt_test() {
  let serialized = "[user]: Hello\n[assistant]: Hi"
  let result = compressor.build_compression_prompt(serialized, option.None)
  should.be_true(string.contains(result, "Create a structured handoff summary"))
  should.be_true(string.contains(result, "Goal"))
  should.be_true(string.contains(result, "Key Decisions"))
  should.be_true(string.contains(result, serialized))
}

pub fn build_iterative_update_prompt_test() {
  let serialized = "[user]: new stuff"
  let existing = "## Goal\nHelp with accounting"
  let result = compressor.build_compression_prompt(serialized, option.Some(existing))
  should.be_true(string.contains(result, "updating a context compaction summary"))
  should.be_true(string.contains(result, "PRESERVE all existing"))
  should.be_true(string.contains(result, existing))
}

// ---------------------------------------------------------------------------
// Summary wrapping
// ---------------------------------------------------------------------------

pub fn wrap_summary_has_prefix_test() {
  let summary = "## Goal\nTest goal"
  let result = compressor.wrap_summary(summary)
  should.be_true(string.starts_with(result, "[CONTEXT COMPACTION]"))
  should.be_true(string.contains(result, "## Goal"))
}
