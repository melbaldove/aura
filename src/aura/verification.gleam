//// Versioned verification record contract.

import gleam/dynamic/decode as dynamic_decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub const schema_version = 1

pub type Record {
  Record(
    schema_version: Int,
    verification_id: String,
    target_type: String,
    target_id: String,
    requirement: String,
    method: String,
    result: String,
    evidence_refs: List(String),
    verifier: String,
    verified_at: Int,
  )
}

/// Encode one verification record as compact JSON.
pub fn encode(value: Record) -> String {
  json.object([
    #("schema_version", json.int(value.schema_version)),
    #("verification_id", json.string(value.verification_id)),
    #("target_type", json.string(value.target_type)),
    #("target_id", json.string(value.target_id)),
    #("requirement", json.string(value.requirement)),
    #("method", json.string(value.method)),
    #("result", json.string(value.result)),
    #("evidence_refs", json.array(value.evidence_refs, of: json.string)),
    #("verifier", json.string(value.verifier)),
    #("verified_at", json.int(value.verified_at)),
  ])
  |> json.to_string
}

/// Decode and validate one version-1 verification record.
pub fn decode(raw: String) -> Result(Record, String) {
  json.parse(raw, decoder())
  |> result.map_error(fn(error) {
    "Invalid verification record: " <> string.inspect(error)
  })
}

fn decoder() {
  use schema_version <- dynamic_decode.field(
    "schema_version",
    version_decoder(),
  )
  use verification_id <- dynamic_decode.field(
    "verification_id",
    dynamic_decode.string,
  )
  use target_type <- dynamic_decode.field("target_type", dynamic_decode.string)
  use target_id <- dynamic_decode.field("target_id", dynamic_decode.string)
  use requirement <- dynamic_decode.field("requirement", dynamic_decode.string)
  use method <- dynamic_decode.field("method", dynamic_decode.string)
  use result_value <- dynamic_decode.field("result", result_decoder())
  use evidence_refs <- dynamic_decode.field(
    "evidence_refs",
    dynamic_decode.list(dynamic_decode.string),
  )
  use verifier <- dynamic_decode.field("verifier", dynamic_decode.string)
  use verified_at <- dynamic_decode.field("verified_at", dynamic_decode.int)
  dynamic_decode.success(Record(
    schema_version:,
    verification_id:,
    target_type:,
    target_id:,
    requirement:,
    method:,
    result: result_value,
    evidence_refs:,
    verifier:,
    verified_at:,
  ))
}

fn version_decoder() {
  use version <- dynamic_decode.then(dynamic_decode.int)
  case version == schema_version {
    True -> dynamic_decode.success(version)
    False -> dynamic_decode.failure(0, expected: "schema_version 1")
  }
}

fn result_decoder() {
  use value <- dynamic_decode.then(dynamic_decode.string)
  case list.contains(["pass", "fail", "unknown"], value) {
    True -> dynamic_decode.success(value)
    False -> dynamic_decode.failure("", expected: "verification result")
  }
}
