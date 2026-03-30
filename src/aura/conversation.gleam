import aura/llm
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

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

/// Append user + assistant messages to the channel buffer.
/// Caps at 20 pairs (40 messages), dropping oldest when over cap.
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
  let length = list.length(new_history)
  let capped = case length > 40 {
    True -> list.drop(new_history, length - 40)
    False -> new_history
  }
  dict.insert(buffers, channel_id, capped)
}

/// Serialize a Message to a JSON object with role and content.
fn message_to_jsonl_obj(message: llm.Message) -> json.Json {
  let #(role, content) = case message {
    llm.SystemMessage(c) -> #("system", c)
    llm.UserMessage(c) -> #("user", c)
    llm.AssistantMessage(c) -> #("assistant", c)
    llm.AssistantToolCallMessage(c, _) -> #("assistant", c)
    llm.ToolResultMessage(_, c) -> #("tool", c)
  }
  json.object([#("role", json.string(role)), #("content", json.string(content))])
}

/// Persist the channel buffer to {data_dir}/conversations/{channel_id}.jsonl
pub fn save(
  buffers: Buffers,
  channel_id: String,
  data_dir: String,
) -> Result(Nil, String) {
  let dir = data_dir <> "/conversations"
  let path = dir <> "/" <> channel_id <> ".jsonl"
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(e) {
      "Failed to create conversations directory: " <> string.inspect(e)
    }),
  )
  let history = get_history(buffers, channel_id)
  let lines =
    list.map(history, fn(msg) { json.to_string(message_to_jsonl_obj(msg)) })
  let content = string.join(lines, "\n") <> "\n"
  simplifile.write(path, content)
  |> result.map_error(fn(e) {
    "Failed to write conversation file " <> path <> ": " <> string.inspect(e)
  })
}

/// Load conversation history from {data_dir}/conversations/{channel_id}.jsonl.
/// Returns empty list if file doesn't exist.
pub fn load(
  channel_id: String,
  data_dir: String,
) -> Result(List(llm.Message), String) {
  let path = data_dir <> "/conversations/" <> channel_id <> ".jsonl"
  case simplifile.read(path) {
    Error(_) -> Ok([])
    Ok(content) -> {
      let msg_decoder = {
        use role <- decode.field("role", decode.string)
        use c <- decode.field("content", decode.string)
        decode.success(#(role, c))
      }
      let lines =
        string.split(content, "\n")
        |> list.filter(fn(line) { string.length(string.trim(line)) > 0 })
      let messages =
        list.filter_map(lines, fn(line) {
          case json.parse(line, msg_decoder) {
            Error(_) -> Error(Nil)
            Ok(#(role, c)) ->
              case role {
                "system" -> Ok(llm.SystemMessage(c))
                "user" -> Ok(llm.UserMessage(c))
                "assistant" -> Ok(llm.AssistantMessage(c))
                "tool" -> Ok(llm.ToolResultMessage("", c))
                _ -> Error(Nil)
              }
          }
        })
      Ok(messages)
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
