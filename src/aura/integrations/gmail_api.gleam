//// Pure Gmail REST metadata normalization.
////
//// The production runtime supplies only selected Gmail metadata after the
//// GET-only boundary accepts its request. This module does not own a token or
//// an HTTP client.

import aura/connector_adapter
import aura/connector_registry
import aura/db
import aura/event_ingest
import aura/google_readonly_http
import aura/oauth
import aura/operating_contracts
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

const readonly_scope = "https://www.googleapis.com/auth/gmail.readonly"

/// Selected profile fields used to seed a checkpoint. The address is not
/// retained after the caller derives the opaque seed.
pub type Profile {
  Profile(email_address: String, history_id: String)
}

/// Opaque profile proof and initial history checkpoint.
pub type ProfileSeed {
  ProfileSeed(
    account_fingerprint: String,
    history_id: String,
    proof_hash: String,
  )
}

/// One selected Gmail history page. It contains message identifiers only.
pub type HistoryPage {
  HistoryPage(
    message_added_ids: List(String),
    history_id: String,
    next_page_token: String,
  )
}

type GmailHeader {
  GmailHeader(name: String, value: String)
}

type RawMetadataMessage {
  RawMetadataMessage(
    message_id: String,
    thread_id: String,
    history_id: String,
    internal_date: String,
    label_ids: List(String),
    size_estimate: Int,
    headers: List(GmailHeader),
  )
}

type RawHistoryMessage {
  RawHistoryMessage(message_id: String)
}

type RawHistoryAdded {
  RawHistoryAdded(message: RawHistoryMessage)
}

type RawHistoryRecord {
  RawHistoryRecord(messages_added: List(RawHistoryAdded))
}

type RawHistoryPage {
  RawHistoryPage(
    history: List(RawHistoryRecord),
    history_id: String,
    next_page_token: String,
  )
}

/// A history checkpoint gap. The caller must audit and require new authority.
pub type CaptureGap {
  CaptureGap(reason_code: String, reauthorization_required: Bool)
}

/// Selected history result from an injected read-only transport.
pub type HistoryRead {
  HistoryPages(List(HistoryPage))
  HistoryCheckpointUnavailable(reason_code: String)
}

/// Local executor outcome for one bounded Gmail history request.
pub type HistoryOutcome {
  SelectedMessageIds(List(String))
  CheckpointGap(CaptureGap)
}

/// The complete metadata set that the Gmail REST path may normalize.
pub type MetadataMessage {
  MetadataMessage(
    message_id: String,
    thread_id: String,
    history_id: String,
    internal_date_ms: Int,
    label_ids: List(String),
    size_estimate: Int,
    subject: String,
    from: String,
  )
}

/// Derive an opaque account proof and history checkpoint from a profile.
pub fn profile_seed(
  profile: Profile,
  identity_key: String,
) -> Result(ProfileSeed, String) {
  case
    profile.email_address != ""
    && valid_history_id(profile.history_id)
    && string.length(identity_key) >= 32
    && string.length(identity_key) <= 256
  {
    False -> Error("gmail_profile_invalid")
    True -> {
      let fingerprint =
        oauth.account_fingerprint(identity_key, profile.email_address)
      let canonical =
        "aura.gmail.profile.v1\u{0}"
        <> fingerprint
        <> "\u{0}"
        <> profile.history_id
      let proof_hash =
        crypto.hash(crypto.Sha256, <<canonical:utf8>>)
        |> bit_array.base16_encode
      Ok(ProfileSeed(fingerprint, profile.history_id, proof_hash))
    }
  }
}

/// Select unique message identifiers from one bounded history read attempt.
pub fn collect_history(
  pages: List(HistoryPage),
  max_pages: Int,
  max_items: Int,
) -> Result(List(String), String) {
  case max_pages > 0 && max_items > 0 && list.length(pages) <= max_pages {
    False -> Error("gmail_history_page_limit_exceeded")
    True -> {
      use _ <- result.try(
        list.try_each(pages, fn(page) {
          case
            valid_page_token(page.next_page_token)
            && valid_history_id(page.history_id)
          {
            True -> Ok(Nil)
            False -> Error("gmail_history_page_token_invalid")
          }
        }),
      )
      use identifiers <- result.try(
        pages
        |> list.flat_map(fn(page) { page.message_added_ids })
        |> unique_identifiers([], max_items),
      )
      Ok(list.reverse(identifiers))
    }
  }
}

