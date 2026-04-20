import aura/llm
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The prefix prepended to all compaction summaries.
pub const compaction_tag = "[CONTEXT COMPACTION]"

const summary_prefix = "[CONTEXT COMPACTION] Earlier turns in this conversation were compacted to save context space. The summary below captures the key context:\n\n"

/// Check if a message is a compaction summary.
pub fn is_compaction_summary(content: String) -> Bool {
  string.starts_with(content, compaction_tag)
}

/// Strip the summary prefix, returning just the raw summary body.
pub fn strip_summary_prefix(content: String) -> String {
  string.drop_start(content, string.length(summary_prefix))
}

const prune_min_chars = 200

const pruned_placeholder = "[Output cleared to save context]"

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

pub const min_tail_messages = 20

const tail_budget_ratio = 20

/// Find the tail boundary by token budget.
/// Walks backward from the end, accumulating tokens until the budget
/// (~20% of context window) is reached. Never splits tool_call/tool_result
/// pairs. Falls back to min_tail_messages if budget protects fewer.
/// Returns the index where the tail starts (messages from this index onward are protected).
pub fn find_tail_boundary(
  messages: List(llm.Message),
  head_end: Int,
  context_length: Int,
) -> Int {
  let n = list.length(messages)
  let token_budget = context_length * tail_budget_ratio / 100

  // Walk backward, accumulating tokens
  let reversed = list.reverse(messages)
  let #(cut_idx, _) =
    list.fold(reversed, #(n, 0), fn(acc, msg) {
      let #(idx, accumulated) = acc
      let current_idx = idx - 1
      case current_idx < head_end {
        True -> acc
        False -> {
          let msg_tokens = estimate_tokens(message_content(msg)) + 10
          // Include tool call argument tokens
          let call_tokens = case msg {
            llm.AssistantToolCallMessage(_, calls) ->
              list.fold(calls, 0, fn(a, c) { a + estimate_tokens(c.arguments) })
            _ -> 0
          }
          let total_msg = msg_tokens + call_tokens
          case
            accumulated + total_msg > token_budget
            && n - current_idx >= min_tail_messages
          {
            True -> acc
            False -> #(current_idx, accumulated + total_msg)
          }
        }
      }
    })

  // Ensure at least min_tail_messages
  let fallback = n - min_tail_messages
  let cut = case cut_idx > fallback {
    True -> fallback
    False -> cut_idx
  }

  // If budget would protect everything, fall back to min_tail
  let cut = case cut <= head_end {
    True -> fallback
    False -> cut
  }

  // Align backward: don't split inside tool_call/result groups
  let cut = align_tail_backward(messages, cut)

  int.max(cut, head_end + 1)
}

/// Pull a boundary backward to avoid splitting a tool_call/result group.
/// If the boundary lands on consecutive tool results, walk backward past them
/// to include the parent assistant message.
fn align_tail_backward(messages: List(llm.Message), idx: Int) -> Int {
  case idx <= 0 || idx >= list.length(messages) {
    True -> idx
    False -> {
      // Check if message at idx-1 is a tool result
      case list.drop(messages, idx - 1) {
        [llm.ToolResultMessage(_, _), ..] -> {
          // Walk backward past consecutive tool results
          walk_back_past_tools(messages, idx - 1)
        }
        _ -> idx
      }
    }
  }
}

fn walk_back_past_tools(messages: List(llm.Message), idx: Int) -> Int {
  case idx <= 0 {
    True -> idx
    False -> {
      case list.drop(messages, idx - 1) {
        [llm.ToolResultMessage(_, _), ..] ->
          walk_back_past_tools(messages, idx - 1)
        [llm.AssistantToolCallMessage(_, _), ..] -> idx - 1
        _ -> idx
      }
    }
  }
}

