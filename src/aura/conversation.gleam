import aura/compressor
import aura/db
import aura/llm
import gleam/dict
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Conversation buffers keyed by channel_id
pub type Buffers =
  dict.Dict(String, List(llm.Message))

/// A tool trace for display
pub type ToolTrace {
  ToolTrace(name: String, args: String, result: String, is_error: Bool)
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
  use stored <- result.try(db.load_messages(db_subject, convo_id, 40))
  let messages = list.map(stored, fn(m) {
    case m.role {
      "system" -> llm.SystemMessage(m.content)
      "user" -> llm.UserMessage(m.content)
      "assistant" -> llm.AssistantMessage(m.content)
      "tool" -> llm.ToolResultMessage(m.tool_call_id, m.content)
      _ -> llm.UserMessage(m.content)
    }
  })
  Ok(#(convo_id, messages))
}

/// Save a user+assistant exchange to the database.
pub fn save_to_db(
  db_subject: process.Subject(db.DbMessage),
  conversation_id: String,
  user_msg: String,
  assistant_msg: String,
  author_id: String,
  author_name: String,
  timestamp: Int,
) -> Result(Nil, String) {
  use _ <- result.try(db.append_message(db_subject, conversation_id, "user", user_msg, author_id, author_name, timestamp))
  db.append_message(db_subject, conversation_id, "assistant", assistant_msg, "", "aura", timestamp + 1)
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
        Error(_) -> #(buffers, cache_key, [])
      }
    }
    existing -> #(buffers, platform <> ":" <> platform_id, existing)
  }
}

/// Append user + assistant messages to the channel buffer.
/// No hard cap — compression is triggered separately.
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

/// Compress old messages and return updated buffer.
/// Protects first 3 messages (head) and last ~20 messages (tail).
/// Compresses the middle into a structured summary via LLM.
pub fn compress_buffer(
  buffers: Buffers,
  channel_id: String,
  llm_config: llm.LlmConfig,
) -> Buffers {
  let history = get_history(buffers, channel_id)
  let total = list.length(history)
  let protect_tail = 20

  case total > protect_tail + 3 {
    False -> buffers
    True -> {
      // Head: first 3 messages (system prompt + initial exchange)
      // But if first message is a compaction summary, protect first 1
      let existing = get_existing_summary(history)
      let head_count = case existing {
        Some(_) -> 1
        None -> 3
      }
      let tail = list.drop(history, total - protect_tail)
      let middle = list.drop(history, head_count) |> list.take(total - head_count - protect_tail)

      case compressor.compress(llm_config, middle, existing) {
        Ok(summary_text) -> {
          io.println("[conversation] Compressed " <> string.inspect(list.length(middle)) <> " messages into summary")
          let summary_msg = llm.SystemMessage(summary_text)
          let new_history = [summary_msg, ..tail]
          dict.insert(buffers, channel_id, new_history)
        }
        Error(e) -> {
          // Compression failed — fall back to hard drop (keep last 40)
          io.println("[conversation] Compression failed: " <> e <> ", falling back to hard drop")
          let capped = list.drop(history, total - 40)
          dict.insert(buffers, channel_id, capped)
        }
      }
    }
  }
}

/// Format tool traces for Discord display.
/// Format: `> ICON \`tool_name(args_preview)\` → result_preview`
pub fn format_traces(traces: List(ToolTrace)) -> String {
  list.map(traces, fn(trace) {
    let icon = case trace.is_error {
      True -> "\u{274C}"
      False -> "\u{1F527}"
    }
    let args_preview = string.slice(trace.args, 0, 40)
    let result_collapsed =
      string.replace(trace.result, each: "\n", with: ", ")
    let result_preview = case string.length(result_collapsed) > 50 {
      True -> string.slice(result_collapsed, 0, 50) <> "..."
      False -> result_collapsed
    }
    "> "
    <> icon
    <> " `"
    <> trace.name
    <> "("
    <> args_preview
    <> ")` → "
    <> result_preview
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
