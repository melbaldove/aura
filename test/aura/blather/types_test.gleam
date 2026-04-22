import aura/blather/types
import gleam/list
import gleam/option
import gleeunit/should

pub fn parse_connected_event_test() {
  let frame = "{\"type\":\"connected\",\"userId\":\"u-1\"}"
  let event = types.parse_event(frame) |> should.be_ok
  case event {
    types.Connected(user_id) -> user_id |> should.equal("u-1")
    _ -> should.fail()
  }
}

pub fn parse_message_created_event_test() {
  let frame =
    "{\"id\":\"evt-1\",\"type\":\"message.created\",\"channel_id\":\"ch-1\","
    <> "\"data\":{\"id\":\"msg-9\",\"channelId\":\"ch-1\",\"userId\":\"u-7\","
    <> "\"content\":\"hello aura\",\"user\":{\"displayName\":\"Alice\","
    <> "\"isAgent\":false}}}"
  let event = types.parse_event(frame) |> should.be_ok
  case event {
    types.MessageCreated(msg) -> {
      msg.platform |> should.equal("blather")
      msg.message_id |> should.equal("msg-9")
      msg.channel_id |> should.equal("ch-1")
      msg.author_id |> should.equal("u-7")
      msg.author_name |> should.equal("Alice")
      msg.content |> should.equal("hello aura")
      msg.is_bot |> should.equal(False)
      msg.channel_name |> should.equal(option.None)
      msg.attachments |> should.equal([])
    }
    _ -> should.fail()
  }
}

/// Agent-authored messages (`isAgent: true`) must deserialize with
/// `is_bot = true` so the brain skips them the same way it skips
/// Discord bot messages, avoiding echo loops.
pub fn parse_message_created_from_agent_marks_is_bot_test() {
  let frame =
    "{\"id\":\"evt-2\",\"type\":\"message.created\",\"channel_id\":\"ch-1\","
    <> "\"data\":{\"id\":\"msg-1\",\"channelId\":\"ch-1\",\"userId\":\"aura\","
    <> "\"content\":\"hi\",\"user\":{\"displayName\":\"Aura\",\"isAgent\":true}}}"
  let event = types.parse_event(frame) |> should.be_ok
  case event {
    types.MessageCreated(msg) -> msg.is_bot |> should.equal(True)
    _ -> should.fail()
  }
}

/// When the `user` subfield is absent (which shouldn't happen on real
/// frames but should degrade gracefully), `author_name` falls back to
/// `userId` rather than empty-string.
pub fn parse_message_created_without_user_falls_back_to_user_id_test() {
  let frame =
    "{\"id\":\"evt-3\",\"type\":\"message.created\",\"channel_id\":\"ch-1\","
    <> "\"data\":{\"id\":\"msg-2\",\"channelId\":\"ch-1\","
    <> "\"userId\":\"u-raw\",\"content\":\"hi\"}}"
  let event = types.parse_event(frame) |> should.be_ok
  case event {
    types.MessageCreated(msg) -> msg.author_name |> should.equal("u-raw")
    _ -> should.fail()
  }
}

pub fn parse_unknown_event_captures_type_test() {
  let frame = "{\"type\":\"typing.started\",\"data\":{}}"
  let event = types.parse_event(frame) |> should.be_ok
  case event {
    types.Unknown(type_name) -> type_name |> should.equal("typing.started")
    _ -> should.fail()
  }
}

pub fn parse_malformed_json_returns_error_test() {
  types.parse_event("not json")
  |> should.be_error
}

/// A JSON frame that parses but lacks a `type` field is malformed per
/// the Blather protocol. Treat as decode error so the caller can log
/// and disconnect rather than silently drop frames.
pub fn parse_event_without_type_field_returns_error_test() {
  types.parse_event("{\"data\":{}}")
  |> should.be_error
}

/// `content` is optional in the protocol (canvas-only messages omit it);
/// the decoder must default to empty string rather than fail the frame.
pub fn parse_message_created_without_content_defaults_to_empty_test() {
  let frame =
    "{\"type\":\"message.created\","
    <> "\"data\":{\"id\":\"m1\",\"channelId\":\"c1\",\"userId\":\"u1\","
    <> "\"user\":{\"displayName\":\"A\",\"isAgent\":false}}}"
  let event = types.parse_event(frame) |> should.be_ok
  case event {
    types.MessageCreated(msg) -> msg.content |> should.equal("")
    _ -> should.fail()
  }
}

/// `isAgent` is optional per the user subfield shape; missing means false.
/// Verifies the `decode.optional_field(..., False, ...)` default path.
pub fn parse_message_created_user_without_is_agent_defaults_false_test() {
  let frame =
    "{\"type\":\"message.created\","
    <> "\"data\":{\"id\":\"m1\",\"channelId\":\"c1\",\"userId\":\"u1\","
    <> "\"content\":\"hi\",\"user\":{\"displayName\":\"A\"}}}"
  let event = types.parse_event(frame) |> should.be_ok
  case event {
    types.MessageCreated(msg) -> msg.is_bot |> should.equal(False)
    _ -> should.fail()
  }
}

/// User present but `displayName` is the empty string — distinct from
/// user absent. Falls back to userId in the same way.
pub fn parse_message_created_empty_display_name_falls_back_to_user_id_test() {
  let frame =
    "{\"type\":\"message.created\","
    <> "\"data\":{\"id\":\"m1\",\"channelId\":\"c1\",\"userId\":\"u-raw\","
    <> "\"content\":\"hi\",\"user\":{\"displayName\":\"\",\"isAgent\":false}}}"
  let event = types.parse_event(frame) |> should.be_ok
  case event {
    types.MessageCreated(msg) -> msg.author_name |> should.equal("u-raw")
    _ -> should.fail()
  }
}

/// Blather messages can carry attachments. The decoder must surface
/// them so vision / inline-file logic still works on Blather.
pub fn parse_message_created_with_attachments_test() {
  let frame =
    "{\"type\":\"message.created\","
    <> "\"data\":{\"id\":\"m1\",\"channelId\":\"c1\",\"userId\":\"u1\","
    <> "\"content\":\"see pic\","
    <> "\"attachments\":[{\"url\":\"https://blather/cdn/a.png\","
    <> "\"contentType\":\"image/png\",\"filename\":\"a.png\"}]}}"
  let event = types.parse_event(frame) |> should.be_ok
  case event {
    types.MessageCreated(msg) -> {
      list.length(msg.attachments) |> should.equal(1)
      let assert [att] = msg.attachments
      att.url |> should.equal("https://blather/cdn/a.png")
      att.content_type |> should.equal("image/png")
      att.filename |> should.equal("a.png")
    }
    _ -> should.fail()
  }
}

pub fn platform_name_is_blather_test() {
  types.platform_name |> should.equal("blather")
}


