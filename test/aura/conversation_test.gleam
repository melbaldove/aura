import aura/conversation
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should

pub fn empty_buffer_test() {
  let buffers = conversation.new()
  conversation.get_history(buffers, "chan-123")
  |> list.length
  |> should.equal(0)
}

pub fn append_and_retrieve_test() {
  let buffers = conversation.new()
  let buffers = conversation.append(buffers, "chan-123", "Hello", "Hi there!")
  conversation.get_history(buffers, "chan-123")
  |> list.length
  |> should.equal(2)
}

pub fn separate_channels_test() {
  let buffers =
    conversation.new()
    |> conversation.append("chan-1", "msg1", "resp1")
    |> conversation.append("chan-2", "msg2", "resp2")
  conversation.get_history(buffers, "chan-1") |> list.length |> should.equal(2)
  conversation.get_history(buffers, "chan-2") |> list.length |> should.equal(2)
}

pub fn append_does_not_cap_test() {
  // append no longer caps — compression handles overflow separately
  let buffers =
    int.range(from: 1, to: 26, with: conversation.new(), run: fn(buf, i) {
      conversation.append(
        buf,
        "chan-1",
        "user " <> int.to_string(i),
        "bot " <> int.to_string(i),
      )
    })
  // 25 pairs = 50 messages, no cap applied
  conversation.get_history(buffers, "chan-1") |> list.length |> should.equal(50)
}

pub fn needs_compression_test() {
  // Build a buffer with enough tokens to trigger compression
  // 200K context window, trigger at 50% = 100K tokens = 400K chars
  // Use small window for testing: 100 tokens = 400 chars
  let buffers =
    conversation.append(
      conversation.new(),
      "chan-1",
      string.repeat("x", 300),
      string.repeat("y", 300),
    )
  // 600 chars = 150 tokens. At context_window=200, threshold=100 tokens -> should trigger
  should.be_true(conversation.needs_compression(buffers, "chan-1", 200))
  // At context_window=2000, threshold=1000 tokens -> should NOT trigger
  should.be_false(conversation.needs_compression(buffers, "chan-1", 2000))
}

pub fn format_traces_test() {
  let traces = [
    conversation.ToolTrace(
      name: "list_directory",
      args: ".",
      result: "events.jsonl, skills, domains",
      is_error: False,
    ),
    conversation.ToolTrace(
      name: "read_file",
      args: "SOUL.md",
      result: "# SOUL\nYou are Aura.",
      is_error: False,
    ),
  ]
  let formatted = conversation.format_traces(traces)
  formatted |> string.contains("list_directory") |> should.be_true
  formatted |> string.contains("read_file") |> should.be_true
}

pub fn format_traces_error_test() {
  let traces = [
    conversation.ToolTrace(
      name: "write_file",
      args: "SOUL.md",
      result: "Error: requires approval",
      is_error: True,
    ),
  ]
  let formatted = conversation.format_traces(traces)
  formatted |> string.contains("> write_file") |> should.be_true
  formatted
  |> string.contains("error=\"Error: requires approval\"")
  |> should.be_true
}

pub fn format_full_message_test() {
  let traces = [
    conversation.ToolTrace(
      name: "list_directory",
      args: ".",
      result: "3 entries",
      is_error: False,
    ),
  ]
  let full = conversation.format_full_message(traces, "Here are the contents.")
  full |> string.contains("list_directory") |> should.be_true
  full |> string.contains("Here are the contents") |> should.be_true
}

pub fn format_full_message_puts_compact_tool_calls_before_answer_test() {
  let traces = [
    conversation.ToolTrace(
      name: "read_file",
      args: "{\"path\":\"src/aura/channel_actor.gleam\"}",
      result: "large file contents that should not be shown",
      is_error: False,
    ),
    conversation.ToolTrace(
      name: "shell",
      args: "{\"command\":\"nix develop --command gleam test\"}",
      result: "all tests passed",
      is_error: False,
    ),
  ]

  let full = conversation.format_full_message(traces, "Here is the answer.")

  full
  |> string.starts_with(
    "> read_file path=\"src/aura/channel_actor.gleam\"\n> shell command=\"nix develop --command gleam test\"\n\nHere is the answer.",
  )
  |> should.be_true
  full |> string.contains("large file contents") |> should.be_false
  full |> string.contains("all tests passed") |> should.be_false
}

pub fn format_full_message_includes_short_tool_errors_test() {
  let traces = [
    conversation.ToolTrace(
      name: "shell",
      args: "{\"command\":\"gleam test\"}",
      result: "Error: Gleam version mismatch\nexpected v1.14+",
      is_error: True,
    ),
  ]

  let full = conversation.format_full_message(traces, "I could not run tests.")

  full
  |> string.contains(
    "> shell command=\"gleam test\" error=\"Error: Gleam version mismatch expected v1.14+\"",
  )
  |> should.be_true
  full |> string.contains("\n\nI could not run tests.") |> should.be_true
}

pub fn format_full_message_trims_tools_before_answer_test() {
  let answer = string.repeat("a", 1700)
  let traces =
    list.map(list.range(1, 40), fn(i) {
      conversation.ToolTrace(
        name: "read_file",
        args: "{\"path\":\"src/aura/very-long-path-"
          <> int.to_string(i)
          <> "-"
          <> string.repeat("x", 80)
          <> ".gleam\"}",
        result: string.repeat("result", 100),
        is_error: False,
      )
    })

  let full = conversation.format_full_message(traces, answer)

  full |> string.ends_with(answer) |> should.be_true
  { string.length(full) <= 1990 } |> should.be_true
  full |> string.contains("resultresult") |> should.be_false
}

pub fn format_no_traces_test() {
  conversation.format_full_message([], "Just a response.")
  |> should.equal("Just a response.")
}
