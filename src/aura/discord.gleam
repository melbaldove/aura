import aura/discord/rest
import aura/discord/types as discord_types
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Briefing section for morning digest
pub type BriefingSection {
  BriefingSection(workstream: String, summary: String)
}

/// Normalized incoming message for Aura's internal use
pub type IncomingMessage {
  IncomingMessage(
    message_id: String,
    channel_id: String,
    channel_name: Option(String),
    guild_id: String,
    author_id: String,
    author_name: String,
    content: String,
    is_bot: Bool,
  )
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

/// Convert a received Discord message to internal type
pub fn from_received(
  msg: discord_types.ReceivedMessage,
  channel_name: Option(String),
) -> IncomingMessage {
  IncomingMessage(
    message_id: msg.id,
    channel_id: msg.channel_id,
    channel_name: channel_name,
    guild_id: option.unwrap(msg.guild_id, ""),
    author_id: msg.author.id,
    author_name: msg.author.username,
    content: msg.content,
    is_bot: msg.author.bot,
  )
}

/// Format a morning briefing as a Discord message string
pub fn format_briefing(title: String, sections: List(BriefingSection)) -> String {
  let section_lines =
    list.map(sections, fn(s) { "**" <> s.workstream <> "** -- " <> s.summary })
  string.join(["**" <> title <> "**", "", ..section_lines], "\n")
}

/// Send a text message (delegates to rest)
pub fn send_text(
  token: String,
  channel_id: String,
  content: String,
) -> Result(String, String) {
  rest.send_message(token, channel_id, content, [])
}

/// Send an embed (delegates to rest)
pub fn send_embed(
  token: String,
  channel_id: String,
  title: String,
  description: String,
  color: Option(Int),
) -> Result(String, String) {
  let embed =
    discord_types.Embed(
      title: Some(title),
      description: Some(description),
      color: color,
      fields: [],
      footer: None,
    )
  rest.send_message(token, channel_id, "", [embed])
}

