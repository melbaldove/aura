import aura/brain
import gleam/list
import gleeunit/should

pub fn parse_tool_args_valid_json_test() {
  let args = brain.parse_tool_args("{\"name\":\"google\",\"args\":\"calendar today\"}")
  list.length(args) |> should.equal(2)
}

pub fn parse_tool_args_concatenated_json_test() {
  let args = brain.parse_tool_args("{\"name\":\"google\",\"args\":\"a\"}{\"name\":\"jira\",\"args\":\"b\"}")
  let name = case list.find(args, fn(p) { p.0 == "name" }) {
    Ok(#(_, v)) -> v
    Error(_) -> ""
  }
  name |> should.equal("google")
}

pub fn parse_tool_args_invalid_json_test() {
  let args = brain.parse_tool_args("not json at all")
  let has_error = case list.find(args, fn(p) { p.0 == "_parse_error" }) {
    Ok(_) -> True
    Error(_) -> False
  }
  has_error |> should.be_true
}

pub fn parse_tool_args_empty_string_test() {
  let args = brain.parse_tool_args("")
  let has_error = case list.find(args, fn(p) { p.0 == "_parse_error" }) {
    Ok(_) -> True
    Error(_) -> False
  }
  has_error |> should.be_true
}
