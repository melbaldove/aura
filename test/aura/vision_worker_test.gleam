import aura/channel_actor
import aura/llm
import aura/vision_worker
import fakes/fake_llm
import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should

fn fake_config() -> llm.LlmConfig {
  llm.LlmConfig(
    model: "fake-vision",
    api_key: "fake",
    base_url: "http://127.0.0.1:1",
  )
}

pub fn vision_worker_forwards_complete_on_success_test() {
  let #(fake, client) = fake_llm.new()
  fake_llm.script_chat_text_response(fake, "a cat on a mat")

  let parent: process.Subject(channel_actor.ChannelMessage) =
    process.new_subject()
  let _ = vision_worker.spawn(client.chat_text, fake_config(), [], None, parent)

  case process.receive(parent, 2000) {
    Ok(channel_actor.VisionComplete(description)) ->
      description |> should.equal("a cat on a mat")
    _ -> should.fail()
  }
}

pub fn vision_worker_forwards_error_on_failure_test() {
  let #(_fake, client) = fake_llm.new()
  // No script — chat_text will return Error("fake_llm: no chat_text script")

  let parent: process.Subject(channel_actor.ChannelMessage) =
    process.new_subject()
  let _ = vision_worker.spawn(client.chat_text, fake_config(), [], None, parent)

  case process.receive(parent, 2000) {
    Ok(channel_actor.VisionError(_)) -> Nil
    _ -> should.fail()
  }
}
