//// Pure Google Calendar REST metadata normalization.
////
//// This module has no HTTP client. A caller can inject a local test transport
//// only after the GET-only request guard and an activation check pass.

import aura/connector_activation
import aura/connector_adapter
import aura/connector_registry
import aura/db
import aura/event_ingest
import aura/google_readonly_http
import aura/operating_contracts
import aura/secret
import aura/time
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

const readonly_scope = "https://www.googleapis.com/auth/calendar.readonly"

/// The primary-calendar identity. The raw value is not retained.
pub type CalendarIdentity {
  CalendarIdentity(identity: String)
}

/// An opaque account proof for a Calendar configuration.
pub type IdentitySeed {
  IdentitySeed(account_fingerprint: String, proof_hash: String)
}

/// The complete Calendar event metadata that Aura can normalize.
pub type CalendarEvent {
  CalendarEvent(
    event_id: String,
    etag: String,
    status: String,
    summary: String,
    start: String,
    end: String,
    updated: String,
    recurring_event_id: Option(String),
    event_type: String,
    transparency: String,
    visibility: String,
    updated_at_ms: Int,
    observed_at_ms: Int,
  )
}

/// Immutable Calendar read limits selected by one canary authorization.
pub opaque type CalendarReadAuthority {
  CalendarReadAuthority(
    authorization_id: String,
    activation_id: String,
    time_min: String,
    time_max: String,
    max_results: Int,
    max_pages: Int,
    max_items: Int,
    max_response_bytes: Int,
  )
}

/// One bounded Calendar events page from an injected read-only transport.
pub type EventsPage {
  EventsPage(
    events: List(CalendarEvent),
    next_page_token: String,
    response_bytes: Int,
  )
}

type RawEventTime {
  RawEventTime(date: String, date_time: String)
}

type RawCalendarEvent {
  RawCalendarEvent(
    event_id: String,
    etag: String,
    status: String,
    summary: String,
    start: RawEventTime,
    end: RawEventTime,
    updated: String,
    recurring_event_id: Option(String),
    event_type: String,
    transparency: String,
    visibility: String,
  )
}

type RawEventsPage {
  RawEventsPage(events: List(RawCalendarEvent), next_page_token: String)
}

/// Derive an opaque Calendar account proof with a connector-specific key.
pub fn identity_seed(
  identity: CalendarIdentity,
  identity_key: String,
) -> Result(IdentitySeed, String) {
  let normalized = identity.identity |> string.trim |> string.lowercase
  case
    normalized != ""
    && string.byte_size(normalized) <= 512
    && string.length(identity_key) >= 32
    && string.length(identity_key) <= 256
  {
    False -> Error("calendar_identity_invalid")
    True -> {
      let canonical = "aura.calendar.account.v1\u{0}" <> normalized
      let fingerprint =
        secret.hmac_sha256(identity_key, canonical) |> string.lowercase
      let proof = "aura.calendar.identity-proof.v1\u{0}" <> fingerprint
      let proof_hash =
        crypto.hash(crypto.Sha256, <<proof:utf8>>)
        |> bit_array.base16_encode
      Ok(IdentitySeed(fingerprint, proof_hash))
    }
  }
}