/// Decode the exact Gmail profile projection.
pub fn decode_profile_response(raw: String) -> Result(Profile, String) {
  use _ <- result.try(validate_json_shape(
    raw,
    ["emailAddress", "historyId"],
    "gmail_profile_response_fields_invalid",
  ))
  use profile <- result.try(
    json.parse(raw, {
      use email_address <- decode.field("emailAddress", decode.string)
      use history_id <- decode.field("historyId", decode.string)
      decode.success(Profile(email_address:, history_id:))
    })
    |> result.map_error(fn(_) { "gmail_profile_response_invalid" }),
  )
  case profile.email_address != "" && valid_history_id(profile.history_id) {
    True -> Ok(profile)
    False -> Error("gmail_profile_response_invalid")
  }
}

/// Decode one exact Gmail history projection.
pub fn decode_history_page_response(raw: String) -> Result(HistoryPage, String) {
  use top <- result.try(validate_json_shape(
    raw,
    ["history", "nextPageToken", "historyId"],
    "gmail_history_response_fields_invalid",
  ))
  use _ <- result.try(validate_history_shape(top))
  use page <- result.try(
    json.parse(raw, raw_history_page_decoder())
    |> result.map_error(fn(_) { "gmail_history_response_invalid" }),
  )
  let identifiers =
    page.history
    |> list.flat_map(fn(record) { record.messages_added })
    |> list.map(fn(added) { added.message.message_id })
  use unique <- result.try(unique_identifiers(identifiers, [], 100))
  case
    valid_history_id(page.history_id) && valid_page_token(page.next_page_token)
  {
    True ->
      Ok(HistoryPage(
        list.reverse(unique),
        page.history_id,
        page.next_page_token,
      ))
    False -> Error("gmail_history_response_invalid")
  }
}

/// Decode one exact Gmail metadata projection and reject all other fields.
pub fn decode_metadata_response(raw: String) -> Result(MetadataMessage, String) {
  use top <- result.try(validate_json_shape(
    raw,
    [
      "id",
      "threadId",
      "labelIds",
      "historyId",
      "internalDate",
      "sizeEstimate",
      "payload",
    ],
    "gmail_metadata_response_fields_invalid",
  ))
  use _ <- result.try(validate_metadata_shape(top))
  use selected <- result.try(
    json.parse(raw, raw_metadata_decoder())
    |> result.map_error(fn(_) { "gmail_metadata_response_invalid" }),
  )
  use _ <- result.try(case valid_decimal(selected.internal_date, 20) {
    True -> Ok(Nil)
    False -> Error("gmail_metadata_response_invalid")
  })
  use internal_date_ms <- result.try(
    int.parse(selected.internal_date)
    |> result.map_error(fn(_) { "gmail_metadata_response_invalid" }),
  )
  use _ <- result.try(
    case
      selected.headers
      |> list.all(fn(header) {
        list.contains(["Subject", "From", "Date"], header.name)
        && string.byte_size(header.value) <= 1024
      })
    {
      True -> Ok(Nil)
      False -> Error("gmail_metadata_response_fields_invalid")
    },
  )
  let subject = header_value(selected.headers, "Subject")
  let sender = header_value(selected.headers, "From")
  let message =
    MetadataMessage(
      message_id: selected.message_id,
      thread_id: selected.thread_id,
      history_id: selected.history_id,
      internal_date_ms:,
      label_ids: selected.label_ids,
      size_estimate: selected.size_estimate,
      subject:,
      from: sender,
    )
  case valid_metadata(message) && string.byte_size(subject) <= 512 {
    True -> Ok(message)
    False -> Error("gmail_metadata_response_invalid")
  }
}

/// Build a bounded checkpoint-gap result. This function creates no evidence.
pub fn history_gap(reason_code: String) -> Result(CaptureGap, String) {
  case valid_identifier(reason_code) {
    True -> Ok(CaptureGap(reason_code:, reauthorization_required: True))
    False -> Error("gmail_history_gap_invalid")
  }
}

