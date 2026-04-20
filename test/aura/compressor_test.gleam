import aura/compressor
import aura/conversation
import aura/llm
import gleam/list
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
  should.be_true(string.contains(result, "[USER]: What's the weather?"))
  should.be_true(string.contains(result, "[ASSISTANT]: It's sunny today."))
  should.be_true(string.contains(result, "[USER]: Thanks!"))
}

pub fn serialize_skips_system_test() {
  let messages = [
    llm.SystemMessage("You are helpful."),
    llm.UserMessage("Hi"),
    llm.AssistantMessage("Hello"),
  ]
  let result = compressor.serialize_messages(messages)
  should.be_false(string.contains(result, "You are helpful"))
  should.be_true(string.contains(result, "[USER]: Hi"))
}

pub fn build_first_compression_prompt_test() {
  let serialized = "[USER]: Hello\n[ASSISTANT]: Hi there"
  let result =
    compressor.build_compression_prompt(serialized, None, "test-domain", "", "")
  should.be_true(string.contains(result, "structured handoff summary"))
  should.be_true(string.contains(result, serialized))
  should.be_true(string.contains(result, "test-domain"))
}

pub fn build_update_prompt_test() {
  let serialized = "[USER]: New stuff\n[ASSISTANT]: Response"
  let existing = "## Goal\nHelp with accounting"
  let result =
    compressor.build_compression_prompt(
      serialized,
      Some(existing),
      "test-domain",
      "",
      "",
    )
  should.be_true(string.contains(
    result,
    "updating a context compaction summary",
  ))
  should.be_true(string.contains(result, existing))
  should.be_true(string.contains(result, "PRESERVE all existing"))
}

pub fn wrap_summary_test() {
  let summary = "## Goal\nHelp with receipts"
  let result = compressor.wrap_summary(summary)
  should.be_true(string.starts_with(result, "[CONTEXT COMPACTION]"))
  should.be_true(string.contains(result, "## Goal"))
}

// ---------------------------------------------------------------------------
// Tool output pruning tests
// ---------------------------------------------------------------------------

pub fn prune_tool_outputs_basic_test() {
  // Old tool results (>200 chars) should be pruned, recent ones protected
  let long_content = string.repeat("x", 300)
  let messages = [
    llm.UserMessage("question"),
    llm.ToolResultMessage("call-1", long_content),
    llm.AssistantMessage("response"),
    llm.UserMessage("follow-up"),
    llm.ToolResultMessage("call-2", long_content),
    llm.AssistantMessage("final"),
  ]
  // Protect last 2 messages (call-2 result and final response)
  let #(pruned, count) = compressor.prune_tool_outputs(messages, 2)
  // First tool result should be pruned
  should.equal(count, 1)
  // Last tool result should be protected
  let last_tool = case list.drop(pruned, 4) {
    [llm.ToolResultMessage(_, c), ..] -> c
    _ -> ""
  }
  should.equal(last_tool, long_content)
}

pub fn prune_tool_outputs_short_content_test() {
  // Short tool results (<200 chars) should NOT be pruned
  let messages = [
    llm.UserMessage("q"),
    llm.ToolResultMessage("call-1", "short result"),
    llm.AssistantMessage("a"),
  ]
  let #(pruned, count) = compressor.prune_tool_outputs(messages, 1)
  should.equal(count, 0)
  should.equal(list.length(pruned), 3)
}

pub fn prune_tool_outputs_all_protected_test() {
  // If protect_tail >= total, nothing should be pruned
  let long_content = string.repeat("x", 300)
  let messages = [
    llm.ToolResultMessage("call-1", long_content),
  ]
  let #(_pruned, count) = compressor.prune_tool_outputs(messages, 10)
  should.equal(count, 0)
}

// ---------------------------------------------------------------------------
// Tool pair sanitization tests
// ---------------------------------------------------------------------------

pub fn sanitize_removes_orphaned_results_test() {
  // A tool result with no matching call should be removed
  let messages = [
    llm.UserMessage("hello"),
    llm.ToolResultMessage("orphan-id", "some result"),
    llm.AssistantMessage("done"),
  ]
  let sanitized = compressor.sanitize_tool_pairs(messages)
  should.equal(list.length(sanitized), 2)
}

