import aura/llm
import fakes/fake_llm
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit/should

fn fake_config() -> llm.LlmConfig {
  llm.LlmConfig(
    base_url: "http://127.0.0.1:1",
    api_key: "fake",
    model: "fake-model",
  )
}

/// Spawn a receiver whose only job is to forward stream events to a
/// Subject owned by the caller. Using a dedicated process means the
/// callback mailbox is empty — no stray messages leaked from other tests
/// in the shared BEAM VM.
fn spawn_collector(collector: process.Subject(String)) -> process.Pid {
  process.spawn(fn() { collector_loop(collector) })
}

fn collector_loop(collector: process.Subject(String)) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_other(fn(_msg) { Nil })
  case process.selector_receive(selector, 5000) {
    Ok(_) -> {
      process.send(collector, "event")
      collector_loop(collector)
    }
    Error(_) -> Nil
  }
}

pub fn fake_llm_script_text_response_forwards_events_test() {
  let #(fake, client) = fake_llm.new()
  fake_llm.script_text_response(fake, "hello")

  let collector = process.new_subject()
  let callback = spawn_collector(collector)
  let _ = client.stream_with_tools(fake_config(), [], [], callback)

  // Expect the collector to forward at least one event (stream_delta).
  case process.receive(collector, 2000) {
    Ok(_) -> Nil
    Error(_) -> should.fail()
  }
}

pub fn fake_llm_script_hang_never_completes_test() {
  let #(fake, client) = fake_llm.new()
  fake_llm.script_hang(fake)

  let collector = process.new_subject()
  let callback = spawn_collector(collector)
  let _ = client.stream_with_tools(fake_config(), [], [], callback)

  // Expect no event in 100ms — script_hang means hang.
  case process.receive(collector, 100) {
    Ok(_) -> should.fail()
    Error(_) -> Nil
  }
}

pub fn fake_llm_records_call_history_test() {
  let #(fake, client) = fake_llm.new()
  fake_llm.script_text_response(fake, "a")
  fake_llm.script_text_response(fake, "b")

  let collector = process.new_subject()
  let callback = spawn_collector(collector)
  let _ =
    client.stream_with_tools(
      fake_config(),
      [llm.UserMessage("q1")],
      [],
      callback,
    )
  let _ =
    client.stream_with_tools(
      fake_config(),
      [llm.UserMessage("q2")],
      [],
      callback,
    )

  let calls = fake_llm.calls(fake)
  list.length(calls) |> should.equal(2)
}

pub fn fake_llm_chat_text_returns_scripted_response_test() {
  let #(fake, client) = fake_llm.new()
  fake_llm.script_chat_text_response(fake, "a blue sky")

  client.chat_text(fake_config(), [llm.UserMessage("describe")], None)
  |> should.equal(Ok("a blue sky"))
}

pub fn fake_llm_chat_text_errors_when_no_script_test() {
  let #(_fake, client) = fake_llm.new()

  case client.chat_text(fake_config(), [], None) {
    Error(_) -> Nil
    Ok(_) -> should.fail()
  }
}

pub fn fake_llm_chat_text_scripts_are_fifo_test() {
  let #(fake, client) = fake_llm.new()
  fake_llm.script_chat_text_response(fake, "first")
  fake_llm.script_chat_text_response(fake, "second")

  client.chat_text(fake_config(), [], None) |> should.equal(Ok("first"))
  client.chat_text(fake_config(), [], None) |> should.equal(Ok("second"))
}
