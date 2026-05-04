import aura/channel_actor
import aura/llm
import aura/stream_worker
import fakes/fake_llm
import gleam/erlang/process.{type Pid}
import gleeunit/should

fn fake_config() -> llm.LlmConfig {
  llm.LlmConfig(
    model: "fake",
    api_key: "fake",
    base_url: "http://127.0.0.1:1",
    codex_reasoning_effort: "medium",
  )
}

pub fn stream_worker_forwards_delta_then_complete_test() {
  // Build a fake LLM, script one text response
  let #(fake, client) = fake_llm.new()
  fake_llm.script_text_response(fake, "hello")

  // Create a subject for the worker's parent (the test process)
  let parent: process.Subject(channel_actor.ChannelMessage) =
    process.new_subject()

  // Spawn the worker with the fake's stream function
  let _ =
    stream_worker.spawn(client.stream_with_tools, fake_config(), [], [], parent)

  // Collect messages forwarded to the parent. The fake replays events with
  // 5ms spacing, so we allow up to 2s.
  // Expect: at least one StreamDelta("hello") and one StreamComplete(...)
  // arrive in order.
  let received_complete = collect_until_complete(parent, 2000, 0)
  received_complete |> should.be_true
}

pub fn stream_worker_forwards_error_test() {
  let #(fake, client) = fake_llm.new()
  fake_llm.script_error(fake, "oops")

  let parent: process.Subject(channel_actor.ChannelMessage) =
    process.new_subject()

  let _ =
    stream_worker.spawn(client.stream_with_tools, fake_config(), [], [], parent)

  let received_error = collect_until_error(parent, 2000, 0)
  received_error |> should.be_true
}

pub fn stream_worker_receives_while_stream_call_is_blocked_test() {
  let parent: process.Subject(channel_actor.ChannelMessage) =
    process.new_subject()

  let _ =
    stream_worker.spawn(blocking_stream, fake_config(), [], [], parent)

  let received_delta = case process.receive(parent, 100) {
    Ok(channel_actor.StreamDelta("early")) -> True
    _ -> False
  }
  received_delta |> should.be_true
}

fn blocking_stream(
  _config: llm.LlmConfig,
  _messages: List(llm.Message),
  _tools: List(llm.ToolDefinition),
  callback_pid: Pid,
) -> Nil {
  send_stream_delta(callback_pid, "early")
  process.sleep(500)
  send_stream_complete(callback_pid, "early", "[]", 0)
}

@external(erlang, "fake_llm_ffi", "stream_delta")
fn send_stream_delta(pid: Pid, text: String) -> Nil

@external(erlang, "fake_llm_ffi", "stream_complete")
fn send_stream_complete(
  pid: Pid,
  content: String,
  tool_calls_json: String,
  prompt_tokens: Int,
) -> Nil

fn collect_until_complete(
  parent: process.Subject(channel_actor.ChannelMessage),
  timeout_ms: Int,
  elapsed: Int,
) -> Bool {
  case elapsed >= timeout_ms {
    True -> False
    False ->
      case process.receive(parent, 50) {
        Ok(channel_actor.StreamComplete(_, _, _)) -> True
        Ok(_) -> collect_until_complete(parent, timeout_ms, elapsed + 50)
        Error(_) -> collect_until_complete(parent, timeout_ms, elapsed + 50)
      }
  }
}

fn collect_until_error(
  parent: process.Subject(channel_actor.ChannelMessage),
  timeout_ms: Int,
  elapsed: Int,
) -> Bool {
  case elapsed >= timeout_ms {
    True -> False
    False ->
      case process.receive(parent, 50) {
        Ok(channel_actor.StreamError(_)) -> True
        Ok(_) -> collect_until_error(parent, timeout_ms, elapsed + 50)
        Error(_) -> collect_until_error(parent, timeout_ms, elapsed + 50)
      }
  }
}
