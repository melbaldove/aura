//// Transport-neutral connector-result normalization.
////
//// This module can submit evidence. It cannot call a connector, make an
//// attention decision, enqueue attention, or deliver a user message.

import aura/connector_registry
import aura/db
import aura/event_ingest
import aura/evidence
import aura/operating_contracts
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result

/// Calculate the canonical semantic hash for one connector result.
pub fn content_hash(value: operating_contracts.ConnectorResult) -> String {
  let canonical =
    operating_contracts.encode_connector_result(
      operating_contracts.ConnectorResult(..value, content_hash: ""),
    )
  sha256(canonical)
}

/// Normalize one enabled connector result to the common evidence contract.
pub fn normalize(
  registry: connector_registry.Registry,
  value: operating_contracts.ConnectorResult,
) -> Result(operating_contracts.EvidenceEvent, String) {
  use decoded <- result.try(
    value
    |> operating_contracts.encode_connector_result
    |> operating_contracts.decode_connector_result,
  )
  use enabled <- result.try(connector_registry.validate_action(
    registry,
    connector_registry.ConnectorActionRequest(
      schema_version: decoded.schema_version,
      request_id: decoded.source_event_id,
      connector_id: decoded.connector_id,
      capability: decoded.capability,
      scope: decoded.scope,
      operation: decoded.operation,
      resource_ref: decoded.raw_ref,
      authority_grants: decoded.authority_grants,
    ),
  ))
  use _ <- result.try(
    case decoded.source_kind == enabled.descriptor.source_kind {
      True -> Ok(Nil)
      False -> Error("connector_source_kind_mismatch")
    },
  )
  use _ <- result.try(case decoded.content_hash == content_hash(decoded) {
    True -> Ok(Nil)
    False -> Error("connector_content_hash_mismatch")
  })
  let digest = identity_digest(decoded)
  let provenance =
    decoded.provenance
    |> dict.insert(
      "connector_id",
      operating_contracts.StructuredString(decoded.connector_id),
    )
    |> dict.insert(
      "capability",
      operating_contracts.StructuredString(decoded.capability),
    )
    |> dict.insert("scope", operating_contracts.StructuredString(decoded.scope))
    |> dict.insert(
      "descriptor_ref",
      operating_contracts.StructuredString(
        enabled.descriptor.descriptor_provenance_ref,
      ),
    )
    |> dict.insert(
      "configuration_ref",
      operating_contracts.StructuredString(enabled.activation.configuration_ref),
    )
    |> dict.insert(
      "policy_boundary_ref",
      operating_contracts.StructuredString(
        enabled.descriptor.policy_boundary_ref,
      ),
    )
    |> dict.insert(
      "authority_grants",
      operating_contracts.StructuredArray(
        decoded.authority_grants
        |> list.map(operating_contracts.StructuredString),
      ),
    )
  operating_contracts.EvidenceEvent(
    schema_version: 1,
    event_id: "event:" <> digest,
    source: "connector:" <> decoded.connector_id,
    source_kind: decoded.source_kind,
    event_type: decoded.event_type,
    external_id: Some("connector-event:" <> digest),
    resource: decoded.resource,
    observed_at: decoded.observed_at,
    summary: decoded.summary,
    normalized_data: decoded.normalized_data,
    raw_ref: Some(decoded.raw_ref),
    content_hash: decoded.content_hash,
    provenance: provenance,
    candidate_domain_refs: decoded.candidate_domain_refs,
    candidate_concern_refs: decoded.candidate_concern_refs,
    verification_status: decoded.verification_status,
  )
  |> evidence.apply_retention(
    enabled.descriptor.summary_limit,
    enabled.descriptor.value_limit,
  )
}

/// Normalize and submit one connector result through the common evidence actor.
pub fn submit(
  registry: connector_registry.Registry,
  subject: Subject(event_ingest.IngestMessage),
  value: operating_contracts.ConnectorResult,
) -> Result(db.EvidenceInsert, String) {
  use envelope <- result.try(normalize(registry, value))
  event_ingest.submit_evidence(subject, envelope)
}

/// Normalize and submit a result bound to one started connector read attempt.
pub fn submit_for_activation(
  registry: connector_registry.Registry,
  subject: Subject(event_ingest.IngestMessage),
  context: operating_contracts.ConnectorSubmissionContext,
  value: operating_contracts.ConnectorResult,
) -> Result(Option(db.EvidenceInsert), String) {
  use envelope <- result.try(normalize(registry, value))
  event_ingest.submit_authorized_evidence(subject, context, envelope)
}

/// Normalize and submit one bounded result batch under one read attempt.
pub fn submit_batch_for_activation(
  registry: connector_registry.Registry,
  subject: Subject(event_ingest.IngestMessage),
  context: operating_contracts.ConnectorSubmissionContext,
  values: List(operating_contracts.ConnectorResult),
) -> Result(Option(List(db.EvidenceInsert)), String) {
  use envelopes <- result.try(
    list.try_map(values, fn(value) { normalize(registry, value) }),
  )
  event_ingest.submit_authorized_evidence_batch(subject, context, envelopes)
}

/// Normalize and atomically submit a bounded batch plus its checkpoint.
pub fn submit_batch_with_checkpoint(
  registry: connector_registry.Registry,
  subject: Subject(event_ingest.IngestMessage),
  context: operating_contracts.ConnectorSubmissionContext,
  values: List(operating_contracts.ConnectorResult),
  checkpoint: db.ConnectorCheckpointUpdate,
) -> Result(Option(List(db.EvidenceInsert)), String) {
  use envelopes <- result.try(
    list.try_map(values, fn(value) { normalize(registry, value) }),
  )
  event_ingest.submit_authorized_evidence_batch_with_checkpoint(
    subject,
    context,
    envelopes,
    checkpoint,
  )
}

fn identity_digest(value: operating_contracts.ConnectorResult) -> String {
  json.array(
    [value.connector_id, value.capability, value.scope, value.source_event_id],
    of: json.string,
  )
  |> json.to_string
  |> sha256
}

fn sha256(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>) |> bit_array.base16_encode
}
