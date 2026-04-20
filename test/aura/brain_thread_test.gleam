import aura/brain
import fakes/fake_discord
import fakes/fake_llm
import gleam/erlang/process
import gleam/string
import gleeunit/should
import test_harness

pub fn top_level_domain_message_creates_thread_test() {
  // Fresh system with a cm2 domain whose channel_id is "cm2-channel".
  // Also allowlist "cm2-channel" so brain routes it through the channel_actor
  // path, where the thread-creation logic lives.
  let #(sys, _) =
    test_harness.fresh_system_with_domain_and_allowlist(
      "cm2",
      "# CM2",
      "cm2-channel",
      ["cm2-channel"],
    )

  // Script the fake Discord client to return a known thread_id.
  fake_discord.script_create_thread(sys.fake_discord, "cm2-thread-123")

  // Script the LLM with a reply that will land in the thread.
  fake_llm.script_text_response(sys.fake_llm, "reply-in-thread")

  // Send a message to the top-level domain channel.
  let msg = test_harness.incoming("cm2-channel", "hi from the top channel")
  process.send(sys.brain_subject, brain.HandleMessage(msg))

  // Assert: reply lands in cm2-thread-123, NOT cm2-channel.
  // assert_latest_contains polls for up to 3000ms.
  let content =
    fake_discord.assert_latest_contains(
      sys.fake_discord,
      "cm2-thread-123",
      "reply-in-thread",
      3000,
    )
  // The channel_actor may include typing indicators in its progressive
  // edits; assert the content *contains* the expected text.
  string.contains(content, "reply-in-thread") |> should.be_true

  // Assert: nothing was sent to the original top-level channel.
  let sent_to_original =
    fake_discord.all_sent_to(sys.fake_discord, "cm2-channel")
  sent_to_original |> should.equal([])

  test_harness.teardown(sys)
}
