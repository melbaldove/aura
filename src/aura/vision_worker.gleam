//// Vision worker: runs one image-description LLM call.
////
//// Preprocessing happens before the main tool loop — enrich the user's
//// message with a textual description of any image attachment. Calls the
//// non-streaming `chat_text` path on LLMClient so fakes can script
//// deterministic descriptions.

import aura/channel_actor
import aura/llm
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option}

/// Spawn a vision worker. Given a `chat_text_fn` matching LLMClient.chat_text,
/// a config, a list of messages (typically one UserMessageWithImage), and a
/// temperature, invokes the LLM and forwards the outcome as VisionComplete or
/// VisionError to the parent. Exits when done.
pub fn spawn(
  chat_text_fn: fn(llm.LlmConfig, List(llm.Message), Option(Float)) ->
    Result(String, String),
  config: llm.LlmConfig,
  messages: List(llm.Message),
  temperature: Option(Float),
  parent: Subject(channel_actor.ChannelMessage),
) -> Pid {
  process.spawn(fn() {
    case chat_text_fn(config, messages, temperature) {
      Ok(description) ->
        process.send(parent, channel_actor.VisionComplete(description))
      Error(reason) ->
        process.send(parent, channel_actor.VisionError(reason))
    }
  })
}