/// Convert selected Gmail message metadata to compact connector evidence.
pub fn metadata_to_result(
  message: MetadataMessage,
) -> Result(operating_contracts.ConnectorResult, String) {
  case
    valid_identifier(message.message_id),
    string.length(message.subject) > 512,
    valid_metadata(message)
  {
    False, _, _ -> Error("gmail_metadata_message_id_required")
    _, True, _ -> Error("gmail_metadata_subject_too_large")
    _, _, False -> Error("gmail_metadata_invalid")
    True, False, True -> {
      let base =
        operating_contracts.ConnectorResult(
          schema_version: 1,
          connector_id: "gmail",
          source_kind: "connector",
          capability: "mail.read",
          scope: readonly_scope,
          operation: "read",
          source_event_id: "message:" <> message.message_id,
          event_type: "gmail.message.metadata_observed",
          resource: dict.from_list([
            #("kind", operating_contracts.StructuredString("gmail_message")),
            #(
              "id",
              operating_contracts.StructuredString(
                "message:" <> message.message_id,
              ),
            ),
            #(
              "thread",
              operating_contracts.StructuredString(
                "thread:" <> message.thread_id,
              ),
            ),
          ]),
          observed_at: message.internal_date_ms,
          summary: message.subject,
          normalized_data: dict.from_list([
            #(
              "history_id",
              operating_contracts.StructuredString(message.history_id),
            ),
            #(
              "label_ids",
              operating_contracts.StructuredArray(
                message.label_ids
                |> list.map(operating_contracts.StructuredString),
              ),
            ),
            #(
              "size_estimate",
              operating_contracts.StructuredInt(message.size_estimate),
            ),
            #(
              "from",
              operating_contracts.StructuredString(display_sender(message.from)),
            ),
          ]),
          raw_ref: "gmail://message/" <> message.message_id,
          content_hash: "",
          provenance: dict.from_list([
            #(
              "adapter",
              operating_contracts.StructuredString("gmail_api_metadata"),
            ),
          ]),
          candidate_domain_refs: [],
          candidate_concern_refs: [],
          verification_status: "unverified",
          authority_grants: [],
        )
      Ok(
        operating_contracts.ConnectorResult(
          ..base,
          content_hash: connector_adapter.content_hash(base),
        ),
      )
    }
  }
}

fn valid_metadata(message: MetadataMessage) -> Bool {
  valid_identifier(message.thread_id)
  && valid_identifier(message.history_id)
  && message.internal_date_ms > 0
  && message.size_estimate >= 0
  && list.length(message.label_ids) <= 100
  && list.all(message.label_ids, valid_identifier)
  && string.length(message.from) <= 1024
}

/// Submit one metadata result only through the activation-aware evidence path.
///
/// This function has no provider transport. SQLite rejects a missing, stale,
/// disabled, or mismatched read-attempt context before evidence can persist.
pub fn submit_metadata(
  registry: connector_registry.Registry,
  subject: Subject(event_ingest.IngestMessage),
  context: operating_contracts.ConnectorSubmissionContext,
  message: MetadataMessage,
) -> Result(Option(db.EvidenceInsert), String) {
  use result <- result.try(metadata_to_result(message))
  connector_adapter.submit_for_activation(registry, subject, context, result)
}

/// Execute one metadata-only request through an injected transport and the
/// activation-aware evidence boundary. This function has no HTTP client.
pub fn execute_metadata(
  registry: connector_registry.Registry,
  subject: Subject(event_ingest.IngestMessage),
  context: operating_contracts.ConnectorSubmissionContext,
  url: String,
  transport: fn(String) -> Result(MetadataMessage, String),
) -> Result(Option(db.EvidenceInsert), String) {
  execute_metadata_with(url, transport, fn(message) {
    submit_metadata(registry, subject, context, message)
  })
}

/// Compose request validation, an injected metadata transport, and submission.
/// Tests use this boundary without a provider or credential.
pub fn execute_metadata_with(
  url: String,
  transport: fn(String) -> Result(MetadataMessage, String),
  submitter: fn(MetadataMessage) -> Result(a, String),
) -> Result(a, String) {
  use _ <- result.try(google_readonly_http.validate_request("GET", url))
  use message <- result.try(transport(url))
  submitter(message)
}

