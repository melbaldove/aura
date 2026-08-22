//// Source-neutral evidence normalization and retention.

import aura/event
import aura/operating_contracts
import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string

pub const default_summary_limit = 500

pub const default_value_limit = 4000

const identifier_limit = 500

const reference_limit = 1000

const collection_limit = 100

const nesting_limit = 8

const input_envelope_limit = 1_000_000

const stored_envelope_limit = 64_000

/// One evaluated evidence-to-concern candidate.
pub type ConcernLink {
  ConcernLink(
    concern_id: String,
    confidence: Float,
    provenance: String,
    confirmed: Bool,
  )
}

/// Validate and compact one source-neutral evidence envelope.
pub fn normalize(
  value: operating_contracts.EvidenceEvent,
) -> Result(operating_contracts.EvidenceEvent, String) {
  let encoded = operating_contracts.encode_evidence_event(value)
  use _ <- result.try(case string.length(encoded) <= input_envelope_limit {
    True -> Ok(Nil)
    False -> Error("evidence_input_too_large")
  })
  use validated <- result.try(operating_contracts.decode_evidence_event(encoded))
  use _ <- result.try(validate_required_identifier(
    "event_id",
    validated.event_id,
  ))
  use _ <- result.try(validate_required_identifier("source", validated.source))
  use _ <- result.try(validate_required_identifier(
    "event_type",
    validated.event_type,
  ))
  use _ <- result.try(validate_required_identifier(
    "content_hash",
    validated.content_hash,
  ))
  apply_retention(validated, default_summary_limit, default_value_limit)
}

/// Apply the selected source retention limits before storage.
pub fn apply_retention(
  value: operating_contracts.EvidenceEvent,
  summary_limit: Int,
  value_limit: Int,
) -> Result(operating_contracts.EvidenceEvent, String) {
  use _ <- result.try(case summary_limit > 0 && value_limit > 0 {
    True -> Ok(Nil)
    False -> Error("invalid_evidence_retention_policy")
  })
  use _ <- result.try(validate_bounded_identifier(
    "event_id",
    value.event_id,
    identifier_limit,
  ))
  use _ <- result.try(case value.external_id {
    Some(external_id) ->
      validate_bounded_identifier("external_id", external_id, reference_limit)
    _ -> Ok(Nil)
  })
  use _ <- result.try(validate_bounded_identifier(
    "source",
    value.source,
    identifier_limit,
  ))
  use _ <- result.try(validate_bounded_identifier(
    "event_type",
    value.event_type,
    identifier_limit,
  ))
  use _ <- result.try(validate_bounded_identifier(
    "content_hash",
    value.content_hash,
    identifier_limit,
  ))
  use _ <- result.try(validate_bounded_identifier(
    "resource.kind",
    result.unwrap(resource_string(value, "kind"), ""),
    reference_limit,
  ))
  use _ <- result.try(validate_bounded_identifier(
    "resource.id",
    result.unwrap(resource_string(value, "id"), ""),
    reference_limit,
  ))
  use _ <- result.try(case value.raw_ref {
    Some(reference) ->
      case
        string.trim(reference) == reference
        && string.contains(reference, "://")
        && !string.contains(reference, " ")
        && !string.contains(reference, "\n")
        && string.length(reference) <= reference_limit
      {
        True -> Ok(Nil)
        False -> Error("invalid_evidence_raw_ref")
      }
    _ -> Error("evidence_raw_ref_required")
  })
  use _ <- result.try(validate_references(
    value.candidate_domain_refs,
    reference_limit,
  ))
  use _ <- result.try(validate_references(
    value.candidate_concern_refs,
    reference_limit,
  ))
  use _ <- result.try(validate_structured_fields(value.resource, 0))
  use _ <- result.try(validate_structured_fields(value.normalized_data, 0))
  use _ <- result.try(validate_structured_fields(value.provenance, 0))
  let compacted =
    operating_contracts.EvidenceEvent(
      ..value,
      summary: string.slice(value.summary, 0, summary_limit),
      resource: compact_fields(value.resource, value_limit),
      normalized_data: compact_fields(value.normalized_data, value_limit),
      provenance: compact_fields(value.provenance, value_limit),
    )
  use _ <- result.try(
    case
      compacted
      |> operating_contracts.encode_evidence_event
      |> string.length
      |> fn(length) { length <= stored_envelope_limit }
    {
      True -> Ok(Nil)
      False -> Error("evidence_storage_limit_exceeded")
    },
  )
  Ok(compacted)
}

fn validate_required_identifier(
  name: String,
  value: String,
) -> Result(Nil, String) {
  case string.trim(value) {
    "" -> Error("evidence_" <> name <> "_required")
    _ -> Ok(Nil)
  }
}

fn validate_bounded_identifier(
  name: String,
  value: String,
  limit: Int,
) -> Result(Nil, String) {
  use _ <- result.try(validate_required_identifier(name, value))
  case string.length(value) <= limit {
    True -> Ok(Nil)
    False -> Error("evidence_" <> name <> "_too_long")
  }
}

fn validate_references(values: List(String), limit: Int) -> Result(Nil, String) {
  use _ <- result.try(case list.length(values) <= collection_limit {
    True -> Ok(Nil)
    False -> Error("evidence_collection_limit_exceeded")
  })
  list.try_each(values, fn(value) {
    validate_bounded_identifier("candidate_reference", value, limit)
  })
}

