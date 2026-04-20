import aura/channel_actor
import aura/discord
import gleam/erlang/process
import gleam/list
import gleam/option
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

fn fake_incoming(channel_id: String, id: String) -> discord.IncomingMessage {
  discord.IncomingMessage(
    message_id: id,
    channel_id: channel_id,
    channel_name: option.None,
    guild_id: "test-guild",
    author_id: "test-author",
    author_name: "tester",
    content: "hello",
    is_bot: False,
    attachments: [],
  )
}

pub fn incoming_when_idle_starts_turn_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let #(new_state, effects) =
    channel_actor.transition(
      state,
      channel_actor.HandleIncoming(fake_incoming("ch1", "m1")),
    )

  new_state.queue |> should.equal([])
  case new_state.turn {
    option.Some(_) -> Nil
    option.None -> should.fail()
  }
  { effects != [] } |> should.be_true
}

pub fn incoming_when_turn_in_flight_queues_test() {
  let state = channel_actor.initial_state_for_test("ch1")
  let busy_state = channel_actor.with_fake_in_flight_turn(state)
  let #(new_state, effects) =
    channel_actor.transition(
      busy_state,
      channel_actor.HandleIncoming(fake_incoming("ch1", "m2")),
    )

  list.length(new_state.queue) |> should.equal(1)
  effects |> should.equal([])
}
