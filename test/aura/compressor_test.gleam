import aura/compressor
import aura/llm
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn estimate_tokens_test() {
  // 4 chars per token
  should.equal(compressor.estimate_tokens(""), 0)
  should.equal(compressor.estimate_tokens("abcd"), 1)
  should.equal(compressor.estimate_tokens("abcdefgh"), 2)
  should.equal(compressor.estimate_tokens(string.repeat("x", 400)), 100)
}

pub fn estimate_messages_tokens_test() {
  let messages = [
    llm.UserMessage(string.repeat("a", 40)),
    llm.AssistantMessage(string.repeat("b", 40)),
  ]
  // 80 chars total / 4 = 20 tokens
  should.equal(compressor.estimate_messages_tokens(messages), 20)
}

pub fn summary_token_budget_test() {
  // Small content: floor at 2000
  should.equal(compressor.summary_token_budget(100), 2000)
  // Medium content: 20%
  should.equal(compressor.summary_token_budget(20_000), 4000)
  // Large content: ceiling at 12000
  should.equal(compressor.summary_token_budget(100_000), 12_000)
}

pub fn serialize_messages_test() {
  let messages = [
    llm.UserMessage("What's the weather?"),
    llm.AssistantMessage("It's sunny today."),
    llm.UserMessage("Thanks!"),
    llm.AssistantMessage("You're welcome."),
  ]
  let result = compressor.serialize_messages(messages)
  should.be_true(string.contains(result, "[user]: What's the weather?"))
  should.be_true(string.contains(result, "[assistant]: It's sunny today."))
  should.be_true(string.contains(result, "[user]: Thanks!"))
}

pub fn serialize_skips_system_test() {
  let messages = [
    llm.SystemMessage("You are helpful."),
    llm.UserMessage("Hi"),
    llm.AssistantMessage("Hello"),
  ]
  let result = compressor.serialize_messages(messages)
  should.be_false(string.contains(result, "You are helpful"))
  should.be_true(string.contains(result, "[user]: Hi"))
}

pub fn build_first_compression_prompt_test() {
  let serialized = "[user]: Hello\n[assistant]: Hi there"
  let result = compressor.build_compression_prompt(serialized, None)
  should.be_true(string.contains(result, "Create a structured handoff summary"))
  should.be_true(string.contains(result, serialized))
  should.be_true(string.contains(result, "Token budget"))
}

pub fn build_update_prompt_test() {
  let serialized = "[user]: New stuff\n[assistant]: Response"
  let existing = "## Goal\nHelp with accounting"
  let result = compressor.build_compression_prompt(serialized, Some(existing))
  should.be_true(string.contains(result, "updating a context compaction summary"))
  should.be_true(string.contains(result, existing))
  should.be_true(string.contains(result, "PRESERVE all existing"))
}

pub fn wrap_summary_test() {
  let summary = "## Goal\nHelp with receipts"
  let result = compressor.wrap_summary(summary)
  should.be_true(string.starts_with(result, "[CONTEXT COMPACTION]"))
  should.be_true(string.contains(result, "## Goal"))
}