fn compact_fields(
  fields: dict.Dict(String, operating_contracts.StructuredValue),
  limit: Int,
) -> dict.Dict(String, operating_contracts.StructuredValue) {
  fields
  |> dict.to_list
  |> list.map(fn(entry) { #(entry.0, compact_value(entry.1, limit)) })
  |> dict.from_list
}

fn validate_structured_fields(
  fields: dict.Dict(String, operating_contracts.StructuredValue),
  depth: Int,
) -> Result(Nil, String) {
  use _ <- result.try(validate_collection(
    depth,
    list.length(dict.to_list(fields)),
  ))
  fields
  |> dict.to_list
  |> list.try_each(fn(entry) {
    use _ <- result.try(validate_bounded_identifier(
      "field_name",
      entry.0,
      identifier_limit,
    ))
    validate_nested_fields(entry.1, depth + 1)
  })
}

fn validate_nested_fields(
  value: operating_contracts.StructuredValue,
  depth: Int,
) -> Result(Nil, String) {
  case value {
    operating_contracts.StructuredObject(fields) ->
      validate_structured_fields(fields, depth)
    operating_contracts.StructuredArray(items) -> {
      use _ <- result.try(validate_collection(depth, list.length(items)))
      list.try_each(items, fn(item) { validate_nested_fields(item, depth + 1) })
    }
    _ -> Ok(Nil)
  }
}

fn validate_collection(depth: Int, count: Int) -> Result(Nil, String) {
  case depth <= nesting_limit && count <= collection_limit {
    True -> Ok(Nil)
    False -> Error("evidence_collection_limit_exceeded")
  }
}

/// Evaluate declared concern candidates with explicit provenance metadata.
pub fn evaluate_concern_links(
  value: operating_contracts.EvidenceEvent,
) -> Result(List(ConcernLink), String) {
  case value.candidate_concern_refs {
    [] -> Ok([])
    refs -> {
      use confidence <- result.try(provenance_float(
        value.provenance,
        "concern_link_confidence",
      ))
      use provenance <- result.try(provenance_string(
        value.provenance,
        "concern_link_provenance",
      ))
      use confirmed <- result.try(provenance_bool(
        value.provenance,
        "concern_link_confirmed",
      ))
      use _ <- result.try(case confidence >=. 0.0 && confidence <=. 1.0 {
        True -> Ok(Nil)
        False -> Error("invalid_concern_link_confidence")
      })
      Ok(
        list.map(refs, fn(concern_id) {
          ConcernLink(concern_id:, confidence:, provenance:, confirmed:)
        }),
      )
    }
  }
}

/// Project normalized evidence into the legacy event view used by the current
/// cognitive worker. The payload is the compact envelope, not a raw resource.
pub fn to_legacy_event(
  value: operating_contracts.EvidenceEvent,
) -> Result(event.AuraEvent, String) {
  use resource_kind <- result.try(resource_string(value, "kind"))
  use resource_id <- result.try(resource_string(value, "id"))
  let external_id = case value.external_id {
    Some(id) ->
      case string.trim(id) {
        "" -> value.content_hash
        present -> present
      }
    _ -> value.content_hash
  }
  Ok(event.AuraEvent(
    id: value.event_id,
    source: value.source,
    type_: value.event_type,
    subject: value.summary,
    time_ms: value.observed_at,
    tags: dict.from_list([
      #("source_kind", value.source_kind),
      #("resource_kind", resource_kind),
      #("resource_id", resource_id),
    ]),
    external_id: external_id,
    data: operating_contracts.encode_evidence_event(value),
  ))
}

fn compact_value(
  value: operating_contracts.StructuredValue,
  limit: Int,
) -> operating_contracts.StructuredValue {
  case value {
    operating_contracts.StructuredString(text) ->
      operating_contracts.StructuredString(string.slice(text, 0, limit))
    operating_contracts.StructuredArray(items) ->
      operating_contracts.StructuredArray(
        list.map(items, fn(item) { compact_value(item, limit) }),
      )
    operating_contracts.StructuredObject(fields) ->
      operating_contracts.StructuredObject(compact_fields(fields, limit))
    other -> other
  }
}

fn resource_string(
  value: operating_contracts.EvidenceEvent,
  key: String,
) -> Result(String, String) {
  case dict.get(value.resource, key) {
    Ok(operating_contracts.StructuredString(text)) if text != "" -> Ok(text)
    _ -> Error("evidence_resource_" <> key <> "_required")
  }
}

fn provenance_float(
  fields: dict.Dict(String, operating_contracts.StructuredValue),
  key: String,
) -> Result(Float, String) {
  case dict.get(fields, key) {
    Ok(operating_contracts.StructuredFloat(value)) -> Ok(value)
    _ -> Error("missing_evidence_provenance: " <> key)
  }
}

fn provenance_string(
  fields: dict.Dict(String, operating_contracts.StructuredValue),
  key: String,
) -> Result(String, String) {
  case dict.get(fields, key) {
    Ok(operating_contracts.StructuredString(value)) if value != "" -> Ok(value)
    _ -> Error("missing_evidence_provenance: " <> key)
  }
}

fn provenance_bool(
  fields: dict.Dict(String, operating_contracts.StructuredValue),
  key: String,
) -> Result(Bool, String) {
  case dict.get(fields, key) {
    Ok(operating_contracts.StructuredBool(value)) -> Ok(value)
    _ -> Error("missing_evidence_provenance: " <> key)
  }
}
