//// Versioned append-only operational audit contract.

import gleam/dynamic/decode as dynamic_decode
import gleam/json
import gleam/option.{type Option, None}
import gleam/result
import gleam/string

pub const schema_version = 1

pub type Record {
  Record(
    schema_version: Int,
    audit_id: String,
    record_type: String,
    actor: String,
    source: String,
    action: String,
    target_type: String,
    target_id: String,
    before_version: Option(Int),
    after_version: Option(Int),
    idempotency_key: Option(String),
    evidence_refs: List(String),
    proof_refs: List(String),
    authority_ref: Option(String),
    result: String,
    error_code: Option(String),
    occurred_at: Int,
  )
}

/// Encode one operational audit record as compact JSON.
pub fn encode(value: Record) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("audit_id", json.string(value.audit_id)),
    #("record_type", json.string(value.record_type)),
    #("actor", json.string(value.actor)),
    #("source", json.string(value.source)),
    #("action", json.string(value.action)),
    #("target_type", json.string(value.target_type)),
    #("target_id", json.string(value.target_id)),
    #("before_version", json.nullable(value.before_version, of: json.int)),
    #("after_version", json.nullable(value.after_version, of: json.int)),
    #("idempotency_key", json.nullable(value.idempotency_key, of: json.string)),
    #("evidence_refs", json.array(value.evidence_refs, of: json.string)),
    #("proof_refs", json.array(value.proof_refs, of: json.string)),
    #("authority_ref", json.nullable(value.authority_ref, of: json.string)),
    #("result", json.string(value.result)),
    #("error_code", json.nullable(value.error_code, of: json.string)),
    #("occurred_at", json.int(value.occurred_at)),
  ])
  |> json.to_string
}

/// Decode and validate one version-1 operational audit record.
pub fn decode(raw: String) -> Result(Record, String) {
  json.parse(raw, decoder())
  |> result.map_error(fn(error) {
    "Invalid operational audit record: " <> string.inspect(error)
  })
}

fn decoder() {
  use schema_version <- dynamic_decode.field(
    "schema_version",
    version_decoder(),
  )
  use audit_id <- dynamic_decode.field("audit_id", dynamic_decode.string)
  use record_type <- dynamic_decode.field("record_type", dynamic_decode.string)
  use actor <- dynamic_decode.field("actor", dynamic_decode.string)
  use source <- dynamic_decode.field("source", dynamic_decode.string)
  use action <- dynamic_decode.field("action", dynamic_decode.string)
  use target_type <- dynamic_decode.field("target_type", dynamic_decode.string)
  use target_id <- dynamic_decode.field("target_id", dynamic_decode.string)
  use before_version <- optional_int_field("before_version")
  use after_version <- optional_int_field("after_version")
  use idempotency_key <- optional_string_field("idempotency_key")
  use evidence_refs <- dynamic_decode.field(
    "evidence_refs",
    dynamic_decode.list(dynamic_decode.string),
  )
  use proof_refs <- dynamic_decode.field(
    "proof_refs",
    dynamic_decode.list(dynamic_decode.string),
  )
  use authority_ref <- optional_string_field("authority_ref")
  use result_value <- dynamic_decode.field("result", dynamic_decode.string)
  use error_code <- optional_string_field("error_code")
  use occurred_at <- dynamic_decode.field("occurred_at", dynamic_decode.int)
  dynamic_decode.success(Record(
    schema_version:,
    audit_id:,
    record_type:,
    actor:,
    source:,
    action:,
    target_type:,
    target_id:,
    before_version:,
    after_version:,
    idempotency_key:,
    evidence_refs:,
    proof_refs:,
    authority_ref:,
    result: result_value,
    error_code:,
    occurred_at:,
  ))
}

fn version_decoder() {
  use version <- dynamic_decode.then(dynamic_decode.int)
  case version == schema_version {
    True -> dynamic_decode.success(version)
    False -> dynamic_decode.failure(0, expected: "schema_version 1")
  }
}

fn optional_int_field(
  name: String,
  next: fn(Option(Int)) -> dynamic_decode.Decoder(value),
) {
  dynamic_decode.optional_field(
    name,
    None,
    dynamic_decode.optional(dynamic_decode.int),
    next,
  )
}

fn optional_string_field(
  name: String,
  next: fn(Option(String)) -> dynamic_decode.Decoder(value),
) {
  dynamic_decode.optional_field(
    name,
    None,
    dynamic_decode.optional(dynamic_decode.string),
    next,
  )
}
