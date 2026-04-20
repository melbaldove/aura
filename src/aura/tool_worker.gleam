//// Tool worker: runs one tool execution, forwards result, exits.

import aura/brain_tools
import aura/channel_actor
import aura/llm
import gleam/erlang/process.{type Pid, type Subject}
import gleam/string

/// Spawn a tool worker. Given a ToolContext (client-aware) + the tool call
/// to execute, invokes `brain_tools.execute_tool` and forwards the outcome
/// as `ChannelMessage.ToolResult` to the parent. Exits when done.
pub fn spawn(
  ctx: brain_tools.ToolContext,
  call: llm.ToolCall,
  parent: Subject(channel_actor.ChannelMessage),
) -> Pid {
  process.spawn(fn() {
    let #(result, _parsed_args) = brain_tools.execute_tool(ctx, call)
    let #(text, is_error) = extract_result(result)
    process.send(
      parent,
      channel_actor.ToolResult(
        call_id: call.id,
        result: text,
        is_error: is_error,
      ),
    )
  })
}

fn extract_result(r: brain_tools.ToolResult) -> #(String, Bool) {
  case r {
    brain_tools.TextResult(text) -> #(text, string.starts_with(text, "Error"))
  }
}
