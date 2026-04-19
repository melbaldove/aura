//// Dependency-injected LLM client. Wraps streaming and non-streaming chat
//// calls from `aura/llm`. Tests substitute a fake client via
//// `test/fakes/fake_llm.new()` (later tasks).

import aura/llm
import gleam/erlang/process.{type Pid}

pub type LLMClient {
  LLMClient(
    stream_with_tools: fn(
      llm.LlmConfig,
      List(llm.Message),
      List(llm.ToolDefinition),
      Pid,
    ) -> Nil,
    chat: fn(
      llm.LlmConfig,
      List(llm.Message),
      List(llm.ToolDefinition),
    ) -> Result(llm.LlmResponse, String),
  )
}

pub fn production() -> LLMClient {
  LLMClient(
    stream_with_tools: llm.chat_streaming_with_tools,
    chat: llm.chat_with_tools,
  )
}
