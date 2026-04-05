import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Message {
  SystemMessage(content: String)
  UserMessage(content: String)
  UserMessageWithImage(content: String, image_url: String)
  AssistantMessage(content: String)
  AssistantToolCallMessage(content: String, tool_calls: List(ToolCall))
  ToolResultMessage(tool_call_id: String, content: String)
}

/// Tool definition for OpenAI function calling
pub type ToolDefinition {
  ToolDefinition(name: String, description: String, parameters: List(ToolParam))
}

pub type ToolParam {
  ToolParam(name: String, param_type: String, description: String, required: Bool)
}

/// Tool call from LLM response
pub type ToolCall {
  ToolCall(id: String, name: String, arguments: String)
}

/// LLM response that may contain both text and tool calls
pub type LlmResponse {
  LlmResponse(content: String, tool_calls: List(ToolCall))
}

pub type LlmConfig {
  LlmConfig(base_url: String, api_key: String, model: String)
}

/// Encode a ToolCall as a JSON object for the assistant message tool_calls array.
pub fn tool_call_to_json(call: ToolCall) -> json.Json {
  json.object([
    #("id", json.string(call.id)),
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(call.name)),
        #("arguments", json.string(call.arguments)),
      ]),
    ),
  ])
}

/// Encode a Message as a JSON object with "role" and "content" fields.
pub fn message_to_json(message: Message) -> json.Json {
  case message {
    ToolResultMessage(id, c) ->
      json.object([
        #("role", json.string("tool")),
        #("tool_call_id", json.string(id)),
        #("content", json.string(c)),
      ])
    AssistantToolCallMessage(c, calls) -> {
      let base = [
        #("role", json.string("assistant")),
        #("tool_calls", json.array(calls, tool_call_to_json)),
      ]
      case c {
        "" -> json.object(base)
        _ -> json.object([#("content", json.string(c)), ..base])
      }
    }
    UserMessageWithImage(c, url) -> {
      let text_part =
        json.object([
          #("type", json.string("text")),
          #("text", json.string(c)),
        ])
      let image_part =
        json.object([
          #("type", json.string("image_url")),
          #("image_url", json.object([#("url", json.string(url))])),
        ])
      json.object([
        #("role", json.string("user")),
        #("content", json.preprocessed_array([text_part, image_part])),
      ])
    }
    _ -> {
      let #(role, content) = case message {
        SystemMessage(c) -> #("system", c)
        UserMessage(c) -> #("user", c)
        AssistantMessage(c) -> #("assistant", c)
        // These cases are already handled above but needed for exhaustiveness
        UserMessageWithImage(c, _) -> #("user", c)
        AssistantToolCallMessage(c, _) -> #("assistant", c)
        ToolResultMessage(_, c) -> #("tool", c)
      }
      json.object([
        #("role", json.string(role)),
        #("content", json.string(content)),
      ])
    }
  }
}

/// Build the request body JSON for a chat completions call.
pub fn build_request_body(
  model: String,
  messages: List(Message),
  temperature: Option(Float),
) -> json.Json {
  let base_fields = [
    #("model", json.string(model)),
    #("messages", json.array(messages, message_to_json)),
  ]
  let fields = case temperature {
    None -> base_fields
    Some(t) -> list.append(base_fields, [#("temperature", json.float(t))])
  }
  json.object(fields)
}

/// Extract choices[0].message.content from a chat completions response body.
pub fn parse_response(body: String) -> Result(String, String) {
  // First try to get all choices as a list of content strings, then take first
  let list_decoder =
    decode.at(["choices"], decode.list(decode.at(["message", "content"], decode.string)))
  case json.parse(body, list_decoder) {
    Error(_) -> Error("Failed to parse response JSON")
    Ok(contents) ->
      list.first(contents)
      |> result.map_error(fn(_) { "No choices in response" })
  }
}

/// Make a POST request to the chat completions endpoint and return the response content.
pub fn chat(
  config: LlmConfig,
  messages: List(Message),
) -> Result(String, String) {
  chat_with_options(config, messages, None)
}

/// Make a POST request with optional temperature and return the response content.
pub fn chat_with_options(
  config: LlmConfig,
  messages: List(Message),
  temperature: Option(Float),
) -> Result(String, String) {
  let url = config.base_url <> "/chat/completions"
  io.println("[llm] Calling " <> config.model <> " at " <> url)
  let body =
    build_request_body(config.model, messages, temperature) |> json.to_string
  use parsed_uri <- result.try(
    uri.parse(url)
    |> result.map_error(fn(_) { "Failed to parse URL: " <> url }),
  )
  use req <- result.try(
    request.from_uri(parsed_uri)
    |> result.map_error(fn(_) { "Failed to build request from URL: " <> url }),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header(
      "authorization",
      "Bearer " <> config.api_key,
    )
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(120_000)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) { "HTTP request failed: " <> string.inspect(e) }),
  )
  case resp.status {
    200 -> parse_response(resp.body)
    status -> {
      io.println("[llm] Error from " <> config.model <> ": status " <> int.to_string(status))
      Error(
        "Unexpected status "
        <> int.to_string(status)
        <> ": "
        <> string.slice(resp.body, 0, 200),
      )
    }
  }
}

/// Encode a ToolParam as a JSON property entry (name -> {type, description}).
fn tool_param_to_property(param: ToolParam) -> #(String, json.Json) {
  #(
    param.name,
    json.object([
      #("type", json.string(param.param_type)),
      #("description", json.string(param.description)),
    ]),
  )
}

