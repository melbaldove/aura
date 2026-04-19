import aura/compressor
import aura/db
import aura/llm
import aura/time
import gleam/dict
import gleam/erlang/process
import gleam/int
import logging
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const protect_tail_count = 20

const compression_cooldown_ms = 600_000

/// Conversation buffers keyed by channel_id
pub type Buffers =
  dict.Dict(String, List(llm.Message))

/// A tool trace for display
pub type ToolTrace {
  ToolTrace(name: String, args: String, result: String, is_error: Bool)
}

/// Per-channel compressor state for tiered runtime compression.
pub type CompressorState {
  CompressorState(
    previous_summary: Option(String),
    last_prompt_tokens: Int,
    compression_count: Int,
    cooldown_until: Int,
  )
}

/// Create a new default compressor state.
pub fn new_compressor_state() -> CompressorState {
  CompressorState(
    previous_summary: None,
    last_prompt_tokens: 0,
    compression_count: 0,
    cooldown_until: 0,
  )
}

/// Return an empty buffer dict.
pub fn new() -> Buffers {
  dict.new()
}

/// Get conversation history for a channel, or empty list if none.
pub fn get_history(buffers: Buffers, channel_id: String) -> List(llm.Message) {
  dict.get(buffers, channel_id) |> result.unwrap([])
}

/// Load conversation history from the database.
/// Resolves the conversation by platform+platform_id, then loads messages.
pub fn load_from_db(
  db_subject: process.Subject(db.DbMessage),
  platform: String,
  platform_id: String,
  timestamp: Int,
) -> Result(#(String, List(llm.Message)), String) {
  use convo_id <- result.try(db.resolve_conversation(db_subject, platform, platform_id, timestamp))
  use stored <- result.try(db.load_messages(db_subject, convo_id, 80))
  let messages = list.map(stored, fn(m) {
    case m.role {
      "system" -> llm.SystemMessage(m.content)
      "user" -> llm.UserMessage(m.content)
      "assistant" -> {
        case m.tool_calls {
          "" -> llm.AssistantMessage(m.content)
          tc_json -> {
            let calls = llm.parse_tool_calls_json(tc_json)
            case calls {
              [] -> llm.AssistantMessage(m.content)
              _ -> llm.AssistantToolCallMessage(m.content, calls)
            }
          }
        }
      }
      "tool" -> llm.ToolResultMessage(m.tool_call_id, m.content)
      _ -> llm.UserMessage(m.content)
    }
  })
  // Restore compaction summary if present
  let messages_with_summary = case db.get_compaction_summary(db_subject, convo_id) {
    Ok("") -> messages
    Ok(summary) -> [llm.SystemMessage(summary), ..messages]
    Error(_) -> messages
  }
  Ok(#(convo_id, messages_with_summary))
}

/// Save a full exchange (user message + tool calls + results + final response)
/// to the database. Each message gets an incrementing timestamp offset to
/// preserve ordering.
pub fn save_exchange_to_db(
  db_subject: process.Subject(db.DbMessage),
  conversation_id: String,
  messages: List(llm.Message),
  author_id: String,
  author_name: String,
  timestamp: Int,
) -> Result(Nil, String) {
  let _ = list.index_fold(messages, Ok(Nil), fn(acc, msg, idx) {
    case acc {
      Error(e) -> Error(e)
      Ok(_) -> {
        let #(role, content, tool_call_id, tool_calls_json) = message_to_db_fields(msg)
        let msg_author_id = case role { "user" -> author_id _ -> "" }
        let msg_author_name = case role { "user" -> author_name _ -> "aura" }
        db.append_message_full(db_subject, conversation_id, role, content, msg_author_id, msg_author_name, tool_call_id, tool_calls_json, timestamp + idx)
      }
    }
  })
}

/// Convert an LLM message to database field tuple: (role, content, tool_call_id, tool_calls_json).
fn message_to_db_fields(msg: llm.Message) -> #(String, String, String, String) {
  case msg {
    llm.UserMessage(c) -> #("user", c, "", "")
    llm.UserMessageWithImage(c, _) -> #("user", c, "", "")
    llm.AssistantMessage(c) -> #("assistant", c, "", "")
    llm.AssistantToolCallMessage(c, calls) -> {
      let calls_json = json.array(calls, llm.tool_call_to_json) |> json.to_string
      #("assistant", c, "", calls_json)
    }
    llm.ToolResultMessage(id, c) -> #("tool", c, id, "")
    llm.SystemMessage(c) -> #("system", c, "", "")
  }
}

