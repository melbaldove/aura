import aura/channel_actor
import aura/llm
import aura/tool_worker
import gleam/erlang/process
import gleeunit/should
import test_harness

pub fn tool_worker_forwards_read_file_result_test() {
  // Build a standalone ToolContext — no full system needed for this test
  let ctx = test_harness.standalone_tool_context()

  // Build a read_file call against a file we know doesn't exist
  let call =
    llm.ToolCall(
      id: "call-1",
      name: "read_file",
      arguments: "{\"path\":\"/tmp/aura-worker-test-nonexistent\"}",
    )

  let parent: process.Subject(channel_actor.ChannelMessage) =
    process.new_subject()
  let _ = tool_worker.spawn(ctx, call, parent)

  let received = process.receive(parent, 2000)
  case received {
    Ok(channel_actor.ToolResult(call_id: "call-1", result: _, is_error: True)) ->
      Nil
    _ -> should.fail()
  }
}
