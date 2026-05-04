import aura/llm
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn build_request_body_test() {
  let body =
    llm.build_request_body(
      "glm-5-turbo",
      [
        llm.SystemMessage("You are a helpful assistant."),
        llm.UserMessage("Hello"),
      ],
      None,
    )
    |> json.to_string
  body |> string.contains("glm-5-turbo") |> should.be_true
  body |> string.contains("system") |> should.be_true
  body |> string.contains("Hello") |> should.be_true
}

pub fn build_request_body_with_temperature_test() {
  let body =
    llm.build_request_body("glm-5-turbo", [llm.UserMessage("test")], Some(0.7))
    |> json.to_string
  body |> string.contains("temperature") |> should.be_true
}

pub fn parse_response_test() {
  llm.parse_response(
    "{\"choices\":[{\"message\":{\"content\":\"Hello! How can I help?\"}}]}",
  )
  |> should.equal(Ok("Hello! How can I help?"))
}

pub fn parse_response_empty_test() {
  llm.parse_response("{\"choices\":[]}")
  |> should.be_error
}

pub fn message_to_json_test() {
  let json_str =
    llm.message_to_json(llm.AssistantMessage("I am Aura.")) |> json.to_string
  json_str |> string.contains("assistant") |> should.be_true
  json_str |> string.contains("I am Aura.") |> should.be_true
}

pub fn tool_definition_to_json_test() {
  let tool =
    llm.ToolDefinition(
      name: "write_file",
      description: "Write a file",
      parameters: [
        llm.ToolParam(
          name: "path",
          param_type: "string",
          description: "File path",
          required: True,
        ),
        llm.ToolParam(
          name: "content",
          param_type: "string",
          description: "Content",
          required: True,
        ),
      ],
    )
  let json_str = llm.tool_definition_to_json(tool) |> json.to_string
  json_str |> string.contains("write_file") |> should.be_true
  json_str |> string.contains("function") |> should.be_true
}

pub fn parse_response_with_tools_test() {
  let body =
    "{\"choices\":[{\"message\":{\"content\":\"Writing file.\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"write_file\",\"arguments\":\"{\\\"path\\\":\\\"test.md\\\",\\\"content\\\":\\\"hello\\\"}\"}}]}}]}"
  let result = llm.parse_response_with_tools(body) |> should.be_ok
  result.content |> should.equal("Writing file.")
  list.length(result.tool_calls) |> should.equal(1)
  let assert [call] = result.tool_calls
  call.name |> should.equal("write_file")
}

pub fn parse_response_no_tools_test() {
  let body = "{\"choices\":[{\"message\":{\"content\":\"Just text.\"}}]}"
  let result = llm.parse_response_with_tools(body) |> should.be_ok
  result.content |> should.equal("Just text.")
  list.length(result.tool_calls) |> should.equal(0)
}

pub fn parse_response_null_content_test() {
  // When model uses tools, content may be null
  let body =
    "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"SOUL.md\\\"}\"}}]}}]}"
  let result = llm.parse_response_with_tools(body) |> should.be_ok
  result.content |> should.equal("")
  list.length(result.tool_calls) |> should.equal(1)
}

pub fn tool_result_message_test() {
  let msg = llm.ToolResultMessage("call_1", "file content here")
  let json_str = llm.message_to_json(msg) |> json.to_string
  json_str |> string.contains("tool") |> should.be_true
  json_str |> string.contains("call_1") |> should.be_true
}

pub fn user_message_with_image_to_json_test() {
  let msg =
    llm.UserMessageWithImage(
      content: "Describe this image",
      image_url: "https://cdn.discordapp.com/attachments/123/456/image.png",
    )
  let json_str = llm.message_to_json(msg) |> json.to_string

  json_str |> string.contains("\"role\":\"user\"") |> should.be_true
  json_str |> string.contains("\"type\":\"text\"") |> should.be_true
  json_str |> string.contains("\"type\":\"image_url\"") |> should.be_true
  json_str |> string.contains("Describe this image") |> should.be_true
  json_str |> string.contains("image.png") |> should.be_true
}

pub fn build_codex_responses_body_with_tools_test() {
  let tool =
    llm.ToolDefinition(
      name: "read_file",
      description: "Read a file",
      parameters: [
        llm.ToolParam(
          name: "path",
          param_type: "string",
          description: "File path",
          required: True,
        ),
      ],
    )
  let body =
    llm.build_codex_responses_body(
      "gpt-5.5",
      [
        llm.SystemMessage("You are Aura."),
        llm.UserMessage("Read the README."),
        llm.AssistantToolCallMessage("", [
          llm.ToolCall(
            id: "call_1",
            name: "read_file",
            arguments: "{\"path\":\"README.md\"}",
          ),
        ]),
        llm.ToolResultMessage("call_1", "file content"),
      ],
      [tool],
      True,
    )
    |> json.to_string

  body |> string.contains("\"model\":\"gpt-5.5\"") |> should.be_true
  body |> string.contains("\"input\"") |> should.be_true
  body |> string.contains("\"messages\"") |> should.be_false
  body |> string.contains("\"function_call\"") |> should.be_true
  body |> string.contains("\"function_call_output\"") |> should.be_true
  body |> string.contains("\"call_id\":\"call_1\"") |> should.be_true
  body |> string.contains("\"tools\"") |> should.be_true
  body |> string.contains("\"name\":\"read_file\"") |> should.be_true
  body |> string.contains("\"function\":{\"name\"") |> should.be_false
  body |> string.contains("\"stream\":true") |> should.be_true
}

pub fn parse_codex_response_with_text_and_tool_call_test() {
  let body =
    "{\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"I need the file.\"}]},{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}]}"

  let result = llm.parse_codex_response_with_tools(body) |> should.be_ok

  result.content |> should.equal("I need the file.")
  list.length(result.tool_calls) |> should.equal(1)
  let assert [call] = result.tool_calls
  call.id |> should.equal("call_1")
  call.name |> should.equal("read_file")
}

pub fn parse_codex_response_output_text_helper_test() {
  let body = "{\"output_text\":\"Done.\"}"

  let result = llm.parse_codex_response_with_tools(body) |> should.be_ok

  result.content |> should.equal("Done.")
  list.length(result.tool_calls) |> should.equal(0)
}
