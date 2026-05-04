//// Stream worker: wraps one LLM streaming call.
////
//// Runs in its own process because the FFI mailbox delivers raw tagged
//// tuples (`{stream_delta, Text}`, `stream_reasoning`, `{stream_complete, ...}`,
//// `{stream_error, Reason}`). Isolating here keeps those off the channel
//// actor's mailbox, so the actor only sees typed `ChannelMessage` variants.

import aura/channel_actor
import aura/llm
import gleam/erlang/process.{type Pid, type Subject}

/// Spawn a stream worker. Given a `stream_fn` matching LLMClient.stream_with_tools,
/// the worker calls it with `self_pid` as the callback, then translates the
/// incoming FFI events and forwards them as ChannelMessages to `parent`.
pub fn spawn(
  stream_fn: fn(llm.LlmConfig, List(llm.Message), List(llm.ToolDefinition), Pid) ->
    Nil,
  config: llm.LlmConfig,
  messages: List(llm.Message),
  tools: List(llm.ToolDefinition),
  parent: Subject(channel_actor.ChannelMessage),
) -> Pid {
  process.spawn(fn() {
    let callback_pid = process.self()
    let stream_pid =
      process.spawn(fn() {
        stream_fn(config, messages, tools, callback_pid)
      })
    receive_loop(parent, stream_pid)
  })
}

fn receive_loop(
  parent: Subject(channel_actor.ChannelMessage),
  stream_pid: Pid,
) -> Nil {
  let result = receive_ffi_message_ffi(120_000)
  case result {
    #("delta", text, _, _) -> {
      process.send(parent, channel_actor.StreamDelta(text))
      receive_loop(parent, stream_pid)
    }
    #("reasoning", _, _, _) -> {
      process.send(parent, channel_actor.StreamReasoning)
      receive_loop(parent, stream_pid)
    }
    #("complete", content, tool_calls_json, prompt_tokens) -> {
      process.send(
        parent,
        channel_actor.StreamComplete(content, tool_calls_json, prompt_tokens),
      )
    }
    #("error", reason, _, _) -> {
      process.send(parent, channel_actor.StreamError(reason))
    }
    #("timeout", _, _, _) -> {
      process.kill(stream_pid)
      process.send(parent, channel_actor.StreamError("idle timeout"))
    }
    _ -> {
      process.kill(stream_pid)
      process.send(parent, channel_actor.StreamError("unknown ffi message"))
    }
  }
}

@external(erlang, "aura_stream_ffi", "receive_stream_message")
fn receive_ffi_message_ffi(timeout_ms: Int) -> #(String, String, String, Int)
