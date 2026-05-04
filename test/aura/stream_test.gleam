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
  should.be_true(string.contains(result, "[USER]: hello"))
  should.be_true(string.contains(result, "[ASSISTANT]: hi"))
}

pub fn serialize_includes_tool_results_test() {
  let messages = [
    llm.ToolResultMessage("call_1", "file contents here"),
  ]
  let result = compressor.serialize_messages(messages)
  should.be_true(string.contains(
    result,
    "[TOOL RESULT call_1]: file contents here",
  ))
}

pub fn serialize_truncates_long_content_test() {
  let long_msg = string.repeat("x", 7000)
  let messages = [llm.UserMessage(long_msg)]
  let result = compressor.serialize_messages(messages)
  // Should be smart-truncated (4000 head + marker + 1500 tail)
  should.be_true(string.contains(result, "...[truncated]..."))
}

pub fn serialize_tool_call_message_test() {
  let messages = [
    llm.AssistantToolCallMessage("", [
      llm.ToolCall(
        id: "call_1",
        name: "read_file",
        arguments: "{\"path\":\".\"}",
      ),
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
  let serialized = "[USER]: Hello\n[ASSISTANT]: Hi"
  let result =
    compressor.build_compression_prompt(
      serialized,
      option.None,
      "test-domain",
      "",
      "",
    )
  should.be_true(string.contains(result, "structured handoff summary"))
  should.be_true(string.contains(result, "Goal"))
  should.be_true(string.contains(result, "Key Decisions"))
  should.be_true(string.contains(result, serialized))
}

pub fn build_iterative_update_prompt_test() {
  let serialized = "[USER]: new stuff"
  let existing = "## Goal\nHelp with accounting"
  let result =
    compressor.build_compression_prompt(
      serialized,
      option.Some(existing),
      "test-domain",
      "",
      "",
    )
  should.be_true(string.contains(
    result,
    "updating a context compaction summary",
  ))
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

// ---------------------------------------------------------------------------
// Compaction summary detection
// ---------------------------------------------------------------------------

pub fn is_compaction_summary_true_test() {
  compressor.is_compaction_summary("[CONTEXT COMPACTION] some content here")
  |> should.be_true
}

pub fn is_compaction_summary_false_test() {
  compressor.is_compaction_summary("regular system message")
  |> should.be_false
}

// ---------------------------------------------------------------------------
// Strip summary prefix
// ---------------------------------------------------------------------------

pub fn strip_summary_prefix_test() {
  let full = compressor.wrap_summary("## Goal\nHelp with receipts")
  let stripped = compressor.strip_summary_prefix(full)
  should.equal(stripped, "## Goal\nHelp with receipts")
}

// ---------------------------------------------------------------------------
// Serialize empty messages list
// ---------------------------------------------------------------------------

pub fn serialize_empty_messages_test() {
  compressor.serialize_messages([])
  |> should.equal("")
}

// ---------------------------------------------------------------------------
// Token estimation for Unicode content
// ---------------------------------------------------------------------------

pub fn estimate_tokens_unicode_test() {
  // Unicode characters should still yield a positive estimate
  let result = compressor.estimate_tokens("Hello world! 你好世界")
  should.be_true(result > 0)
}

// ---------------------------------------------------------------------------
// Streaming SSE parse_delta regression tests
// ---------------------------------------------------------------------------

@external(erlang, "aura_stream_ffi", "test_parse_delta_type")
fn parse_delta_type(json: String) -> String

/// Regression: when an SSE delta contains both "content":"" (empty) AND
/// "tool_calls", parse_delta must classify it as tool_call_delta, not as an
/// empty content delta.  Before the fix, the content check matched first and
/// the tool call argument chunk was silently dropped.
pub fn parse_delta_empty_content_with_tool_calls_test() {
  // Simulates a delta chunk where content is empty but tool_calls are present
  let json =
    "{\"choices\":[{\"delta\":{\"content\":\"\",\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"web_search\",\"arguments\":\"{\\\"query\\\":\\\"test\\\"}\"}}]}}]}"
  parse_delta_type(json)
  |> should.equal("tool_call_delta")
}

/// Normal content delta should still be classified correctly.
pub fn parse_delta_normal_content_test() {
  let json = "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}"
  parse_delta_type(json)
  |> should.equal("delta")
}

/// Null content with tool calls should classify as tool_call_delta.
pub fn parse_delta_null_content_with_tool_calls_test() {
  let json =
    "{\"choices\":[{\"delta\":{\"content\":null,\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"piece\"}}]}}]}"
  parse_delta_type(json)
  |> should.equal("tool_call_delta")
}

pub fn parse_delta_responses_output_text_test() {
  let json = "{\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}"

  parse_delta_type(json)
  |> should.equal("delta")
}

pub fn parse_delta_responses_function_call_added_test() {
  let json =
    "{\"type\":\"response.output_item.added\",\"response_id\":\"resp_1\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"\"}}"

  parse_delta_type(json)
  |> should.equal("tool_call_delta")
}

pub fn parse_delta_responses_function_call_arguments_test() {
  let json =
    "{\"type\":\"response.function_call_arguments.delta\",\"response_id\":\"resp_1\",\"item_id\":\"fc_1\",\"output_index\":0,\"delta\":\"{\\\"path\\\"\"}"

  parse_delta_type(json)
  |> should.equal("tool_call_delta")
}
