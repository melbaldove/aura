import aura/acp/transport
import gleam/string
import gleeunit/should

pub fn buffer_tool_call_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Read\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Grep\"}")
  buf.tool_names |> should.equal(["Read", "Grep"])
}

pub fn buffer_tool_call_caps_at_5_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"A\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"B\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"C\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"D\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"E\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"F\"}")
  buf.tool_names |> should.equal(["B", "C", "D", "E", "F"])
}

pub fn buffer_agent_text_test() {
  let chunk1 =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"x\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Hello \"}}}}"
  let chunk2 =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"x\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"world\"}}}}"
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "agent_message_chunk", chunk1)
  let buf = transport.buffer_event(buf, "agent_message_chunk", chunk2)
  string.concat(buf.agent_chunks) |> should.equal("Hello world")
}

pub fn buffer_agent_text_resets_on_tool_call_test() {
  let chunk1 =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"x\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"First message\"}}}}"
  let chunk2 =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"x\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Second message\"}}}}"
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "agent_message_chunk", chunk1)
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Read\"}")
  let buf = transport.buffer_event(buf, "agent_message_chunk", chunk2)
  string.concat(buf.agent_chunks) |> should.equal("Second message")
  buf.tool_names |> should.equal(["Read"])
}

pub fn format_result_text_test() {
  let chunk =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"x\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"The feature is built but not enforced.\"}}}}"
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Read\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Write\"}")
  let buf = transport.buffer_event(buf, "agent_message_chunk", chunk)

  let result =
    transport.format_result_text(buf, "Read 8 files, checked pipeline")
  { result != "" } |> should.be_true
}

pub fn format_result_text_empty_summary_test() {
  let chunk =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"x\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Done.\"}}}}"
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "agent_message_chunk", chunk)

  let result = transport.format_result_text(buf, "")
  result |> should.not_equal("")
}

pub fn extract_agent_text_test() {
  let json =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"abc\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Hello world\"}}}}"
  transport.extract_agent_text(json) |> should.equal("Hello world")
}

pub fn extract_agent_text_with_newlines_test() {
  let json =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"abc\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"line1\\nline2\"}}}}"
  transport.extract_agent_text(json) |> should.equal("line1\nline2")
}

pub fn extract_agent_text_empty_test() {
  let json =
    "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"abc\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"\"}}}}"
  transport.extract_agent_text(json) |> should.equal("")
}

pub fn extract_tool_name_test() {
  transport.extract_tool_name("{\"toolName\":\"Read\"}") |> should.equal("Read")
  transport.extract_tool_name("{\"toolName\":\"Write\"}")
  |> should.equal("Write")
  transport.extract_tool_name("no tool here") |> should.equal("")
}
