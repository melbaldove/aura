import aura/codex_auth
import aura/codex_reasoning
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import logging

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
  ToolParam(
    name: String,
    param_type: String,
    description: String,
    required: Bool,
  )
}

/// Tool call from LLM response
pub type ToolCall {
  ToolCall(id: String, name: String, arguments: String)
}

/// LLM response that may contain both text and tool calls
pub type LlmResponse {
  LlmResponse(content: String, tool_calls: List(ToolCall))
}

type ParsedCodexOutput {
  ParsedCodexOutput(content: String, tool_calls: List(ToolCall))
}

pub type LlmConfig {
  LlmConfig(
    base_url: String,
    api_key: String,
    model: String,
    codex_reasoning_effort: String,
  )
}

pub const openai_codex_base_url = "https://chatgpt.com/backend-api/codex"

pub fn is_openai_codex_config(config: LlmConfig) -> Bool {
  config.base_url == openai_codex_base_url
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
    decode.at(
      ["choices"],
      decode.list(decode.at(["message", "content"], decode.string)),
    )
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
  let body = case is_openai_codex_config(config) {
    True ->
      build_codex_responses_body_with_reasoning_effort(
        config.model,
        messages,
        [],
        False,
        config.codex_reasoning_effort,
      )
    False -> build_request_body(config.model, messages, temperature)
  } |> json.to_string
  use resp <- result.try(post_chat(config, body, ""))
  case is_openai_codex_config(config) {
    True ->
      parse_codex_response_with_tools(resp)
      |> result.map(fn(response) { response.content })
    False -> parse_response(resp)
  }
}

/// Make a non-streaming chat completion request with tool definitions.
/// Returns the full LlmResponse (content + tool_calls).
pub fn chat_with_tools(
  config: LlmConfig,
  messages: List(Message),
  tools: List(ToolDefinition),
) -> Result(LlmResponse, String) {
  let body = case is_openai_codex_config(config) {
    True ->
      build_codex_responses_body_with_reasoning_effort(
        config.model,
        messages,
        tools,
        False,
        config.codex_reasoning_effort,
      )
    False -> build_request_body_with_tools(config.model, messages, tools, None)
  } |> json.to_string
  use resp <- result.try(post_chat(config, body, " (with tools)"))
  case is_openai_codex_config(config) {
    True -> parse_codex_response_with_tools(resp)
    False -> parse_response_with_tools(resp)
  }
}

/// Shared HTTP POST for chat completions. Returns the response body on 200.
fn post_chat(
  config: LlmConfig,
  body: String,
  label: String,
) -> Result(String, String) {
  let config = config_with_fresh_codex_auth(config)
  use resp <- result.try(dispatch_post_chat(config, body, label))
  let #(status, resp_body) = resp
  case status {
    200 -> Ok(resp_body)
    401 ->
      case is_openai_codex_config(config) {
        True -> retry_post_chat_after_codex_refresh(config, body, label)
        False -> api_error(config, status, resp_body)
      }
    _ -> api_error(config, status, resp_body)
  }
}

fn dispatch_post_chat(
  config: LlmConfig,
  body: String,
  label: String,
) -> Result(#(Int, String), String) {
  let url = case is_openai_codex_config(config) {
    True -> config.base_url <> "/responses"
    False -> config.base_url <> "/chat/completions"
  }
  logging.log(
    logging.Info,
    "[llm] Calling " <> config.model <> " at " <> url <> label,
  )
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
    |> set_auth_headers(config)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(120_000)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) { "HTTP request failed: " <> string.inspect(e) }),
  )
  Ok(#(resp.status, resp.body))
}

fn retry_post_chat_after_codex_refresh(
  config: LlmConfig,
  body: String,
  label: String,
) -> Result(String, String) {
  logging.log(
    logging.Info,
    "[llm] Refreshing Codex OAuth token after 401 from " <> config.model,
  )
  use auth <- result.try(
    codex_auth.refresh_from_auth_json()
    |> result.map_error(fn(err) {
      "LLM API error (status 401); Codex token refresh failed: " <> err
    }),
  )
  let config = LlmConfig(..config, api_key: codex_auth.encode(auth))
  use resp <- result.try(dispatch_post_chat(config, body, label <> " retry"))
  let #(status, resp_body) = resp
  case status {
    200 -> Ok(resp_body)
    _ -> api_error(config, status, resp_body)
  }
}

fn api_error(
  config: LlmConfig,
  status: Int,
  body: String,
) -> Result(String, String) {
  logging.log(
    logging.Error,
    "[llm] Error from "
      <> config.model
      <> ": status "
      <> int.to_string(status),
  )
  Error(
    "LLM API error (status "
    <> int.to_string(status)
    <> "): "
    <> string.slice(body, 0, 200),
  )
}

fn config_with_fresh_codex_auth(config: LlmConfig) -> LlmConfig {
  case is_openai_codex_config(config) {
    False -> config
    True ->
      case codex_auth.load() {
        Ok(auth) -> LlmConfig(..config, api_key: codex_auth.encode(auth))
        Error(_) -> config
      }
  }
}

