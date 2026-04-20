import aura/discord/types
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn embed_to_json_test() {
  let embed =
    types.Embed(
      title: Some("ACP Started"),
      description: Some("TASK-456: Fix ACK receipt format"),
      color: Some(0x00FF00),
      fields: [],
      footer: None,
    )
  let json_str = embed |> types.embed_to_json |> json.to_string
  json_str |> string.contains("ACP Started") |> should.be_true
  json_str |> string.contains("TASK-456") |> should.be_true
}

pub fn embed_field_to_json_test() {
  let field = types.EmbedField(name: "Status", value: "Running", inline: True)
  let json_str = field |> types.embed_field_to_json |> json.to_string
  json_str |> string.contains("Status") |> should.be_true
}

pub fn create_message_payload_test() {
  let payload = types.create_message_payload("Hello world", [])
  let json_str = payload |> json.to_string
  json_str |> string.contains("Hello world") |> should.be_true
}

pub fn create_message_with_embed_test() {
  let embed =
    types.Embed(
      title: Some("Test"),
      description: Some("Desc"),
      color: None,
      fields: [],
      footer: None,
    )
  let payload = types.create_message_payload("", [embed])
  let json_str = payload |> json.to_string
  json_str |> string.contains("embeds") |> should.be_true
  json_str |> string.contains("Test") |> should.be_true
}

pub fn identify_payload_test() {
  let payload = types.identify_payload("my-token", 37_376)
  let json_str = payload |> json.to_string
  json_str |> string.contains("my-token") |> should.be_true
  json_str |> string.contains("aura") |> should.be_true
  json_str |> string.contains("37376") |> should.be_true
}

pub fn heartbeat_payload_with_seq_test() {
  let payload = types.heartbeat_payload(Some(42))
  let json_str = payload |> json.to_string
  json_str |> string.contains("42") |> should.be_true
}

pub fn heartbeat_payload_null_test() {
  let payload = types.heartbeat_payload(None)
  let json_str = payload |> json.to_string
  json_str |> string.contains("null") |> should.be_true
}

pub fn attachment_type_test() {
  let att =
    types.Attachment(
      url: "https://cdn.discordapp.com/attachments/123/456/image.png",
      content_type: "image/png",
      filename: "image.png",
    )
  att.url
  |> should.equal("https://cdn.discordapp.com/attachments/123/456/image.png")
  att.content_type |> should.equal("image/png")
}

pub fn received_message_with_attachments_test() {
  let msg =
    types.ReceivedMessage(
      id: "msg1",
      channel_id: "ch1",
      guild_id: Some("guild1"),
      author: types.User(id: "u1", username: "test", bot: False),
      content: "check this out",
      attachments: [
        types.Attachment(
          url: "https://cdn.discordapp.com/image.png",
          content_type: "image/png",
          filename: "image.png",
        ),
      ],
    )
  msg.content |> should.equal("check this out")
  msg.attachments |> should.not_equal([])
}
