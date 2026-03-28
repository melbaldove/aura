import aura/discord
import aura/discord/types as discord_types
import gleam/option
import gleam/string
import gleeunit/should

pub fn format_briefing_test() {
  let sections = [
    discord.BriefingSection(workstream: "cm2", summary: "2 tickets in sprint"),
    discord.BriefingSection(workstream: "hy", summary: "1 new ticket assigned"),
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
      author: discord_types.User(id: "111", username: "melbs", bot: False),
      content: "hello aura",
    )
  let incoming = discord.from_received(received, "cm2")
  incoming.channel_name |> should.equal("cm2")
  incoming.author_name |> should.equal("melbs")
  incoming.content |> should.equal("hello aura")
  incoming.is_bot |> should.equal(False)
}
