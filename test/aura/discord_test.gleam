import aura/discord
import aura/discord/message as discord_message
import aura/discord/types as discord_types
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should

pub fn format_briefing_test() {
  let sections = [
    discord.BriefingSection(domain: "cm2", summary: "2 tickets in sprint"),
    discord.BriefingSection(domain: "hy", summary: "1 new ticket assigned"),
  ]
  let text = discord.format_briefing("Morning Briefing", sections)
  text |> string.contains("**cm2**") |> should.be_true
  text |> string.contains("**hy**") |> should.be_true
  text |> string.contains("Morning Briefing") |> should.be_true
}

pub fn incoming_from_received_test() {
  let received =
    discord_types.ReceivedMessage(
      id: "123",
      channel_id: "456",
      guild_id: option.Some("789"),
      author: discord_types.User(id: "111", username: "testuser", bot: False),
      content: "hello aura",
      attachments: [],
    )
  let incoming = discord.from_received(received, option.Some("cm2"))
  incoming.channel_name |> should.equal(option.Some("cm2"))
  incoming.author_name |> should.equal("testuser")
  incoming.content |> should.equal("hello aura")
  incoming.is_bot |> should.equal(False)
}

pub fn split_to_discord_messages_preserves_long_content_test() {
  let content = string.repeat("x", 4500)
  let chunks = discord_message.split_to_discord_messages(content)

  list.length(chunks) |> should.equal(3)
  string.concat(chunks) |> should.equal(content)
  list.all(chunks, fn(chunk) {
    string.length(chunk) <= discord_message.discord_max_chars
  })
  |> should.be_true
}
