//// Test double for `LLMClient`. Production streaming LLM calls emit tagged
//// messages to a callback Pid as SSE events arrive. This fake reproduces
//// the exact same tagged-tuple protocol via an Erlang FFI shim so that
//// receiver code (brain, channel_actor) pattern-matches the fake output
//// identically to the real one — no production changes required.
////
//// Usage:
////
////   let #(fake, client) = fake_llm.new()
////   fake_llm.script_text_response(fake, "hi")
////   client.stream_with_tools(config, msgs, tools, process.self())
////
//// Each scripted response is consumed by the next `stream_with_tools` call.
//// Events in a script are replayed to the callback Pid with a small delay
//// between them so ordering is deterministic on the receiver.

import aura/clients/llm_client.{type LLMClient, LLMClient}
import aura/llm
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/otp/actor
import gleam/string

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One event in a scripted LLM response. Mirrors the production stream tags.
pub type ScriptedEvent {
  Delta(text: String)
  Reasoning
  Complete(content: String, tool_calls_json: String, prompt_tokens: Int)
  ErrorEvent(reason: String)
}

/// A recorded call to `stream_with_tools`, capturing what the production
/// code requested. Use `fake_llm.calls/1` to inspect.
pub type LlmCall {
  LlmCall(messages: List(llm.Message), tools: List(llm.ToolDefinition))
}

pub opaque type FakeLLM {
  FakeLLM(subject: process.Subject(Msg))
}

// ---------------------------------------------------------------------------
// Internal actor
// ---------------------------------------------------------------------------

type State {
  State(scripts: List(List(ScriptedEvent)), calls: List(LlmCall))
}

type Msg {
  PushScript(events: List(ScriptedEvent))
  Consume(
    call: LlmCall,
    callback_pid: Pid,
    reply: process.Subject(Nil),
  )
  GetCalls(reply: process.Subject(List(LlmCall)))
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    PushScript(events:) ->
      actor.continue(State(
        scripts: list.append(state.scripts, [events]),
        calls: state.calls,
      ))

    Consume(call:, callback_pid:, reply:) -> {
      let #(events, rest) = case state.scripts {
        [] -> #([], [])
        [first, ..tail] -> #(first, tail)
      }
      // Spawn the replayer so the caller's stream_with_tools returns
      // immediately (mirrors production where the FFI runs async).
      let _ = process.spawn_unlinked(fn() { replay(events, callback_pid) })
      process.send(reply, Nil)
      actor.continue(State(
        scripts: rest,
        calls: list.append(state.calls, [call]),
      ))
    }

    GetCalls(reply:) -> {
      process.send(reply, state.calls)
      actor.continue(state)
    }
  }
}

// 5ms between events so receivers see them in order (matches production
// pacing closely enough for pattern-match-based tests).
fn replay(events: List(ScriptedEvent), callback_pid: Pid) -> Nil {
  case events {
    [] -> Nil
    [event, ..rest] -> {
      emit(event, callback_pid)
      process.sleep(5)
      replay(rest, callback_pid)
    }
  }
}

fn emit(event: ScriptedEvent, callback_pid: Pid) -> Nil {
  case event {
    Delta(text:) -> send_stream_delta(callback_pid, text)
    Reasoning -> send_stream_reasoning(callback_pid)
    Complete(content:, tool_calls_json:, prompt_tokens:) ->
      send_stream_complete(
        callback_pid,
        content,
        tool_calls_json,
        prompt_tokens,
      )
    ErrorEvent(reason:) -> send_stream_error(callback_pid, reason)
  }
}

// ---------------------------------------------------------------------------
// FFI bindings — see src/fake_llm_ffi.erl
// ---------------------------------------------------------------------------

@external(erlang, "fake_llm_ffi", "stream_delta")
fn send_stream_delta(pid: Pid, text: String) -> Nil

@external(erlang, "fake_llm_ffi", "stream_reasoning")
fn send_stream_reasoning(pid: Pid) -> Nil

@external(erlang, "fake_llm_ffi", "stream_complete")
fn send_stream_complete(
  pid: Pid,
  content: String,
  tool_calls_json: String,
  prompt_tokens: Int,
) -> Nil

@external(erlang, "fake_llm_ffi", "stream_error")
fn send_stream_error(pid: Pid, reason: String) -> Nil

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create a new fake LLM. Returns a `#(FakeLLM, LLMClient)` pair — use
/// `FakeLLM` to script responses and inspect recorded calls, inject
/// `LLMClient` into code under test.
pub fn new() -> #(FakeLLM, LLMClient) {
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let state = State(scripts: [], calls: [])
      Ok(actor.initialised(state) |> actor.returning(subject))
    })
    |> actor.on_message(handle_message)

  let assert Ok(started) = actor.start(builder)
  let subj = started.data
  let fake = FakeLLM(subject: subj)

  let client =
    LLMClient(
      stream_with_tools: fn(_config, messages, tools, callback_pid) {
        let call = LlmCall(messages: messages, tools: tools)
        process.call(subj, 1000, fn(reply) {
          Consume(call: call, callback_pid: callback_pid, reply: reply)
        })
      },
      chat: fn(_config, _messages, _tools) {
        Error("fake_llm: non-streaming chat not scripted in this test")
      },
    )

  #(fake, client)
}

/// Push one scripted response onto the queue. Each `stream_with_tools` call
/// consumes one scripted response in FIFO order.
pub fn script(fake: FakeLLM, events: List(ScriptedEvent)) -> Nil {
  process.send(fake.subject, PushScript(events: events))
}

/// Shortcut: push a scripted response that emits one `Delta(text)` then a
/// `Complete("", "[]", 0)`. Matches the common "plain text reply" case.
pub fn script_text_response(fake: FakeLLM, text: String) -> Nil {
  script(fake, [
    Delta(text: text),
    Complete(content: "", tool_calls_json: "[]", prompt_tokens: 0),
  ])
}

/// Shortcut: push a scripted response that emits a `Complete` carrying a
/// single tool call (no content delta). The JSON matches the flat format
/// produced by `aura_stream_ffi:tool_calls_to_json/1`.
pub fn script_tool_call(
  fake: FakeLLM,
  tool_name: String,
  args_json: String,
) -> Nil {
  let escaped =
    args_json
    |> string.replace(each: "\\", with: "\\\\")
    |> string.replace(each: "\"", with: "\\\"")
  let tc_json =
    "[{\"id\":\"call_fake_1\",\"name\":\""
    <> tool_name
    <> "\",\"arguments\":\""
    <> escaped
    <> "\"}]"
  script(fake, [
    Complete(content: "", tool_calls_json: tc_json, prompt_tokens: 0),
  ])
}

/// Push an empty scripted response — the next `stream_with_tools` call
/// returns but emits nothing to the callback Pid (simulates a hang).
pub fn script_hang(fake: FakeLLM) -> Nil {
  script(fake, [])
}

/// Push a scripted response that emits a single `ErrorEvent`.
pub fn script_error(fake: FakeLLM, reason: String) -> Nil {
  script(fake, [ErrorEvent(reason: reason)])
}

/// Push a scripted response that emits 500 reasoning pulses — simulates a
/// model stuck in its thinking phase with no content progress.
pub fn script_reasoning_forever(fake: FakeLLM) -> Nil {
  script(fake, list.repeat(Reasoning, 500))
}

/// Return every recorded call to `stream_with_tools`, in order.
pub fn calls(fake: FakeLLM) -> List(LlmCall) {
  process.call(fake.subject, 1000, fn(reply) { GetCalls(reply: reply) })
}