/// Encode a ToolDefinition as OpenAI function calling format.
pub fn tool_definition_to_json(tool: ToolDefinition) -> json.Json {
  let properties =
    list.map(tool.parameters, tool_param_to_property)
    |> json.object
  let required =
    list.filter(tool.parameters, fn(p) { p.required })
    |> list.map(fn(p) { p.name })
  json.object([
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(tool.name)),
        #("description", json.string(tool.description)),
        #(
          "parameters",
          json.object([
            #("type", json.string("object")),
            #("properties", properties),
            #("required", json.array(required, json.string)),
          ]),
        ),
      ]),
    ),
  ])
}

/// Build request body JSON including tools array for function calling.
pub fn build_request_body_with_tools(
  model: String,
  messages: List(Message),
  tools: List(ToolDefinition),
  temperature: Option(Float),
) -> json.Json {
  let base_fields = [
    #("model", json.string(model)),
    #("messages", json.array(messages, message_to_json)),
  ]
  let fields = case temperature {
    None -> base_fields
    Some(t) -> list.append(base_fields, [#("temperature", json.float(t))])
  }
  let fields = case tools {
    [] -> fields
    _ ->
      list.append(fields, [
        #("tools", json.array(tools, tool_definition_to_json)),
      ])
  }
  json.object(fields)
}

/// Parse a chat completions response that may contain tool_calls.
pub fn parse_response_with_tools(body: String) -> Result(LlmResponse, String) {
  let function_decoder = {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    decode.success(#(name, arguments))
  }
  let tool_call_decoder = {
    use id <- decode.field("id", decode.string)
    use func <- decode.field("function", function_decoder)
    decode.success(ToolCall(id: id, name: func.0, arguments: func.1))
  }
  let message_decoder = {
    use content <- decode.optional_field(
      "content",
      None,
      decode.optional(decode.string),
    )
    use tool_calls <- decode.optional_field(
      "tool_calls",
      [],
      decode.list(tool_call_decoder),
    )
    let content_str = case content {
      Some(c) -> c
      None -> ""
    }
    decode.success(LlmResponse(content: content_str, tool_calls: tool_calls))
  }
  let list_decoder =
    decode.at(["choices"], decode.list(decode.at(["message"], message_decoder)))
  case json.parse(body, list_decoder) {
    Error(_) -> Error("Failed to parse response JSON")
    Ok(responses) ->
      list.first(responses)
      |> result.map_error(fn(_) { "No choices in response" })
  }
}

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

/// Start a streaming chat completion request WITH tool definitions.
/// The Erlang FFI sends events to callback_pid:
///   {stream_delta, Content}        — text content chunk
///   stream_reasoning               — GLM-5.1 thinking token
///   {stream_complete, Content, ToolCallsJson} — final result
///   {stream_error, Reason}         — fatal error
/// This function blocks until the stream completes (run in a spawned process).
pub fn chat_streaming_with_tools(
  config: LlmConfig,
  messages: List(Message),
  tools: List(ToolDefinition),
  callback_pid: process.Pid,
) -> Nil {
  let url = config.base_url <> "/chat/completions"
  io.println("[llm] Streaming " <> config.model <> " at " <> url <> " (with tools)")
  let base_fields = [
    #("model", json.string(config.model)),
    #("messages", json.array(messages, message_to_json)),
    #("stream", json.bool(True)),
  ]
  let fields = case tools {
    [] -> base_fields
    _ -> list.append(base_fields, [
      #("tools", json.array(tools, tool_definition_to_json)),
    ])
  }
  let body_str = json.object(fields) |> json.to_string
  stream_ffi(url, config.api_key, config.model, body_str, callback_pid)
}

/// Parse a JSON array of tool calls (as stored in the database) back into
/// a list of `ToolCall` values. Returns an empty list on parse failure.
pub fn parse_tool_calls_json(json_str: String) -> List(ToolCall) {
  let function_decoder = {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    decode.success(#(name, arguments))
  }
  let tool_call_decoder = {
    use id <- decode.field("id", decode.string)
    use func <- decode.field("function", function_decoder)
    decode.success(ToolCall(id: id, name: func.0, arguments: func.1))
  }
  case json.parse(json_str, decode.list(tool_call_decoder)) {
    Ok(calls) -> calls
    Error(_) -> []
  }
}

/// Parse a JSON array of flat tool calls as produced by the streaming FFI:
/// `[{"id":"...","name":"...","arguments":"..."}]`.
/// Returns Ok(list) or Error(message).
pub fn parse_flat_tool_calls_json(json_str: String) -> Result(List(ToolCall), String) {
  let decoder = decode.list({
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    decode.success(ToolCall(id: id, name: name, arguments: arguments))
  })
  json.parse(json_str, decoder)
  |> result.map_error(fn(_) { "Failed to parse tool calls JSON" })
}

@external(erlang, "aura_stream_ffi", "chat_stream")
fn stream_ffi(
  url: String,
  api_key: String,
  model: String,
  body_json: String,
  callback_pid: process.Pid,
) -> Nil
