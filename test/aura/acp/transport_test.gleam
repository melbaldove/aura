import aura/acp/transport
import gleeunit/should

pub fn buffer_tool_call_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Read\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Grep\"}")
  transport.tool_names(buf) |> should.equal(["Read", "Grep"])
}

pub fn buffer_tool_call_caps_at_5_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"A\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"B\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"C\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"D\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"E\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"F\"}")
  transport.tool_names(buf) |> should.equal(["B", "C", "D", "E", "F"])
}

pub fn buffer_agent_text_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "agent_message_chunk", "Hello ")
  let buf = transport.buffer_event(buf, "agent_message_chunk", "world")
  transport.agent_text(buf) |> should.equal("Hello world")
}

pub fn buffer_agent_text_resets_on_tool_call_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "agent_message_chunk", "First message")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Read\"}")
  let buf = transport.buffer_event(buf, "agent_message_chunk", "Second message")
  transport.agent_text(buf) |> should.equal("Second message")
  transport.tool_names(buf) |> should.equal(["Read"])
}

pub fn format_result_text_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Read\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Write\"}")
  let buf = transport.buffer_event(buf, "agent_message_chunk", "The feature is built but not enforced.")

  let result = transport.format_result_text(buf, "Read 8 files, checked pipeline")
  { result != "" } |> should.be_true
}

pub fn format_result_text_empty_summary_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "agent_message_chunk", "Done.")

  let result = transport.format_result_text(buf, "")
  result |> should.not_equal("")
}

pub fn extract_tool_name_test() {
  transport.extract_tool_name("{\"toolName\":\"Read\"}") |> should.equal("Read")
  transport.extract_tool_name("{\"toolName\":\"Write\"}") |> should.equal("Write")
  transport.extract_tool_name("no tool here") |> should.equal("")
}
