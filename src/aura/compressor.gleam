import aura/llm
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

const summary_prefix = "[CONTEXT COMPACTION] Earlier turns in this conversation were compacted to save context space. The summary below captures the key context:\n\n"

const chars_per_token = 4

const min_summary_tokens = 2000

const max_summary_tokens = 12_000

const summary_ratio = 20

/// Rough token estimate (~4 chars/token) for pre-flight checks.
/// Same heuristic as Hermes Agent.
pub fn estimate_tokens(text: String) -> Int {
  case string.length(text) {
    0 -> 0
    len -> len / chars_per_token
  }
}

/// Estimate tokens for a list of messages.
pub fn estimate_messages_tokens(messages: List(llm.Message)) -> Int {
  list.fold(messages, 0, fn(acc, msg) {
    acc + estimate_tokens(message_content(msg))
  })
}

/// Calculate the summary token budget based on content being compressed.
/// Formula: max(2000, min(content_tokens * 0.20, 12000))
pub fn summary_token_budget(content_tokens: Int) -> Int {
  let proportional = content_tokens * summary_ratio / 100
  int.max(min_summary_tokens, int.min(proportional, max_summary_tokens))
}

/// Serialize messages into text format for the summarization prompt.
/// Skips system messages. Truncates long content.
pub fn serialize_messages(messages: List(llm.Message)) -> String {
  list.filter_map(messages, fn(msg) {
    case msg {
      llm.SystemMessage(_) -> Error(Nil)
      llm.UserMessage(c) -> Ok("[user]: " <> truncate(c, 500))
      llm.AssistantMessage(c) -> Ok("[assistant]: " <> truncate(c, 500))
      llm.AssistantToolCallMessage(c, calls) -> {
        let call_names =
          list.map(calls, fn(call) {
            call.name <> "(" <> truncate(call.arguments, 200) <> ")"
          })
        Ok(
          "[assistant]: "
          <> truncate(c, 300)
          <> "\n[Tool calls: "
          <> string.join(call_names, ", ")
          <> "]",
        )
      }
      llm.ToolResultMessage(_, c) -> Ok("[tool]: " <> truncate(c, 300))
    }
  })
  |> string.join("\n")
}

/// Build the prompt for compressing messages.
/// If existing_summary is Some, this is an iterative update.
pub fn build_compression_prompt(
  serialized_messages: String,
  existing_summary: Option(String),
) -> String {
  let content_tokens = estimate_tokens(serialized_messages)
  let budget = summary_token_budget(content_tokens)

  case existing_summary {
    None ->
      "Create a structured handoff summary of this conversation. Include:\n"
      <> "- Goal: What the user is trying to accomplish\n"
      <> "- Constraints & Preferences: Any stated requirements\n"
      <> "- Progress: What's been done, in progress, or blocked\n"
      <> "- Key Decisions: Important choices made and why\n"
      <> "- Relevant Files: File paths, commands, or references mentioned\n"
      <> "- Next Steps: What should happen next\n"
      <> "- Critical Context: Anything else essential to continue\n\n"
      <> "Token budget: ~"
      <> int.to_string(budget)
      <> " tokens.\n"
      <> "Include file paths, command outputs, error messages, and concrete values rather than vague descriptions.\n"
      <> "Write only the summary body. Do not include any preamble or prefix.\n\n"
      <> "Conversation:\n"
      <> serialized_messages
    Some(existing) ->
      "You are updating a context compaction summary with new conversation turns.\n"
      <> "PRESERVE all existing information that is still relevant. ADD new progress, decisions, and context.\n"
      <> "Move items from In Progress to Done when completed.\n"
      <> "Token budget: ~"
      <> int.to_string(budget)
      <> " tokens.\n"
      <> "Write only the updated summary body.\n\n"
      <> "Existing summary:\n"
      <> existing
      <> "\n\nNew conversation turns:\n"
      <> serialized_messages
  }
}

/// Wrap a summary with the standard compaction prefix.
pub fn wrap_summary(summary: String) -> String {
  summary_prefix <> summary
}

/// Compress a list of messages into a summary using the LLM.
/// Returns the wrapped summary text ready to be stored as a SystemMessage.
pub fn compress(
  config: llm.LlmConfig,
  messages: List(llm.Message),
  existing_summary: Option(String),
) -> Result(String, String) {
  let serialized = serialize_messages(messages)
  let prompt = build_compression_prompt(serialized, existing_summary)
  let llm_messages = [llm.UserMessage(prompt)]
  case llm.chat(config, llm_messages) {
    Ok(summary) -> Ok(wrap_summary(summary))
    Error(e) -> Error("Compression failed: " <> e)
  }
}

fn message_content(msg: llm.Message) -> String {
  case msg {
    llm.SystemMessage(c) -> c
    llm.UserMessage(c) -> c
    llm.AssistantMessage(c) -> c
    llm.AssistantToolCallMessage(c, _) -> c
    llm.ToolResultMessage(_, c) -> c
  }
}

fn truncate(s: String, max: Int) -> String {
  case string.length(s) > max {
    True -> string.slice(s, 0, max) <> "..."
    False -> s
  }
}
