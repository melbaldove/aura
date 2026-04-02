import aura/discord/gateway
import aura/discord/types
import gleam/option.{None}
import gleeunit/should

pub fn parse_message_create_with_attachments_test() {
  let json = "{
    \"op\": 0,
    \"t\": \"MESSAGE_CREATE\",
    \"d\": {
      \"id\": \"msg123\",
      \"channel_id\": \"ch456\",
      \"guild_id\": \"guild789\",
      \"author\": {\"id\": \"u1\", \"username\": \"testuser\", \"bot\": false},
      \"content\": \"check this image\",
      \"attachments\": [
        {\"url\": \"https://cdn.discordapp.com/attachments/1/2/photo.png\", \"content_type\": \"image/png\", \"filename\": \"photo.png\"}
      ]
    }
  }"
  let result = gateway.parse_message_create_public(json)
  let assert Ok(msg) = result
  msg.id |> should.equal("msg123")
  msg.content |> should.equal("check this image")
  msg.attachments |> should.equal([
    types.Attachment(
      url: "https://cdn.discordapp.com/attachments/1/2/photo.png",
      content_type: "image/png",
      filename: "photo.png",
    ),
  ])
}

pub fn parse_message_create_without_attachments_test() {
  let json = "{
    \"op\": 0,
    \"t\": \"MESSAGE_CREATE\",
    \"d\": {
      \"id\": \"msg456\",
      \"channel_id\": \"ch789\",
      \"guild_id\": \"guild000\",
      \"author\": {\"id\": \"u2\", \"username\": \"anotheruser\"},
      \"content\": \"just text\"
    }
  }"
  let result = gateway.parse_message_create_public(json)
  let assert Ok(msg) = result
  msg.id |> should.equal("msg456")
  msg.content |> should.equal("just text")
  msg.attachments |> should.equal([])
}

pub fn parse_message_create_attachment_missing_optional_fields_test() {
  let json = "{
    \"op\": 0,
    \"t\": \"MESSAGE_CREATE\",
    \"d\": {
      \"id\": \"msg789\",
      \"channel_id\": \"ch111\",
      \"author\": {\"id\": \"u3\", \"username\": \"user3\"},
      \"content\": \"file here\",
      \"attachments\": [
        {\"url\": \"https://cdn.discordapp.com/attachments/1/2/file.dat\"}
      ]
    }
  }"
  let result = gateway.parse_message_create_public(json)
  let assert Ok(msg) = result
  msg.guild_id |> should.equal(None)
  msg.attachments |> should.equal([
    types.Attachment(
      url: "https://cdn.discordapp.com/attachments/1/2/file.dat",
      content_type: "",
      filename: "",
    ),
  ])
}
