import gleam/dynamic/decode
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

pub type Message {
  SystemMessage(content: String)
  UserMessage(content: String)
  AssistantMessage(content: String)
}

pub type LlmConfig {
  LlmConfig(base_url: String, api_key: String, model: String)
}

/// Encode a Message as a JSON object with "role" and "content" fields.
pub fn message_to_json(message: Message) -> json.Json {
  let #(role, content) = case message {
    SystemMessage(c) -> #("system", c)
    UserMessage(c) -> #("user", c)
    AssistantMessage(c) -> #("assistant", c)
  }
  json.object([#("role", json.string(role)), #("content", json.string(content))])
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
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 -> parse_response(resp.body)
    status ->
      Error(
        "Unexpected status "
        <> int.to_string(status)
        <> ": "
        <> string.slice(resp.body, 0, 200),
      )
  }
}