/// Execute one selected profile request through an injected transport.
pub fn execute_profile(
  url: String,
  identity_key: String,
  transport: fn(String) -> Result(Profile, String),
) -> Result(ProfileSeed, String) {
  use _ <- result.try(google_readonly_http.validate_request("GET", url))
  use profile <- result.try(transport(url))
  profile_seed(profile, identity_key)
}

/// Execute one bounded history request through an injected transport.
pub fn execute_history(
  url: String,
  max_pages: Int,
  max_items: Int,
  transport: fn(String) -> Result(HistoryRead, String),
) -> Result(HistoryOutcome, String) {
  use _ <- result.try(google_readonly_http.validate_request("GET", url))
  use response <- result.try(transport(url))
  case response {
    HistoryPages(pages) -> {
      use ids <- result.try(collect_history(pages, max_pages, max_items))
      Ok(SelectedMessageIds(ids))
    }
    HistoryCheckpointUnavailable(reason_code) -> {
      use gap <- result.try(history_gap(reason_code))
      Ok(CheckpointGap(gap))
    }
  }
}

fn display_sender(value: String) -> String {
  // Do not retain a local email-address part in compact evidence.
  let address = case string.split_once(value, on: "<") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, on: ">") {
        Ok(#(inside, _)) -> inside
        Error(_) -> ""
      }
    Error(_) -> string.trim(value)
  }
  case string.split(address, "@") {
    [local, domain] if local != "" && domain != "" ->
      "sender@" <> string.lowercase(domain)
    _ -> ""
  }
}

fn unique_identifiers(
  remaining: List(String),
  accepted: List(String),
  max_items: Int,
) -> Result(List(String), String) {
  case remaining {
    [] -> Ok(accepted)
    [identifier, ..rest] ->
      case valid_identifier(identifier) {
        False -> Error("gmail_history_identifier_invalid")
        True ->
          case list.contains(accepted, identifier) {
            True -> unique_identifiers(rest, accepted, max_items)
            False ->
              case list.length(accepted) >= max_items {
                True -> Error("gmail_history_item_limit_exceeded")
                False ->
                  unique_identifiers(rest, [identifier, ..accepted], max_items)
              }
          }
      }
  }
}

fn valid_identifier(value: String) -> Bool {
  let size = string.length(value)
  size > 0
  && size <= 256
  && {
    value
    |> string.to_graphemes
    |> list.all(fn(character) {
      string.contains(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
        character,
      )
    })
  }
}

fn valid_page_token(value: String) -> Bool {
  string.length(value) <= 1024
  && !string.contains(value, " ")
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn valid_history_id(value: String) -> Bool {
  valid_decimal(value, 256)
}

fn valid_decimal(value: String, maximum_bytes: Int) -> Bool {
  let size = string.byte_size(value)
  size > 0
  && size <= maximum_bytes
  && !string.starts_with(value, "0")
  && {
    value
    |> string.to_graphemes
    |> list.all(fn(character) { string.contains("0123456789", character) })
  }
}

fn validate_json_shape(
  raw: String,
  allowed: List(String),
  error: String,
) -> Result(dict.Dict(String, Dynamic), String) {
  use fields <- result.try(
    json.parse(raw, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) { error }),
  )
  case dict.keys(fields) |> list.all(fn(key) { list.contains(allowed, key) }) {
    True -> Ok(fields)
    False -> Error(error)
  }
}

fn validate_history_shape(
  top: dict.Dict(String, Dynamic),
) -> Result(Nil, String) {
  case dict.get(top, "history") {
    Error(_) -> Ok(Nil)
    Ok(value) -> {
      use records <- result.try(
        decode.run(value, decode.list(decode.dynamic))
        |> result.map_error(fn(_) { "gmail_history_response_fields_invalid" }),
      )
      records
      |> list.try_each(fn(record_value) {
        use record <- result.try(dynamic_object_with_keys(
          record_value,
          ["messagesAdded"],
          "gmail_history_response_fields_invalid",
        ))
        case dict.get(record, "messagesAdded") {
          Error(_) -> Ok(Nil)
          Ok(added_value) -> {
            use added <- result.try(
              decode.run(added_value, decode.list(decode.dynamic))
              |> result.map_error(fn(_) {
                "gmail_history_response_fields_invalid"
              }),
            )
            added
            |> list.try_each(fn(item_value) {
              use item <- result.try(dynamic_object_with_keys(
                item_value,
                ["message"],
                "gmail_history_response_fields_invalid",
              ))
              use message_value <- result.try(
                dict.get(item, "message")
                |> result.map_error(fn(_) {
                  "gmail_history_response_fields_invalid"
                }),
              )
              dynamic_object_with_keys(
                message_value,
                ["id", "threadId", "labelIds", "historyId"],
                "gmail_history_response_fields_invalid",
              )
              |> result.map(fn(_) { Nil })
            })
          }
        }
      })
    }
  }
}

