import fakes/fake_discord
import gleam/list
import gleeunit/should

pub fn fake_discord_records_sent_messages_test() {
  let #(fake, client) = fake_discord.new()
  let _ = client.send_message("channel-a", "hello")
  let _ = client.send_message("channel-a", "world")

  let sent = fake_discord.all_sent_to(fake, "channel-a")
  list.length(sent) |> should.equal(2)
  list.contains(sent, "hello") |> should.be_true
  list.contains(sent, "world") |> should.be_true
}

pub fn fake_discord_generates_unique_message_ids_test() {
  let #(_fake, client) = fake_discord.new()
  let first = client.send_message("ch", "a") |> should.be_ok
  let second = client.send_message("ch", "b") |> should.be_ok
  first |> should.not_equal(second)
}

pub fn fake_discord_seed_and_lookup_parent_test() {
  let #(fake, client) = fake_discord.new()
  fake_discord.seed_channel_parent(fake, "thread-1", "parent-1")
  client.get_channel_parent("thread-1") |> should.equal(Ok("parent-1"))
}

pub fn fake_discord_unseeded_parent_returns_empty_test() {
  let #(_fake, client) = fake_discord.new()
  client.get_channel_parent("unknown") |> should.equal(Ok(""))
}

pub fn fake_discord_records_other_event_types_test() {
  let #(fake, client) = fake_discord.new()
  let _ = client.edit_message("ch", "msg-1", "edited")
  let _ = client.trigger_typing("ch")
  let _ =
    client.send_message_with_attachment("ch", "see attached", "/tmp/x.jpg")
  let _ = client.create_thread_from_message("ch", "msg-1", "new-thread")

  let events = fake_discord.all_events(fake)
  list.length(events) |> should.equal(4)
}
