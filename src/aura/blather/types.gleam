//// Blather WebSocket event envelope and event-type decoders.
////
//// Every event the server pushes has the shape
////   `{id, type, channel_id, data}`
//// where `type` is a string tag like `"message.created"` and `data` is
//// a type-specific payload. The decoders here turn a raw JSON frame
//// into a typed `GatewayEvent`; the gateway actor (not yet written)
//// will dispatch on the variant.
////
//// Only `message.created` is decoded in detail — that's the event the
//// brain acts on. Presence, typing, reaction, channel lifecycle, and
//// other events are captured as `Unknown(type)` so adding handlers
//// later is non-breaking.

import aura/blather/thread_channel
import aura/message
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}

/// Canonical platform name for Blather-sourced messages. Mirrors
/// `discord.platform_name` — use this when threading platform identity
/// through the system.
pub const platform_name: String = "blather"

/// Decoded event from a Blather WS frame.
pub type GatewayEvent {
  /// Server greeted us; auth is valid.
  Connected(user_id: String)
  /// A new message was posted in a channel we can see.
  MessageCreated(msg: message.IncomingMessage)
  /// Any event type we don't specifically handle yet.
  Unknown(type_name: String)
}

/// Parse a single JSON frame from the WS connection into a typed event.
pub fn parse_event(text: String) -> Result(GatewayEvent, json.DecodeError) {
  json.parse(text, event_decoder())
}

fn event_decoder() -> decode.Decoder(GatewayEvent) {
  use type_name <- decode.field("type", decode.string)
  case type_name {
    "connected" -> {
      use user_id <- decode.field("userId", decode.string)
      decode.success(Connected(user_id:))
    }
    "message.created" -> {
      use msg <- decode.field("data", message_data_decoder())
      decode.success(MessageCreated(msg:))
    }
    other -> decode.success(Unknown(type_name: other))
  }
}

/// Decode the `data` payload of a `message.created` event into a
/// platform-neutral `IncomingMessage`. `platform` is always
/// `platform_name`; `is_bot` is wired to the server's `user.isAgent`
/// flag so the brain can skip agent echoes the same way the Discord
/// path skips bots.
fn message_data_decoder() -> decode.Decoder(message.IncomingMessage) {
  use id <- decode.field("id", decode.string)
  use channel_id <- decode.field("channelId", decode.string)
  use thread_id <- decode.optional_field(
    "threadId",
    None,
    decode.optional(decode.string),
  )
  use user_id <- decode.field("userId", decode.string)
  use content <- decode.optional_field("content", "", decode.string)
  use user <- decode.optional_field(
    "user",
    None,
    decode.optional(user_decoder()),
  )
  use attachments <- decode.optional_field(
    "attachments",
    [],
    decode.list(attachment_decoder()),
  )
  let #(author_name, is_bot) = case user {
    Some(UserShape(display_name:, is_agent:)) ->
      case display_name {
        "" -> #(user_id, is_agent)
        name -> #(name, is_agent)
      }
    None -> #(user_id, False)
  }
  let routed_channel_id = case thread_id {
    Some(id) -> thread_channel.make(channel_id, id)
    None -> channel_id
  }
  decode.success(message.IncomingMessage(
    platform: platform_name,
    message_id: id,
    channel_id: routed_channel_id,
    channel_name: None,
    guild_id: "",
    author_id: user_id,
    author_name: author_name,
    content: content,
    is_bot: is_bot,
    attachments: attachments,
  ))
}

type UserShape {
  UserShape(display_name: String, is_agent: Bool)
}

fn user_decoder() -> decode.Decoder(UserShape) {
  use display_name <- decode.optional_field("displayName", "", decode.string)
  use is_agent <- decode.optional_field("isAgent", False, decode.bool)
  decode.success(UserShape(display_name:, is_agent:))
}

fn attachment_decoder() -> decode.Decoder(message.Attachment) {
  use url <- decode.field("url", decode.string)
  use content_type <- decode.optional_field("contentType", "", decode.string)
  use filename <- decode.optional_field("filename", "", decode.string)
  decode.success(message.Attachment(
    url: url,
    content_type: content_type,
    filename: filename,
  ))
}
