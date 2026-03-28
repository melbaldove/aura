import aura/llm
import gleam/json
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
