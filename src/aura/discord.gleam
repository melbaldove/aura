import aura/discord/rest
import aura/discord/types as discord_types
import aura/message
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Canonical platform name for Discord-sourced messages. Use this in
/// place of the string literal when threading platform through the
/// system (conversation keys, channel actor deps, etc.).
pub const platform_name: String = "discord"

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Briefing section for morning digest
pub type BriefingSection {
  BriefingSection(domain: String, summary: String)
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

/// Convert a received Discord message to the platform-neutral
/// `message.IncomingMessage` that the brain processes.
pub fn from_received(
  msg: discord_types.ReceivedMessage,
  channel_name: Option(String),
) -> message.IncomingMessage {
  message.IncomingMessage(
    platform: platform_name,
    message_id: msg.id,
    channel_id: msg.channel_id,
    channel_name: channel_name,
    guild_id: option.unwrap(msg.guild_id, ""),
    author_id: msg.author.id,
    author_name: msg.author.username,
    content: msg.content,
    is_bot: msg.author.bot,
    attachments: list.map(msg.attachments, attachment_from_discord),
  )
}

fn attachment_from_discord(a: discord_types.Attachment) -> message.Attachment {
  message.Attachment(
    url: a.url,
    content_type: a.content_type,
    filename: a.filename,
  )
}

/// Format a morning briefing as a Discord message string
pub fn format_briefing(title: String, sections: List(BriefingSection)) -> String {
  let section_lines =
    list.map(sections, fn(s) { "**" <> s.domain <> "** -- " <> s.summary })
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