/// Append a full list of messages to the channel buffer.
/// Used when persisting the complete tool call chain in memory.
pub fn append_messages(
  buffers: Buffers,
  channel_id: String,
  messages: List(llm.Message),
) -> Buffers {
  let history = get_history(buffers, channel_id)
  let new_history = list.append(history, messages)
  dict.insert(buffers, channel_id, new_history)
}

/// Get or load from DB, updating in-memory cache.
/// Returns updated buffers, the conversation_id, and the message history.
pub fn get_or_load_db(
  buffers: Buffers,
  db_subject: process.Subject(db.DbMessage),
  platform: String,
  platform_id: String,
  timestamp: Int,
) -> #(Buffers, String, List(llm.Message)) {
  let cache_key = platform <> ":" <> platform_id
  case get_history(buffers, cache_key) {
    [] -> {
      case load_from_db(db_subject, platform, platform_id, timestamp) {
        Ok(#(convo_id, messages)) -> {
          let new_buffers = dict.insert(buffers, cache_key, messages)
          #(new_buffers, convo_id, messages)
        }
        Error(e) -> {
          logging.log(logging.Error, "[conversation] Failed to load from DB for " <> cache_key <> ": " <> e)
          #(buffers, cache_key, [])
        }
      }
    }
    existing -> #(buffers, platform <> ":" <> platform_id, existing)
  }
}

/// Append user + assistant messages to the channel buffer.
/// No hard cap — compression is triggered separately.
/// Note: only used in tests; production code uses append_messages instead.
pub fn append(
  buffers: Buffers,
  channel_id: String,
  user_msg: String,
  assistant_msg: String,
) -> Buffers {
  let history = get_history(buffers, channel_id)
  let new_history =
    list.append(history, [
      llm.UserMessage(user_msg),
      llm.AssistantMessage(assistant_msg),
    ])
  dict.insert(buffers, channel_id, new_history)
}

/// Check if a buffer needs compression.
/// Triggers at 50% of context window (Hermes default).
/// Uses chars/4 heuristic for token estimation.
pub fn needs_compression(
  buffers: Buffers,
  channel_id: String,
  context_window: Int,
) -> Bool {
  let history = get_history(buffers, channel_id)
  let tokens = compressor.estimate_messages_tokens(history)
  tokens > context_window / 2
}

/// Estimate token count: use real API value if available, otherwise rough estimate.
pub fn estimate_tokens(messages: List(llm.Message), last_prompt_tokens: Int) -> Int {
  case last_prompt_tokens > 0 {
    True -> last_prompt_tokens
    False -> compressor.estimate_messages_tokens(messages)
  }
}

/// Check if tier 1 (tool pruning) should fire — 50% of context window.
pub fn needs_tool_pruning(
  messages: List(llm.Message),
  context_length: Int,
  last_prompt_tokens: Int,
) -> Bool {
  let tokens = estimate_tokens(messages, last_prompt_tokens)
  tokens > context_length / 2
}

/// Check if tier 2 (full compression) should fire — 70% of context window.
pub fn needs_full_compression(
  messages: List(llm.Message),
  context_length: Int,
  last_prompt_tokens: Int,
) -> Bool {
  let tokens = estimate_tokens(messages, last_prompt_tokens)
  tokens > context_length * 7 / 10
}

/// Extract the existing compaction summary from a buffer, if any.
fn get_existing_summary(history: List(llm.Message)) -> Option(String) {
  case history {
    [llm.SystemMessage(content), ..] -> {
      case compressor.is_compaction_summary(content) {
        True -> Some(compressor.strip_summary_prefix(content))
        False -> None
      }
    }
    _ -> None
  }
}

/// Compress conversation buffer. Delegates to compress_history and wraps result in buffers.
pub fn compress_buffer(
  buffers: Buffers,
  channel_id: String,
  llm_config: llm.LlmConfig,
  compressor_state: CompressorState,
  domain_name: String,
  agents_md: String,
  state_md: String,
  db_subject: process.Subject(db.DbMessage),
  convo_id: String,
  context_length: Int,
) -> #(Buffers, CompressorState) {
  let history = get_history(buffers, channel_id)
  let #(new_history, new_state) = compress_history(
    history, llm_config, compressor_state, domain_name, agents_md, state_md, db_subject, convo_id, context_length,
  )
  #(dict.insert(buffers, channel_id, new_history), new_state)
}