fn set_auth_headers(
  req: request.Request(String),
  config: LlmConfig,
) -> request.Request(String) {
  case is_openai_codex_config(config) {
    False -> request.set_header(req, "authorization", "Bearer " <> config.api_key)
    True -> {
      let auth = codex_auth.decode(config.api_key)
      let req =
        req
        |> request.set_header("authorization", "Bearer " <> auth.access_token)
        |> request.set_header("originator", "codex_cli_rs")
        |> request.set_header("user-agent", "codex_cli_rs/0.0.1 (aura)")
      case auth.account_id {
        "" -> req
        account_id ->
          request.set_header(req, "ChatGPT-Account-ID", account_id)
      }
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

/// Encode a ToolDefinition as OpenAI Responses function-tool format.
pub fn codex_tool_definition_to_json(tool: ToolDefinition) -> json.Json {
  let properties =
    list.map(tool.parameters, tool_param_to_property)
    |> json.object
  let required =
    list.filter(tool.parameters, fn(p) { p.required })
    |> list.map(fn(p) { p.name })
  json.object([
    #("type", json.string("function")),
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #("strict", json.bool(False)),
    #(
      "parameters",
      json.object([
        #("type", json.string("object")),
        #("properties", properties),
        #("required", json.array(required, json.string)),
      ]),
    ),
  ])
}

fn codex_text_part(role: String, content: String) -> json.Json {
  let part_type = case role {
    "assistant" -> "output_text"
    _ -> "input_text"
  }
  json.object([
    #("type", json.string(part_type)),
    #("text", json.string(content)),
  ])
}

fn codex_text_message(role: String, content: String) -> json.Json {
  json.object([
    #("type", json.string("message")),
    #("role", json.string(role)),
    #(
      "content",
      json.preprocessed_array([codex_text_part(role, content)]),
    ),
  ])
}

fn codex_image_message(content: String, image_url: String) -> json.Json {
  let text_part =
    json.object([
      #("type", json.string("input_text")),
      #("text", json.string(content)),
    ])
  let image_part =
    json.object([
      #("type", json.string("input_image")),
      #("image_url", json.string(image_url)),
    ])
  json.object([
    #("type", json.string("message")),
    #("role", json.string("user")),
    #("content", json.preprocessed_array([text_part, image_part])),
  ])
}

fn codex_function_call_item(call: ToolCall) -> json.Json {
  json.object([
    #("type", json.string("function_call")),
    #("call_id", json.string(call.id)),
    #("name", json.string(call.name)),
    #("arguments", json.string(call.arguments)),
  ])
}

fn codex_function_call_output_item(
  tool_call_id: String,
  content: String,
) -> json.Json {
  json.object([
    #("type", json.string("function_call_output")),
    #("call_id", json.string(tool_call_id)),
    #("output", json.string(content)),
  ])
}

fn codex_input_items(messages: List(Message)) -> List(json.Json) {
  let #(items, _) =
    list.fold(messages, #([], []), fn(acc, message) {
      let #(items, known_call_ids) = acc
      case message {
        SystemMessage(_) -> #(items, known_call_ids)
        UserMessage(c) ->
          #(list.append(items, [codex_text_message("user", c)]), known_call_ids)
        UserMessageWithImage(c, url) ->
          #(list.append(items, [codex_image_message(c, url)]), known_call_ids)
        AssistantMessage(c) ->
          #(
            list.append(items, [codex_text_message("assistant", c)]),
            known_call_ids,
          )
        AssistantToolCallMessage(c, calls) -> {
          let content_items = case c {
            "" -> []
            _ -> [codex_text_message("assistant", c)]
          }
          let call_items = list.map(calls, codex_function_call_item)
          let call_ids = list.map(calls, fn(call) { call.id })
          #(
            list.append(items, list.append(content_items, call_items)),
            list.append(known_call_ids, call_ids),
          )
        }
        ToolResultMessage(id, c) ->
          case list.contains(known_call_ids, id) {
            True ->
              #(
                list.append(items, [codex_function_call_output_item(id, c)]),
                known_call_ids,
              )
            False -> #(items, known_call_ids)
          }
      }
    })
  items
}

fn codex_instructions(messages: List(Message)) -> String {
  let instructions =
    messages
    |> list.filter_map(fn(message) {
      case message {
        SystemMessage(c) -> Ok(c)
        _ -> Error(Nil)
      }
    })
    |> string.join("\n\n")
  case instructions {
    "" -> "You are a helpful assistant."
    _ -> instructions
  }
}

fn codex_reasoning_config(effort: String) -> json.Json {
  json.object([
    #("effort", json.string(codex_reasoning.normalize(effort))),
    #("summary", json.string("auto")),
  ])
}

