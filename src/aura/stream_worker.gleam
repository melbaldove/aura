//// Stream worker: wraps one LLM streaming call.
////
//// Runs in its own process because the FFI mailbox delivers raw tagged
//// tuples (`{stream_delta, Text}`, `stream_reasoning`, `{stream_complete, ...}`,
//// `{stream_error, Reason}`). Isolating here keeps those off the channel
//// actor's mailbox, so the actor only sees typed `ChannelMessage` variants.

import aura/channel_actor
import aura/llm
import gleam/erlang/process.{type Pid, type Subject}
import logging

// The provider transport owns its model-specific idle timeout (120 seconds
// normally, 600 seconds for Codex). This outer watchdog is only a safety net
// in case the transport itself fails to report completion.
const stream_safety_timeout_ms = 610_000

const cancel_ack_timeout_ms = 1000

type CancelOutcome {
  CancelConfirmed
  StreamFinished
  CancelUnconfirmed
}

/// Return the outer stream-worker safety timeout. Provider transports are
/// expected to report their own idle timeout before this fallback fires.
pub fn safety_timeout_ms() -> Int {
  stream_safety_timeout_ms
}

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
  spawn_with_idle_timeout(
    stream_fn,
    config,
    messages,
    tools,
    parent,
    safety_timeout_ms(),
  )
}

/// Spawn a stream worker with an explicit safety timeout. Production callers
/// use `spawn`; this entrypoint supports deterministic stall fault injection.
pub fn spawn_with_idle_timeout(
  stream_fn: fn(llm.LlmConfig, List(llm.Message), List(llm.ToolDefinition), Pid) ->
    Nil,
  config: llm.LlmConfig,
  messages: List(llm.Message),
  tools: List(llm.ToolDefinition),
  parent: Subject(channel_actor.ChannelMessage),
  idle_timeout_ms: Int,
) -> Pid {
  process.spawn(fn() {
    let callback_pid = process.self()
    let stream_pid =
      process.spawn(fn() { stream_fn(config, messages, tools, callback_pid) })
    receive_loop(parent, stream_pid, idle_timeout_ms)
  })
}

fn receive_loop(
  parent: Subject(channel_actor.ChannelMessage),
  stream_pid: Pid,
  idle_timeout_ms: Int,
) -> Nil {
  let result = receive_ffi_message_ffi(idle_timeout_ms)
  case result {
    #("delta", text, _, _) -> {
      process.send(parent, channel_actor.StreamDelta(text))
      receive_loop(parent, stream_pid, idle_timeout_ms)
    }
    #("reasoning", _, _, _) -> {
      process.send(parent, channel_actor.StreamReasoning)
      receive_loop(parent, stream_pid, idle_timeout_ms)
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
      cancel_active_stream(stream_pid, parent, "idle timeout")
    }
    _ -> {
      cancel_active_stream(stream_pid, parent, "unknown ffi message")
    }
  }
}

fn cancel_active_stream(
  stream_pid: Pid,
  parent: Subject(channel_actor.ChannelMessage),
  reason: String,
) -> Nil {
  cancel_stream_ffi(stream_pid)
  case await_cancel(parent, cancel_ack_timeout_ms) {
    CancelConfirmed -> process.send(parent, channel_actor.StreamError(reason))
    StreamFinished -> Nil
    CancelUnconfirmed -> {
      logging.log(
        logging.Error,
        "[stream_worker] Stream cancellation was not acknowledged; forcing process exit",
      )
      process.kill(stream_pid)
      process.send(parent, channel_actor.StreamError(reason))
    }
  }
}

fn await_cancel(
  parent: Subject(channel_actor.ChannelMessage),
  remaining_ms: Int,
) -> CancelOutcome {
  case remaining_ms <= 0 {
    True -> CancelUnconfirmed
    False -> {
      let wait_ms = case remaining_ms < 100 {
        True -> remaining_ms
        False -> 100
      }
      case receive_ffi_message_ffi(wait_ms) {
        #("cancelled", _, _, _) -> CancelConfirmed
        #("complete", content, tool_calls_json, prompt_tokens) -> {
          process.send(
            parent,
            channel_actor.StreamComplete(
              content,
              tool_calls_json,
              prompt_tokens,
            ),
          )
          StreamFinished
        }
        #("error", reason, _, _) -> {
          process.send(parent, channel_actor.StreamError(reason))
          StreamFinished
        }
        // A response can race with cancellation. Drop non-terminal events and
        // wait for either the cancellation acknowledgement or stream end.
        _ -> await_cancel(parent, remaining_ms - wait_ms)
      }
    }
  }
}

@external(erlang, "aura_stream_ffi", "receive_stream_message")
fn receive_ffi_message_ffi(timeout_ms: Int) -> #(String, String, String, Int)

@external(erlang, "aura_stream_ffi", "cancel_stream")
fn cancel_stream_ffi(stream_pid: Pid) -> Nil