/// Convert selected Calendar event metadata to compact connector evidence.
pub fn event_to_result(
  event: CalendarEvent,
) -> Result(operating_contracts.ConnectorResult, String) {
  use _ <- result.try(validate_event(event))
  let version_digest = event_version_digest(event.event_id, event.etag)
  let summary = case event.summary {
    "" -> "Cancelled calendar event"
    value -> value
  }
  let schedule = case event.start, event.end {
    "", "" -> []
    start, end -> [
      #("start", operating_contracts.StructuredString(start)),
      #("end", operating_contracts.StructuredString(end)),
    ]
  }
  let recurring_ref = case event.recurring_event_id {
    None -> []
    Some(identifier) -> [
      #(
        "recurring_event_ref",
        operating_contracts.StructuredString(
          "calendar:series:" <> opaque_digest(identifier),
        ),
      ),
    ]
  }
  let base =
    operating_contracts.ConnectorResult(
      schema_version: 1,
      connector_id: "calendar",
      source_kind: "connector",
      capability: "calendar.read",
      scope: readonly_scope,
      operation: "read",
      source_event_id: "event-version:" <> version_digest,
      event_type: "calendar.event.metadata_observed",
      resource: dict.from_list([
        #("kind", operating_contracts.StructuredString("calendar_event")),
        #(
          "id",
          operating_contracts.StructuredString(
            "calendar:event:" <> version_digest,
          ),
        ),
      ]),
      // Provider update time is stable for one event ID and etag. Poll time is
      // not semantic evidence and must not turn an exact repeat into conflict.
      observed_at: event.updated_at_ms,
      summary:,
      normalized_data: dict.from_list(list.append(
        [
          #("status", operating_contracts.StructuredString(event.status)),
          #("updated", operating_contracts.StructuredString(event.updated)),
          #(
            "event_type",
            operating_contracts.StructuredString(event.event_type),
          ),
          #(
            "transparency",
            operating_contracts.StructuredString(event.transparency),
          ),
          #(
            "visibility",
            operating_contracts.StructuredString(event.visibility),
          ),
        ],
        list.append(schedule, recurring_ref),
      )),
      raw_ref: "calendar://event/" <> version_digest,
      content_hash: "",
      provenance: dict.from_list([
        #(
          "adapter",
          operating_contracts.StructuredString("calendar_api_readonly"),
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

/// Select Calendar read limits from one immutable authorization and its exact
/// server-issued submission context.
pub fn read_authority(
  authorization: operating_contracts.CanaryAuthorizationV1,
  context: operating_contracts.ConnectorSubmissionContext,
) -> Result(CalendarReadAuthority, String) {
  use connector <- result.try(
    authorization.connectors
    |> list.find(fn(connector) { connector.connector_id == "calendar" })
    |> result.map_error(fn(_) { "calendar_authority_not_found" }),
  )
  case
    context.authorization_id == authorization.authorization_id
    && context.activation_id == connector.activation_id
    && context.connector_id == connector.connector_id
    && context.capability == connector.capability
    && context.oauth_scope == connector.oauth_scope
    && context.configuration_hash == connector.configuration_hash
    && context.account_fingerprint == connector.account_fingerprint
    && context.domain_id == authorization.domain_id
    && context.concern_id == authorization.concern_id
    && connector.oauth_scope == readonly_scope
    && connector.capability == "calendar.read"
    && connector.max_pages_per_poll > 0
    && connector.max_items_per_poll > 0
    && connector.max_response_bytes > 0
    && authorization.ends_at_ms > authorization.starts_at_ms
  {
    False -> Error("calendar_authority_mismatch")
    True ->
      Ok(CalendarReadAuthority(
        authorization_id: authorization.authorization_id,
        activation_id: connector.activation_id,
        time_min: time.format_ms_rfc3339_utc(authorization.starts_at_ms),
        time_max: time.format_ms_rfc3339_utc(authorization.ends_at_ms),
        max_results: case connector.max_items_per_poll > 100 {
          True -> 100
          False -> connector.max_items_per_poll
        },
        max_pages: connector.max_pages_per_poll,
        max_items: connector.max_items_per_poll,
        max_response_bytes: connector.max_response_bytes,
      ))
  }
}

/// Decode one exact Calendar events partial response.
///
/// The decoder rejects every field that is not in the reviewed metadata
/// projection. It does not accept descriptions, attendees, conference data,
/// attachments, or extended properties.
pub fn decode_events_page_response(raw: String) -> Result(EventsPage, String) {
  use top <- result.try(validate_object_shape(
    raw,
    ["items", "nextPageToken"],
    "calendar_response_fields_invalid",
  ))
  use _ <- result.try(validate_events_shape(top))
  use selected <- result.try(
    json.parse(raw, raw_events_page_decoder())
    |> result.map_error(fn(_) { "calendar_response_invalid" }),
  )
  use events <- result.try(
    list.try_map(selected.events, fn(raw_event) {
      use start <- result.try(selected_event_time(raw_event.start))
      use end <- result.try(selected_event_time(raw_event.end))
      use updated_at_ms <- result.try(
        time.parse_rfc3339_ms(raw_event.updated)
        |> result.map_error(fn(_) { "calendar_response_invalid" }),
      )
      let event =
        CalendarEvent(
          event_id: raw_event.event_id,
          etag: raw_event.etag,
          status: raw_event.status,
          summary: raw_event.summary,
          start:,
          end:,
          updated: raw_event.updated,
          recurring_event_id: raw_event.recurring_event_id,
          event_type: raw_event.event_type,
          transparency: raw_event.transparency,
          visibility: raw_event.visibility,
          updated_at_ms:,
          observed_at_ms: updated_at_ms,
        )
      use _ <- result.try(validate_event(event))
      Ok(event)
    }),
  )
  use _ <- result.try(case valid_page_token(selected.next_page_token) {
    True -> Ok(Nil)
    False -> Error("calendar_response_invalid")
  })
  Ok(EventsPage(
    events:,
    next_page_token: selected.next_page_token,
    response_bytes: string.byte_size(raw),
  ))
}

/// Submit one Calendar event only through the activation-aware evidence path.
pub fn submit_event(
  registry: connector_registry.Registry,
  subject: Subject(event_ingest.IngestMessage),
  context: operating_contracts.ConnectorSubmissionContext,
  event: CalendarEvent,
) -> Result(Option(db.EvidenceInsert), String) {
  use connector_result <- result.try(event_to_result(event))
  connector_adapter.submit_for_activation(
    registry,
    subject,
    context,
    connector_result,
  )
}

/// Execute one complete bounded local page projection.
///
/// Aura builds and validates each page request before the injected local
/// transport receives it. This function does not contain a provider client.
pub fn execute_pages_with(
  authority: CalendarReadAuthority,
  url: String,
  transport: fn(String) -> Result(EventsPage, String),
  submitter: fn(List(CalendarEvent)) -> Result(a, String),
) -> Result(a, String) {
  use _ <- result.try(case string.contains(url, "pageToken=") {
    True -> Error("calendar_initial_page_token_forbidden")
    False -> Ok(Nil)
  })
  use events <- result.try(fetch_pages(authority, url, url, transport, [], 0, 0))
  submitter(events)
}

/// Execute a bounded page projection and submit every result through the
/// activation-aware evidence transaction.
///
/// One server-issued read attempt owns the provider page set and the atomic
/// evidence batch. No provider transport is present in this module.
pub fn execute_pages(
  registry: connector_registry.Registry,
  db_subject: Subject(db.DbMessage),
  subject: Subject(event_ingest.IngestMessage),
  authorization: operating_contracts.CanaryAuthorizationV1,
  context: operating_contracts.ConnectorSubmissionContext,
  url: String,
  transport: fn(String) -> Result(EventsPage, String),
) -> Result(Option(List(db.EvidenceInsert)), String) {
  use authority <- result.try(read_authority(authorization, context))
  use effective <- result.try(connector_activation.load_effective(
    db_subject,
    context.activation_id,
    context.authorization_id,
  ))
  use _ <- result.try(case effective {
    Some(activation) if activation.version == context.activation_version ->
      Ok(Nil)
    _ -> Error("calendar_activation_not_effective")
  })
  execute_pages_with(authority, url, transport, fn(events) {
    submit_events(registry, subject, authorization, context, events)
  })
}

/// Submit a bounded event set through one activation-aware read attempt.
pub fn submit_events(
  registry: connector_registry.Registry,
  subject: Subject(event_ingest.IngestMessage),
  authorization: operating_contracts.CanaryAuthorizationV1,
  context: operating_contracts.ConnectorSubmissionContext,
  events: List(CalendarEvent),
) -> Result(Option(List(db.EvidenceInsert)), String) {
  use _ <- result.try(read_authority(authorization, context))
  use values <- result.try(list.try_map(events, event_to_result))
  connector_adapter.submit_batch_for_activation(
    registry,
    subject,
    context,
    values,
  )
}

fn fetch_pages(
  authority: CalendarReadAuthority,
  base_url: String,
  request_url: String,
  transport: fn(String) -> Result(EventsPage, String),
  events: List(CalendarEvent),
  page_count: Int,
  response_bytes: Int,
) -> Result(List(CalendarEvent), String) {
  use _ <- result.try(google_readonly_http.validate_calendar_request(
    "GET",
    request_url,
    authority.time_min,
    authority.time_max,
    authority.max_results,
  ))
  use page <- result.try(transport(request_url))
  use page_events <- result.try(collect_pages(
    [page],
    1,
    authority.max_items,
    authority.max_response_bytes,
  ))
  let next_events = list.append(events, page_events)
  let next_page_count = page_count + 1
  let next_response_bytes = response_bytes + page.response_bytes
  use _ <- result.try(
    case
      next_page_count <= authority.max_pages
      && list.length(next_events) <= authority.max_items
      && next_response_bytes <= authority.max_response_bytes
    {
      True -> Ok(Nil)
      False -> Error("calendar_response_limit_exceeded")
    },
  )
  case page.next_page_token {
    "" -> Ok(next_events)
    _ if next_page_count >= authority.max_pages ->
      Error("calendar_page_limit_exceeded")
    token ->
      fetch_pages(
        authority,
        base_url,
        base_url <> "&pageToken=" <> uri.percent_encode(token),
        transport,
        next_events,
        next_page_count,
        next_response_bytes,
      )
  }
}

/// Validate and flatten bounded Calendar response pages.
pub fn collect_pages(
  pages: List(EventsPage),
  max_pages: Int,
  max_items: Int,
  max_response_bytes: Int,
) -> Result(List(CalendarEvent), String) {
  case
    max_pages > 0
    && max_items > 0
    && max_response_bytes > 0
    && list.length(pages) <= max_pages
  {
    False -> Error("calendar_page_limit_exceeded")
    True -> {
      use _ <- result.try(
        list.try_each(pages, fn(page) {
          case
            page.response_bytes >= 0 && valid_page_token(page.next_page_token)
          {
            True -> Ok(Nil)
            False -> Error("calendar_page_invalid")
          }
        }),
      )
      let response_bytes =
        pages |> list.fold(0, fn(total, page) { total + page.response_bytes })
      let events = pages |> list.flat_map(fn(page) { page.events })
      case
        response_bytes <= max_response_bytes && list.length(events) <= max_items
      {
        False -> Error("calendar_response_limit_exceeded")
        True -> {
          use _ <- result.try(
            list.try_each(events, fn(event) {
              event_to_result(event) |> result.map(fn(_) { Nil })
            }),
          )
          Ok(events)
        }
      }
    }
  }
}

fn validate_event(event: CalendarEvent) -> Result(Nil, String) {
  let recurring_valid = case event.recurring_event_id {
    None -> True
    Some(identifier) -> valid_identifier(identifier)
  }
  case
    valid_identifier(event.event_id)
    && bounded_text(event.etag, 256)
    && list.contains(["confirmed", "tentative", "cancelled"], event.status)
    && string.byte_size(event.summary) <= 512
    && valid_schedule(event.status, event.start, event.end)
    && bounded_text(event.updated, 256)
    && valid_enum(event.event_type)
    && valid_enum(event.transparency)
    && valid_enum(event.visibility)
    && recurring_valid
    && event.updated_at_ms > 0
    && event.observed_at_ms > 0
  {
    True -> Ok(Nil)
    False -> Error("calendar_event_invalid")
  }
}

fn event_version_digest(event_id: String, etag: String) -> String {
  "aura.calendar.event-version.v1\u{0}"
  <> event_id
  <> "\u{0}"
  <> etag
  |> opaque_digest
}

fn opaque_digest(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>) |> bit_array.base16_encode
}

fn valid_identifier(value: String) -> Bool {
  value != ""
  && string.byte_size(value) <= 256
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

fn valid_enum(value: String) -> Bool {
  valid_identifier(value) && string.byte_size(value) <= 64
}

fn bounded_text(value: String, limit: Int) -> Bool {
  value != ""
  && string.byte_size(value) <= limit
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn valid_page_token(value: String) -> Bool {
  string.byte_size(value) <= 1024
  && !string.contains(value, " ")
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn selected_event_time(value: RawEventTime) -> Result(String, String) {
  case value.date, value.date_time {
    "", "" -> Ok("")
    date, "" ->
      case bounded_text(date, 32) {
        True -> Ok(date)
        False -> Error("calendar_response_invalid")
      }
    "", date_time ->
      case bounded_text(date_time, 64) {
        True -> Ok(date_time)
        False -> Error("calendar_response_invalid")
      }
    _, _ -> Error("calendar_response_invalid")
  }
}

fn valid_schedule(status: String, start: String, end: String) -> Bool {
  case start, end {
    "", "" -> status == "cancelled"
    "", _ | _, "" -> False
    start, end -> valid_calendar_time(start) && valid_calendar_time(end)
  }
}

fn valid_calendar_time(value: String) -> Bool {
  case string.contains(value, "T") {
    True -> time.parse_rfc3339_ms(value) |> result.is_ok
    False -> time.valid_calendar_date(value)
  }
}

fn validate_object_shape(
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

fn validate_events_shape(top: dict.Dict(String, Dynamic)) -> Result(Nil, String) {
  case dict.get(top, "items") {
    Error(_) -> Ok(Nil)
    Ok(value) -> {
      use events <- result.try(
        decode.run(value, decode.list(decode.dynamic))
        |> result.map_error(fn(_) { "calendar_response_fields_invalid" }),
      )
      events
      |> list.try_each(fn(event_value) {
        use event <- result.try(dynamic_object_with_keys(
          event_value,
          [
            "id",
            "etag",
            "status",
            "summary",
            "start",
            "end",
            "updated",
            "recurringEventId",
            "eventType",
            "transparency",
            "visibility",
          ],
          "calendar_response_fields_invalid",
        ))
        use _ <- result.try(validate_optional_event_time_shape(event, "start"))
        validate_optional_event_time_shape(event, "end")
      })
    }
  }
}

fn validate_event_time_shape(
  event: dict.Dict(String, Dynamic),
  field: String,
) -> Result(Nil, String) {
  use value <- result.try(
    dict.get(event, field)
    |> result.map_error(fn(_) { "calendar_response_fields_invalid" }),
  )
  dynamic_object_with_keys(
    value,
    ["date", "dateTime"],
    "calendar_response_fields_invalid",
  )
  |> result.map(fn(_) { Nil })
}

fn validate_optional_event_time_shape(
  event: dict.Dict(String, Dynamic),
  field: String,
) -> Result(Nil, String) {
  case dict.get(event, field) {
    Error(_) -> Ok(Nil)
    Ok(_) -> validate_event_time_shape(event, field)
  }
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

fn raw_events_page_decoder() -> decode.Decoder(RawEventsPage) {
  use events <- decode.optional_field(
    "items",
    [],
    decode.list(raw_calendar_event_decoder()),
  )
  use next_page_token <- decode.optional_field(
    "nextPageToken",
    "",
    decode.string,
  )
  decode.success(RawEventsPage(events:, next_page_token:))
}

fn raw_calendar_event_decoder() -> decode.Decoder(RawCalendarEvent) {
  use event_id <- decode.field("id", decode.string)
  use etag <- decode.field("etag", decode.string)
  use status <- decode.field("status", decode.string)
  use summary <- decode.optional_field("summary", "", decode.string)
  use start <- decode.optional_field(
    "start",
    RawEventTime("", ""),
    event_time_decoder(),
  )
  use end <- decode.optional_field(
    "end",
    RawEventTime("", ""),
    event_time_decoder(),
  )
  use updated <- decode.field("updated", decode.string)
  use recurring_event_id <- decode.optional_field(
    "recurringEventId",
    None,
    decode.optional(decode.string),
  )
  use event_type <- decode.optional_field("eventType", "default", decode.string)
  use transparency <- decode.optional_field(
    "transparency",
    "opaque",
    decode.string,
  )
  use visibility <- decode.optional_field(
    "visibility",
    "default",
    decode.string,
  )
  decode.success(RawCalendarEvent(
    event_id:,
    etag:,
    status:,
    summary:,
    start:,
    end:,
    updated:,
    recurring_event_id:,
    event_type:,
    transparency:,
    visibility:,
  ))
}

fn event_time_decoder() -> decode.Decoder(RawEventTime) {
  use date <- decode.optional_field("date", "", decode.string)
  use date_time <- decode.optional_field("dateTime", "", decode.string)
  decode.success(RawEventTime(date:, date_time:))
}