fn codex_text_config() -> json.Json {
  json.object([#("verbosity", json.string("low"))])
}

/// Build the request body JSON for the Codex/Responses route.
pub fn build_codex_responses_body(
  model: String,
  messages: List(Message),
  tools: List(ToolDefinition),
  stream: Bool,
) -> json.Json {
  build_codex_responses_body_with_reasoning_effort(
    model,
    messages,
    tools,
    stream,
    codex_reasoning.default_effort,
  )
}

pub fn build_codex_responses_body_with_reasoning_effort(
  model: String,
  messages: List(Message),
  tools: List(ToolDefinition),
  stream: Bool,
  reasoning_effort: String,
) -> json.Json {
  let input_items = codex_input_items(messages)
  let base_fields = [
    #("model", json.string(model)),
    #("instructions", json.string(codex_instructions(messages))),
    #("input", json.preprocessed_array(input_items)),
    #("store", json.bool(False)),
    #("stream", json.bool(stream)),
    #("reasoning", codex_reasoning_config(reasoning_effort)),
    #("text", codex_text_config()),
  ]
  let fields = case tools {
    [] -> base_fields
    _ ->
      list.append(base_fields, [
        #("tools", json.array(tools, codex_tool_definition_to_json)),
        #("tool_choice", json.string("auto")),
      ])
  }
  json.object(fields)
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

/// Parse a Responses API body from Codex/OpenAI.
pub fn parse_codex_response_with_tools(
  body: String,
) -> Result(LlmResponse, String) {
  let content_item_decoder = {
    use item_type <- decode.field("type", decode.string)
    use text <- decode.optional_field("text", "", decode.string)
    case item_type {
      "output_text" -> decode.success(text)
      _ -> decode.success("")
    }
  }
  let output_item_decoder = {
    use item_type <- decode.field("type", decode.string)
    case item_type {
      "message" -> {
        use texts <- decode.field(
          "content",
          decode.list(content_item_decoder),
        )
        decode.success(ParsedCodexOutput(
          content: texts
            |> list.filter(fn(text) { text != "" })
            |> string.join(""),
          tool_calls: [],
        ))
      }
      "function_call" -> {
        use call_id <- decode.field("call_id", decode.string)
        use name <- decode.field("name", decode.string)
        use arguments <- decode.field("arguments", decode.string)
        decode.success(ParsedCodexOutput(
          content: "",
          tool_calls: [ToolCall(id: call_id, name: name, arguments: arguments)],
        ))
      }
      _ -> decode.success(ParsedCodexOutput(content: "", tool_calls: []))
    }
  }
  let output_decoder =
    decode.at(["output"], decode.list(output_item_decoder))

  case json.parse(body, output_decoder) {
    Ok(items) ->
      Ok(LlmResponse(
        content: items
          |> list.map(fn(item) { item.content })
          |> string.join(""),
        tool_calls: items |> list.flat_map(fn(item) { item.tool_calls }),
      ))
    Error(_) ->
      json.parse(body, decode.at(["output_text"], decode.string))
      |> result.map(fn(content) {
        LlmResponse(content: content, tool_calls: [])
      })
      |> result.map_error(fn(_) { "Failed to parse Codex response JSON" })
  }
}

// ---------------------------------------------------------------------------
// Streaming
// ---------------------------------------------------------------------------

/// Start a streaming chat completion request WITH tool definitions.
/// The Erlang FFI sends events to callback_pid:
///   {stream_delta, Content}        — text content chunk
///   stream_reasoning               — GLM-5.1 thinking token
///   {stream_complete, Content, ToolCallsJson, PromptTokens} — final result
///   {stream_error, Reason}         — fatal error
/// This function blocks until the stream completes (run in a spawned process).
pub fn chat_streaming_with_tools(
  config: LlmConfig,
  messages: List(Message),
  tools: List(ToolDefinition),
  callback_pid: process.Pid,
) -> Nil {
  let config = config_with_fresh_codex_auth(config)
  let url = case is_openai_codex_config(config) {
    True -> config.base_url <> "/responses"
    False -> config.base_url <> "/chat/completions"
  }
  let stream_label = case is_openai_codex_config(config) {
    True ->
      " (with tools, reasoning="
      <> codex_reasoning.normalize(config.codex_reasoning_effort)
      <> ")"
    False -> " (with tools)"
  }
  logging.log(
    logging.Info,
    "[llm] Streaming " <> config.model <> " at " <> url <> stream_label,
  )
  let body_str = case is_openai_codex_config(config) {
    True ->
      build_codex_responses_body_with_reasoning_effort(
        config.model,
        messages,
        tools,
        True,
        config.codex_reasoning_effort,
      )
      |> json.to_string
    False -> {
      let base_fields = [
        #("model", json.string(config.model)),
        #("messages", json.array(messages, message_to_json)),
        #("stream", json.bool(True)),
        #(
          "stream_options",
          json.object([#("include_usage", json.bool(True))]),
        ),
      ]
      let fields = case tools {
        [] -> base_fields
        _ ->
          list.append(base_fields, [
            #("tools", json.array(tools, tool_definition_to_json)),
          ])
      }
      json.object(fields) |> json.to_string
    }
  }
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
pub fn parse_flat_tool_calls_json(
  json_str: String,
) -> Result(List(ToolCall), String) {
  let decoder =
    decode.list({
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
