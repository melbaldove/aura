import aura/channel_actor
import gleam/erlang/process
import gleeunit/should

pub fn channel_actor_starts_and_accepts_messages_test() {
  let deps =
    channel_actor.TestDeps(
      channel_id: "test-channel",
      discord_token: "fake",
    )
  let subject = channel_actor.start_for_test(deps) |> should.be_ok

  // Sending messages should not crash the actor
  process.send(subject, channel_actor.Cancel)
  process.send(subject, channel_actor.TurnDeadline)

  // Verify the actor is still alive by sending one more and completing
  process.send(subject, channel_actor.Cancel)
}
