import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Partial Discord User object
pub type User {
  User(id: String, username: String, bot: Bool)
}

/// A single embed field
pub type EmbedField {
  EmbedField(name: String, value: String, inline: Bool)
}

/// Embed footer
pub type EmbedFooter {
  EmbedFooter(text: String)
}

/// Discord message embed (all fields optional except fields list)
pub type Embed {
  Embed(
    title: Option(String),
    description: Option(String),
    color: Option(Int),
    fields: List(EmbedField),
    footer: Option(EmbedFooter),
  )
}

/// A file attached to a Discord message
pub type Attachment {
  Attachment(url: String, content_type: String, filename: String)
}

/// A message received from MESSAGE_CREATE
pub type ReceivedMessage {
  ReceivedMessage(
    id: String,
    channel_id: String,
    guild_id: Option(String),
    author: User,
    content: String,
    attachments: List(Attachment),
  )
}

// ---------------------------------------------------------------------------
// Gateway payload types
// ---------------------------------------------------------------------------

pub type HelloPayload {
  HelloPayload(heartbeat_interval: Int)
}

pub type ReadyPayload {
  ReadyPayload(session_id: String, resume_gateway_url: String)
}

pub type GatewayEvent {
  Hello(HelloPayload)
  Ready(ReadyPayload)
  MessageCreate(ReceivedMessage)
  InteractionCreate(
    interaction_id: String,
    interaction_token: String,
    custom_id: String,
    channel_id: String,
    user_id: String,
    message_id: String,
  )
  HeartbeatAck
  Reconnect
  InvalidSession(resumable: Bool)
  UnknownEvent(name: String)
}

// ---------------------------------------------------------------------------
// JSON encoding helpers
// ---------------------------------------------------------------------------

fn optional_field(
  key: String,
  value: Option(a),
  encoder: fn(a) -> json.Json,
) -> Result(#(String, json.Json), Nil) {
  case value {
    Some(v) -> Ok(#(key, encoder(v)))
    None -> Error(Nil)
  }
}

/// Encode an EmbedField to JSON
pub fn embed_field_to_json(field: EmbedField) -> json.Json {
  json.object([
    #("name", json.string(field.name)),
    #("value", json.string(field.value)),
    #("inline", json.bool(field.inline)),
  ])
}

/// Encode an EmbedFooter to JSON
pub fn embed_footer_to_json(footer: EmbedFooter) -> json.Json {
  json.object([#("text", json.string(footer.text))])
}

/// Encode an Embed to JSON, skipping None optional fields
pub fn embed_to_json(embed: Embed) -> json.Json {
  let optional_fields =
    [
      optional_field("title", embed.title, json.string),
      optional_field("description", embed.description, json.string),
      optional_field("color", embed.color, json.int),
      optional_field("footer", embed.footer, embed_footer_to_json),
    ]
    |> list.filter_map(fn(x) { x })

  let fields_entry = #(
    "fields",
    json.array(embed.fields, embed_field_to_json),
  )

  json.object([fields_entry, ..optional_fields])
}

/// Encode a message creation payload (POST /channels/{id}/messages)
pub fn create_message_payload(
  content: String,
  embeds: List(Embed),
) -> json.Json {
  json.object([
    #("content", json.string(content)),
    #("embeds", json.array(embeds, embed_to_json)),
  ])
}

/// Encode a Discord gateway Identify payload (op: 2)
pub fn identify_payload(token: String, intents: Int) -> json.Json {
  json.object([
    #("op", json.int(2)),
    #(
      "d",
      json.object([
        #("token", json.string(token)),
        #("intents", json.int(intents)),
        #(
          "properties",
          json.object([
            #("os", json.string("beam")),
            #("browser", json.string("aura")),
            #("device", json.string("aura")),
          ]),
        ),
      ]),
    ),
  ])
}

/// Encode a Discord gateway Heartbeat payload (op: 1)
pub fn heartbeat_payload(sequence: Option(Int)) -> json.Json {
  let d = case sequence {
    Some(seq) -> json.int(seq)
    None -> json.null()
  }
  json.object([#("op", json.int(1)), #("d", d)])
}

/// Encode a Discord gateway Resume payload (op: 6)
pub fn resume_payload(
  token: String,
  session_id: String,
  sequence: Int,
) -> json.Json {
  json.object([
    #("op", json.int(6)),
    #(
      "d",
      json.object([
        #("token", json.string(token)),
        #("session_id", json.string(session_id)),
        #("seq", json.int(sequence)),
      ]),
    ),
  ])
}

/// Build an action row with Approve and Reject buttons for a proposal.
pub fn approve_reject_buttons(proposal_id: String) -> json.Json {
  json.array(
    [
      json.object([
        #("type", json.int(1)),
        #(
          "components",
          json.array(
            [
              json.object([
                #("type", json.int(2)),
                #("style", json.int(3)),
                #("label", json.string("Approve")),
                #("custom_id", json.string("approve:" <> proposal_id)),
              ]),
              json.object([
                #("type", json.int(2)),
                #("style", json.int(4)),
                #("label", json.string("Reject")),
                #("custom_id", json.string("reject:" <> proposal_id)),
              ]),
            ],
            fn(x) { x },
          ),
        ),
      ]),
    ],
    fn(x) { x },
  )
}