fn validate_metadata_shape(
  top: dict.Dict(String, Dynamic),
) -> Result(Nil, String) {
  use payload_value <- result.try(
    dict.get(top, "payload")
    |> result.map_error(fn(_) { "gmail_metadata_response_fields_invalid" }),
  )
  use payload <- result.try(dynamic_object_with_keys(
    payload_value,
    ["headers"],
    "gmail_metadata_response_fields_invalid",
  ))
  use headers_value <- result.try(
    dict.get(payload, "headers")
    |> result.map_error(fn(_) { "gmail_metadata_response_fields_invalid" }),
  )
  use headers <- result.try(
    decode.run(headers_value, decode.list(decode.dynamic))
    |> result.map_error(fn(_) { "gmail_metadata_response_fields_invalid" }),
  )
  headers
  |> list.try_each(fn(header) {
    dynamic_object_with_keys(
      header,
      ["name", "value"],
      "gmail_metadata_response_fields_invalid",
    )
    |> result.map(fn(_) { Nil })
  })
}

fn dynamic_object_with_keys(
  value: Dynamic,
  allowed: List(String),
  error: String,
) -> Result(dict.Dict(String, Dynamic), String) {
  use fields <- result.try(
    decode.run(value, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) { error }),
  )
  case dict.keys(fields) |> list.all(fn(key) { list.contains(allowed, key) }) {
    True -> Ok(fields)
    False -> Error(error)
  }
}

fn raw_history_page_decoder() -> decode.Decoder(RawHistoryPage) {
  use history <- decode.optional_field(
    "history",
    [],
    decode.list({
      use messages_added <- decode.optional_field(
        "messagesAdded",
        [],
        decode.list({
          use message <- decode.field("message", {
            use message_id <- decode.field("id", decode.string)
            decode.success(RawHistoryMessage(message_id:))
          })
          decode.success(RawHistoryAdded(message:))
        }),
      )
      decode.success(RawHistoryRecord(messages_added:))
    }),
  )
  use history_id <- decode.field("historyId", decode.string)
  use next_page_token <- decode.optional_field(
    "nextPageToken",
    "",
    decode.string,
  )
  decode.success(RawHistoryPage(history:, history_id:, next_page_token:))
}

fn raw_metadata_decoder() -> decode.Decoder(RawMetadataMessage) {
  use message_id <- decode.field("id", decode.string)
  use thread_id <- decode.field("threadId", decode.string)
  use label_ids <- decode.optional_field(
    "labelIds",
    [],
    decode.list(decode.string),
  )
  use history_id <- decode.field("historyId", decode.string)
  use internal_date <- decode.field("internalDate", decode.string)
  use size_estimate <- decode.field("sizeEstimate", decode.int)
  use headers <- decode.field("payload", {
    use values <- decode.field(
      "headers",
      decode.list({
        use name <- decode.field("name", decode.string)
        use value <- decode.field("value", decode.string)
        decode.success(GmailHeader(name:, value:))
      }),
    )
    decode.success(values)
  })
  decode.success(RawMetadataMessage(
    message_id:,
    thread_id:,
    history_id:,
    internal_date:,
    label_ids:,
    size_estimate:,
    headers:,
  ))
}

fn header_value(headers: List(GmailHeader), name: String) -> String {
  headers
  |> list.filter_map(fn(header) {
    case header.name == name {
      True -> Ok(header.value)
      False -> Error(Nil)
    }
  })
  |> list.first
  |> result.unwrap("")
}
