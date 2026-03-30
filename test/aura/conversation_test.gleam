import aura/conversation
import aura/test_helpers
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import simplifile

pub fn empty_buffer_test() {
  let buffers = conversation.new()
  conversation.get_history(buffers, "chan-123") |> list.length |> should.equal(0)
}

pub fn append_and_retrieve_test() {
  let buffers = conversation.new()
  let buffers = conversation.append(buffers, "chan-123", "Hello", "Hi there!")
  conversation.get_history(buffers, "chan-123") |> list.length |> should.equal(2)
}

pub fn separate_channels_test() {
  let buffers =
    conversation.new()
    |> conversation.append("chan-1", "msg1", "resp1")
    |> conversation.append("chan-2", "msg2", "resp2")
  conversation.get_history(buffers, "chan-1") |> list.length |> should.equal(2)
  conversation.get_history(buffers, "chan-2") |> list.length |> should.equal(2)
}

pub fn cap_at_20_pairs_test() {
  let buffers =
    list.range(1, 25)
    |> list.fold(conversation.new(), fn(buf, i) {
      conversation.append(
        buf,
        "chan-1",
        "user " <> int.to_string(i),
        "bot " <> int.to_string(i),
      )
    })
  conversation.get_history(buffers, "chan-1") |> list.length |> should.equal(40)
}

pub fn persist_and_load_test() {
  let base = "/tmp/aura-conv-test-" <> test_helpers.random_suffix()
  let _ = simplifile.create_directory_all(base <> "/conversations")
  let buffers =
    conversation.new()
    |> conversation.append("chan-test", "hello", "hi")
    |> conversation.append("chan-test", "how are you", "good")
  conversation.save(buffers, "chan-test", base) |> should.be_ok
  let loaded = conversation.load("chan-test", base) |> should.be_ok
  list.length(loaded) |> should.equal(4)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn format_traces_test() {
  let traces = [
    conversation.ToolTrace(
      name: "list_directory",
      args: ".",
      result: "events.jsonl, skills, workstreams",
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
  formatted |> string.contains("\u{274C}") |> should.be_true
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

pub fn format_no_traces_test() {
  conversation.format_full_message([], "Just a response.")
  |> should.equal("Just a response.")
}