/// Prune old tool result contents to save context space.
/// Replaces tool results >200 chars with a placeholder, except the last
/// `protect_tail` messages. Returns the pruned list and count of pruned messages.
pub fn prune_tool_outputs(
  messages: List(llm.Message),
  protect_tail: Int,
) -> #(List(llm.Message), Int) {
  let total = list.length(messages)
  let prune_boundary = int.max(0, total - protect_tail)
  let #(pruned, count, _idx) =
    list.fold(messages, #([], 0, 0), fn(acc, msg) {
      let #(acc_msgs, acc_count, idx) = acc
      let #(new_msg, was_pruned) = case idx < prune_boundary {
        False -> #(msg, False)
        True ->
          case msg {
            llm.ToolResultMessage(id, content) -> {
              case string.length(content) > prune_min_chars {
                True -> #(llm.ToolResultMessage(id, pruned_placeholder), True)
                False -> #(msg, False)
              }
            }
            _ -> #(msg, False)
          }
      }
      let new_count = case was_pruned {
        True -> acc_count + 1
        False -> acc_count
      }
      #([new_msg, ..acc_msgs], new_count, idx + 1)
    })
  #(list.reverse(pruned), count)
}

/// Calculate the summary token budget based on content being compressed.
/// Formula: max(2000, min(content_tokens * 0.20, 12000))
pub fn summary_token_budget(content_tokens: Int) -> Int {
  let proportional = content_tokens * summary_ratio / 100
  int.max(min_summary_tokens, int.min(proportional, max_summary_tokens))
}

/// Fix orphaned tool_call / tool_result pairs after compression.
/// 1. Remove tool results whose call_id has no matching assistant tool_call.
/// 2. Insert stub results for assistant tool_calls whose results were removed.
pub fn sanitize_tool_pairs(messages: List(llm.Message)) -> List(llm.Message) {
  // Collect all tool_call IDs from assistant messages
  let call_ids =
    list.flat_map(messages, fn(msg) {
      case msg {
        llm.AssistantToolCallMessage(_, calls) ->
          list.map(calls, fn(c) { c.id })
        _ -> []
      }
    })

  // Collect all result call_ids from tool result messages
  let result_ids =
    list.filter_map(messages, fn(msg) {
      case msg {
        llm.ToolResultMessage(id, _) -> Ok(id)
        _ -> Error(Nil)
      }
    })

  // Step 1: Remove orphaned tool results (result with no matching call)
  let cleaned =
    list.filter(messages, fn(msg) {
      case msg {
        llm.ToolResultMessage(id, _) -> list.contains(call_ids, id)
        _ -> True
      }
    })

  // Step 2: Insert stub results for calls with no matching result
  list.flat_map(cleaned, fn(msg) {
    case msg {
      llm.AssistantToolCallMessage(_, calls) -> {
        let stubs =
          list.filter_map(calls, fn(call) {
            case list.contains(result_ids, call.id) {
              True -> Error(Nil)
              False ->
                Ok(llm.ToolResultMessage(
                  call.id,
                  "[Result from earlier — see summary above]",
                ))
            }
          })
        [msg, ..stubs]
      }
      _ -> [msg]
    }
  })
}

const content_max = 6000

const content_head = 4000

const content_tail = 1500

const tool_args_max = 1500

/// Serialize messages for the summarizer with richer detail.
/// Includes tool call arguments and result content, truncated to fit.
pub fn serialize_messages(messages: List(llm.Message)) -> String {
  list.filter_map(messages, fn(msg) {
    case msg {
      llm.SystemMessage(_) -> Error(Nil)
      llm.UserMessage(c) -> Ok("[USER]: " <> smart_truncate(c))
      llm.UserMessageWithImage(c, _) ->
        Ok("[USER]: " <> smart_truncate(c) <> " [image]")
      llm.AssistantMessage(c) -> Ok("[ASSISTANT]: " <> smart_truncate(c))
      llm.AssistantToolCallMessage(c, calls) -> {
        let call_parts =
          list.map(calls, fn(call) {
            let args = truncate(call.arguments, tool_args_max)
            "  " <> call.name <> "(" <> args <> ")"
          })
        let content = smart_truncate(c)
        Ok(
          "[ASSISTANT]: "
          <> content
          <> "\n[Tool calls:\n"
          <> string.join(call_parts, "\n")
          <> "\n]",
        )
      }
      llm.ToolResultMessage(id, c) ->
        Ok("[TOOL RESULT " <> id <> "]: " <> smart_truncate(c))
    }
  })
  |> string.join("\n\n")
}