pub fn sanitize_inserts_stubs_for_orphaned_calls_test() {
  // A tool call with no matching result should get a stub
  let messages = [
    llm.AssistantToolCallMessage("thinking", [
      llm.ToolCall(id: "call-1", name: "read_file", arguments: "{}"),
    ]),
    llm.AssistantMessage("done"),
  ]
  let sanitized = compressor.sanitize_tool_pairs(messages)
  // Should be: tool call msg, stub result, assistant msg
  should.equal(list.length(sanitized), 3)
  let stub = case list.drop(sanitized, 1) {
    [llm.ToolResultMessage(_, c), ..] -> c
    _ -> ""
  }
  should.be_true(string.contains(stub, "Result from earlier"))
}

pub fn sanitize_preserves_matched_pairs_test() {
  // Matched call+result pairs should be preserved
  let messages = [
    llm.AssistantToolCallMessage("", [
      llm.ToolCall(id: "call-1", name: "read_file", arguments: "{}"),
    ]),
    llm.ToolResultMessage("call-1", "file contents"),
    llm.AssistantMessage("here it is"),
  ]
  let sanitized = compressor.sanitize_tool_pairs(messages)
  should.equal(list.length(sanitized), 3)
}

// ---------------------------------------------------------------------------
// Threshold check tests
// ---------------------------------------------------------------------------

pub fn needs_tool_pruning_test() {
  // 600 chars = 150 tokens. At context_length=200, 50% = 100 -> should trigger
  let messages = [
    llm.UserMessage(string.repeat("x", 300)),
    llm.AssistantMessage(string.repeat("y", 300)),
  ]
  // 0 = no API tokens, use rough estimate
  should.be_true(conversation.needs_tool_pruning(messages, 200, 0))
  should.be_false(conversation.needs_tool_pruning(messages, 2000, 0))
  // With real API token count: 500 tokens > 200/2=100, should trigger
  should.be_true(conversation.needs_tool_pruning(messages, 200, 500))
}

pub fn needs_full_compression_test() {
  // 600 chars = 150 tokens. At context_length=200, 70% = 140 -> should trigger
  let messages = [
    llm.UserMessage(string.repeat("x", 300)),
    llm.AssistantMessage(string.repeat("y", 300)),
  ]
  // 0 = no API tokens, use rough estimate
  should.be_true(conversation.needs_full_compression(messages, 200, 0))
  should.be_false(conversation.needs_full_compression(messages, 2000, 0))
}

// ---------------------------------------------------------------------------
// Domain-aware prompt tests
// ---------------------------------------------------------------------------

pub fn build_prompt_with_domain_context_test() {
  let serialized = "[USER]: Hello"
  let result =
    compressor.build_compression_prompt(
      serialized,
      None,
      "my-project",
      "You are a coding assistant",
      "Working on PR #42",
    )
  should.be_true(string.contains(result, "my-project"))
  should.be_true(string.contains(result, "Domain instructions:"))
  should.be_true(string.contains(result, "You are a coding assistant"))
  should.be_true(string.contains(result, "Current state:"))
  should.be_true(string.contains(result, "Working on PR #42"))
}

pub fn build_prompt_without_domain_context_test() {
  let serialized = "[USER]: Hello"
  let result =
    compressor.build_compression_prompt(serialized, None, "aura", "", "")
  should.be_true(string.contains(result, "aura"))
  should.be_false(string.contains(result, "Domain instructions:"))
  should.be_false(string.contains(result, "Current state:"))
}

// ---------------------------------------------------------------------------
// Smart truncate via serialize_messages test
// ---------------------------------------------------------------------------

pub fn serialize_messages_truncates_long_content_test() {
  // Content over 6000 chars should be smart-truncated
  let long = string.repeat("x", 7000)
  let messages = [llm.UserMessage(long)]
  let result = compressor.serialize_messages(messages)
  should.be_true(string.contains(result, "...[truncated]..."))
}

pub fn serialize_messages_includes_tool_call_args_test() {
  let messages = [
    llm.AssistantToolCallMessage("thinking", [
      llm.ToolCall(
        id: "c1",
        name: "read_file",
        arguments: "{\"path\": \"test.gleam\"}",
      ),
    ]),
  ]
  let result = compressor.serialize_messages(messages)
  should.be_true(string.contains(result, "read_file"))
  should.be_true(string.contains(result, "test.gleam"))
}

pub fn serialize_messages_includes_tool_result_id_test() {
  let messages = [
    llm.ToolResultMessage("call-abc", "file contents here"),
  ]
  let result = compressor.serialize_messages(messages)
  should.be_true(string.contains(result, "call-abc"))
  should.be_true(string.contains(result, "file contents here"))
}
