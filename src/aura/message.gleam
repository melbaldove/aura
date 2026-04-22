//// Platform-neutral message types. Any transport (Discord, Blather,
//// Telegram, …) converts its wire format into these before handing off
//// to the brain. The `platform` field is the only way downstream code
//// distinguishes sources — everything else is the same shape.

import gleam/option.{type Option}

/// An attachment on an incoming message. Shape matches Discord's today
/// because that's the only producer; platforms without a MIME type pass
/// empty string for `content_type`.
pub type Attachment {
  Attachment(url: String, content_type: String, filename: String)
}

/// A message received from some platform, normalized for internal use.
///
/// `platform` identifies the source ("discord", "blather", …) and is
/// used as the first half of the conversation DB key. `channel_id` is
/// the platform's native channel identifier; combined with `platform`
/// it uniquely names the conversation. `guild_id` is only meaningful on
/// platforms that have guilds/workspaces; platforms without one pass
/// the empty string.
pub type IncomingMessage {
  IncomingMessage(
    platform: String,
    message_id: String,
    channel_id: String,
    channel_name: Option(String),
    guild_id: String,
    author_id: String,
    author_name: String,
    content: String,
    is_bot: Bool,
    attachments: List(Attachment),
  )
}