/// Build the compression prompt. Domain-aware: injects AGENTS.md and STATE.md context.
/// If existing_summary is Some, generates an iterative update.
pub fn build_compression_prompt(
  serialized_messages: String,
  existing_summary: Option(String),
  domain_name: String,
  agents_md: String,
  state_md: String,
) -> String {
  let content_tokens = estimate_tokens(serialized_messages)
  let budget = summary_token_budget(content_tokens)

  let domain_context = case agents_md {
    "" -> ""
    _ -> "Domain instructions:\n" <> truncate(agents_md, 2000) <> "\n\n"
  }
  let state_context = case state_md {
    "" -> ""
    _ -> "Current state:\n" <> truncate(state_md, 1000) <> "\n\n"
  }

  let template =
    "## Goal\n[What the user is trying to accomplish]\n\n"
    <> "## Constraints & Preferences\n[User preferences, coding style, constraints, important decisions]\n\n"
    <> "## Progress\n### Done\n[Completed work — include specific file paths, commands run, results obtained]\n### In Progress\n[Work currently underway]\n### Blocked\n[Any blockers or issues encountered]\n\n"
    <> "## Key Decisions\n[Important technical decisions and why they were made]\n\n"
    <> "## Relevant Files\n[Files read, modified, or created — with brief note on each]\n\n"
    <> "## Next Steps\n[What needs to happen next]\n\n"
    <> "## Critical Context\n[Specific values, error messages, configuration details, or data that would be lost without explicit preservation]\n\n"
    <> "## Tools & Patterns\n[Which tools were used effectively, and any tool-specific discoveries]\n\n"

  case existing_summary {
    None ->
      "You are summarizing a conversation in the \""
      <> domain_name
      <> "\" domain to save context space.\n\n"
      <> domain_context
      <> state_context
      <> "Create a structured handoff summary using this exact structure:\n\n"
      <> template
      <> "Target ~"
      <> int.to_string(budget)
      <> " tokens. Be specific — include file paths, command outputs, error messages, and concrete values.\n"
      <> "Write only the summary body.\n\n"
      <> "TURNS TO SUMMARIZE:\n"
      <> serialized_messages
    Some(existing) ->
      "You are updating a context compaction summary for the \""
      <> domain_name
      <> "\" domain.\n\n"
      <> domain_context
      <> state_context
      <> "PREVIOUS SUMMARY:\n"
      <> existing
      <> "\n\n"
      <> "Update the summary using this structure. PRESERVE all existing information that is still relevant. ADD new progress. Move items from In Progress to Done when completed. Remove information only if clearly obsolete.\n\n"
      <> template
      <> "Target ~"
      <> int.to_string(budget)
      <> " tokens. Be specific.\n"
      <> "Write only the updated summary body.\n\n"
      <> "NEW TURNS TO INCORPORATE:\n"
      <> serialized_messages
  }
}

/// Wrap a summary with the standard compaction prefix.
pub fn wrap_summary(summary: String) -> String {
  summary_prefix <> summary
}

/// Compress a list of messages into a summary using the LLM.
/// Domain-aware: uses AGENTS.md and STATE.md to guide summarization.
/// Returns the wrapped summary text ready to be stored as a SystemMessage.
pub fn compress(
  config: llm.LlmConfig,
  messages: List(llm.Message),
  existing_summary: Option(String),
  domain_name: String,
  agents_md: String,
  state_md: String,
) -> Result(String, String) {
  let serialized = serialize_messages(messages)
  let prompt =
    build_compression_prompt(
      serialized,
      existing_summary,
      domain_name,
      agents_md,
      state_md,
    )
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
    llm.UserMessageWithImage(c, _) -> c
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

/// Truncate long content preserving head and tail.
fn smart_truncate(s: String) -> String {
  case string.length(s) > content_max {
    True ->
      string.slice(s, 0, content_head)
      <> "\n...[truncated]...\n"
      <> string.slice(s, string.length(s) - content_tail, content_tail)
    False -> s
  }
}
