import aura/brain_tools
import aura/llm
import gleam/list
import gleeunit/should

pub fn parse_tool_args_valid_json_test() {
  let args = brain_tools.parse_tool_args("{\"name\":\"google\",\"args\":\"calendar today\"}")
  list.length(args) |> should.equal(2)
}

pub fn parse_tool_args_concatenated_json_test() {
  let args = brain_tools.parse_tool_args("{\"name\":\"google\",\"args\":\"a\"}{\"name\":\"jira\",\"args\":\"b\"}")
  let name = case list.find(args, fn(p) { p.0 == "name" }) {
    Ok(#(_, v)) -> v
    Error(_) -> ""
  }
  name |> should.equal("google")
}

pub fn parse_tool_args_invalid_json_test() {
  let args = brain_tools.parse_tool_args("not json at all")
  let has_error = case list.find(args, fn(p) { p.0 == "_parse_error" }) {
    Ok(_) -> True
    Error(_) -> False
  }
  has_error |> should.be_true
}

pub fn parse_tool_args_empty_string_test() {
  let args = brain_tools.parse_tool_args("")
  let has_error = case list.find(args, fn(p) { p.0 == "_parse_error" }) {
    Ok(_) -> True
    Error(_) -> False
  }
  has_error |> should.be_true
}

// ---------------------------------------------------------------------------
// expand_tool_calls tests
// ---------------------------------------------------------------------------

pub fn expand_tool_calls_no_concat_test() {
  let calls = [
    llm.ToolCall(id: "1", name: "jira", arguments: "{\"action\":\"list\"}"),
  ]
  let expanded = brain_tools.expand_tool_calls(calls)
  list.length(expanded) |> should.equal(1)
  case list.first(expanded) {
    Ok(c) -> {
      c.id |> should.equal("1")
      c.name |> should.equal("jira")
      c.arguments |> should.equal("{\"action\":\"list\"}")
    }
    Error(_) -> should.fail()
  }
}

pub fn expand_tool_calls_two_concat_test() {
  let calls = [
    llm.ToolCall(
      id: "1",
      name: "jira",
      arguments: "{\"name\":\"jira\",\"args\":\"[\\\"--instance\\\", \\\"HY\\\"]\"}{\"name\":\"jira\",\"args\":\"[\\\"--instance\\\", \\\"CM\\\"]\"}",
    ),
  ]
  let expanded = brain_tools.expand_tool_calls(calls)
  list.length(expanded) |> should.equal(2)
  case expanded {
    [first, second] -> {
      first.id |> should.equal("1_0")
      second.id |> should.equal("1_1")
      first.name |> should.equal("jira")
      second.name |> should.equal("jira")
    }
    _ -> should.fail()
  }
}

pub fn expand_tool_calls_three_concat_test() {
  let calls = [
    llm.ToolCall(
      id: "1",
      name: "run_skill",
      arguments: "{\"a\":\"1\"}{\"b\":\"2\"}{\"c\":\"3\"}",
    ),
  ]
  let expanded = brain_tools.expand_tool_calls(calls)
  list.length(expanded) |> should.equal(3)
  case expanded {
    [first, second, third] -> {
      first.id |> should.equal("1_0")
      first.arguments |> should.equal("{\"a\":\"1\"}")
      second.id |> should.equal("1_1")
      second.arguments |> should.equal("{\"b\":\"2\"}")
      third.id |> should.equal("1_2")
      third.arguments |> should.equal("{\"c\":\"3\"}")
    }
    _ -> should.fail()
  }
}

pub fn expand_tool_calls_mixed_names_test() {
  let calls = [
    llm.ToolCall(
      id: "1",
      name: "unknown",
      arguments: "{\"name\":\"jira\",\"args\":\"a\"}{\"name\":\"google\",\"args\":\"b\"}",
    ),
  ]
  let expanded = brain_tools.expand_tool_calls(calls)
  list.length(expanded) |> should.equal(2)
  case expanded {
    [first, second] -> {
      first.name |> should.equal("jira")
      second.name |> should.equal("google")
    }
    _ -> should.fail()
  }
}

pub fn expand_tool_calls_preserves_non_concat_test() {
  let calls = [
    llm.ToolCall(id: "1", name: "read_file", arguments: "{\"path\":\"foo.txt\"}"),
    llm.ToolCall(
      id: "2",
      name: "jira",
      arguments: "{\"name\":\"jira\",\"args\":\"a\"}{\"name\":\"jira\",\"args\":\"b\"}",
    ),
  ]
  let expanded = brain_tools.expand_tool_calls(calls)
  list.length(expanded) |> should.equal(3)
  case expanded {
    [first, second, third] -> {
      first.id |> should.equal("1")
      first.name |> should.equal("read_file")
      second.id |> should.equal("2_0")
      third.id |> should.equal("2_1")
    }
    _ -> should.fail()
  }
}