/// Compress a message list directly (for use in spawned processes).
/// Returns the compressed history and new compressor state.
pub fn compress_history(
  history: List(llm.Message),
  llm_config: llm.LlmConfig,
  compressor_state: CompressorState,
  domain_name: String,
  agents_md: String,
  state_md: String,
  db_subject: process.Subject(db.DbMessage),
  convo_id: String,
  context_length: Int,
) -> #(List(llm.Message), CompressorState) {
  let total = list.length(history)

  case total > protect_tail_count + 3 {
    False -> #(history, compressor_state)
    True -> {
      let #(pruned_history, prune_count) =
        compressor.prune_tool_outputs(history, protect_tail_count)
      case prune_count > 0 {
        True -> logging.log(logging.Info, "[conversation] Pruned " <> int.to_string(prune_count) <> " tool output(s)")
        False -> Nil
      }

      let existing = get_existing_summary(pruned_history)
      let head_count = case existing {
        Some(_) -> 1
        None -> 3
      }
      // Token-budget tail protection: walk backward by ~20% of context window
      let tail_start = compressor.find_tail_boundary(pruned_history, head_count, context_length)
      let tail = list.drop(pruned_history, tail_start)
      let middle = list.drop(pruned_history, head_count) |> list.take(tail_start - head_count)

      let now = time.now_ms()
      case now < compressor_state.cooldown_until {
        True -> {
          logging.log(logging.Info, "[conversation] Compression in cooldown, pruning only")
          #(pruned_history, compressor_state)
        }
        False -> {
          let summary_input = case existing {
            Some(s) -> Some(s)
            None -> compressor_state.previous_summary
          }
          case compressor.compress(llm_config, middle, summary_input, domain_name, agents_md, state_md) {
            Ok(summary_text) -> {
              logging.log(logging.Info, "[conversation] Compressed " <> int.to_string(list.length(middle)) <> " messages into summary")
              let summary_msg = llm.SystemMessage(summary_text)
              let new_history = compressor.sanitize_tool_pairs([summary_msg, ..tail])
              case db.update_compaction_summary(db_subject, convo_id, summary_text) {
                Ok(_) -> Nil
                Error(e) -> logging.log(logging.Error, "[conversation] Failed to persist compaction summary: " <> e)
              }
              let new_state = CompressorState(
                previous_summary: Some(compressor.strip_summary_prefix(summary_text)),
                last_prompt_tokens: compressor_state.last_prompt_tokens,
                compression_count: compressor_state.compression_count + 1,
                cooldown_until: 0,
              )
              #(new_history, new_state)
            }
            Error(e) -> {
              logging.log(logging.Error, "[conversation] Compression failed: " <> e <> ", cooldown 10 minutes")
              #(pruned_history, CompressorState(..compressor_state, cooldown_until: now + compression_cooldown_ms))
            }
          }
        }
      }
    }
  }
}

const max_trace_field_chars = 1500

/// Safety cap against a single trace field (args or result) overflowing
/// Discord's 2000-char message limit. Appends `…[N more chars]` when cut.
fn cap_field(text: String, max: Int) -> String {
  let len = string.length(text)
  case len > max {
    False -> text
    True ->
      string.slice(text, 0, max)
      <> " …["
      <> int.to_string(len - max)
      <> " more chars]"
  }
}

/// Format tool traces for Discord display. Shows the full call (name +
/// args) and the full result verbatim — no truncation, no spoilers. If
/// either field is pathologically long, caps at max_trace_field_chars to
/// protect the 2000-char message limit.
pub fn format_traces(traces: List(ToolTrace)) -> String {
  list.map(traces, fn(trace) {
    let icon = case trace.is_error {
      True -> "\u{274C}"
      False -> "\u{1F527}"
    }
    let args = cap_field(trace.args, max_trace_field_chars)
    let result = cap_field(trace.result, max_trace_field_chars)
    // Keep newlines in the result but reflow into Discord's quote-block
    // continuation by prefixing with `> `.
    let result_indented = string.replace(result, each: "\n", with: "\n> ")
    let args_has_newlines = string.contains(args, "\n")
    case args_has_newlines {
      False ->
        "> "
        <> icon
        <> " `"
        <> trace.name
        <> "("
        <> args
        <> ")` → "
        <> result_indented
      True ->
        "> "
        <> icon
        <> " ```\n"
        <> trace.name
        <> "("
        <> args
        <> ")```\n> → "
        <> result_indented
    }
  })
  |> string.join("\n")
}

/// Format traces + response for Discord.
/// If no traces, returns just the response string.
pub fn format_full_message(traces: List(ToolTrace), response: String) -> String {
  case traces {
    [] -> response
    _ -> format_traces(traces) <> "\n\n" <> response
  }
}
