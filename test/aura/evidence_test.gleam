import aura/evidence
import aura/operating_contracts
import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn envelope(source: String, source_kind: String) {
  operating_contracts.EvidenceEvent(
    schema_version: 1,
    event_id: "ev-" <> source,
    source: source,
    source_kind: source_kind,
    event_type: "resource.changed",
    external_id: Some("resource-1"),
    resource: dict.from_list([
      #("kind", operating_contracts.StructuredString("external_resource")),
      #("id", operating_contracts.StructuredString("resource-1")),
    ]),
    observed_at: 1000,
    summary: "A compact source observation.",
    normalized_data: dict.from_list([
      #("status", operating_contracts.StructuredString("changed")),
    ]),
    raw_ref: Some("opaque://resource/1"),
    content_hash: "hash-1",
    provenance: dict.from_list([
      #("adapter", operating_contracts.StructuredString("fixture")),
    ]),
    candidate_domain_refs: [],
    candidate_concern_refs: [],
    verification_status: "verified",
  )
}

pub fn common_envelope_accepts_all_required_source_fixtures_test() {
  [
    #("gmail", "connector"),
    #("calendar", "connector"),
    #("slack", "connector"),
    #("jira", "connector"),
    #("confluence", "connector"),
    #("github", "connector"),
    #("scheduler", "schedule"),
    #("hook", "hook"),
    #("codex", "codex"),
    #("claude", "claude"),
  ]
  |> list.each(fn(item) {
    evidence.normalize(envelope(item.0, item.1)) |> should.be_ok
  })
}

pub fn retention_compacts_values_and_keeps_opaque_raw_reference_test() {
  let value =
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      summary: "1234567890",
      normalized_data: dict.from_list([
        #("text", operating_contracts.StructuredString("abcdefghij")),
      ]),
    )
  let compact = evidence.apply_retention(value, 6, 5) |> should.be_ok
  compact.summary |> should.equal("123456")
  dict.get(compact.normalized_data, "text")
  |> should.equal(Ok(operating_contracts.StructuredString("abcde")))
  compact.raw_ref |> should.equal(Some("opaque://resource/1"))
}

pub fn normalization_rejects_empty_canonical_identifiers_test() {
  [
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      event_id: "",
    ),
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      source: " ",
    ),
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      event_type: "",
    ),
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      content_hash: "",
    ),
  ]
  |> list.each(fn(value) { evidence.normalize(value) |> should.be_error })
}

pub fn retention_compacts_all_stored_envelope_fields_test() {
  let value =
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      resource: dict.from_list([
        #("kind", operating_contracts.StructuredString("record")),
        #("id", operating_contracts.StructuredString("1234")),
      ]),
      provenance: dict.from_list([
        #("adapter", operating_contracts.StructuredString("abcdefghij")),
      ]),
      raw_ref: Some("x://1"),
      candidate_domain_refs: ["d:12"],
      candidate_concern_refs: ["c:12"],
    )
  let compact = evidence.apply_retention(value, 6, 5) |> should.be_ok
  dict.get(compact.resource, "id")
  |> should.equal(Ok(operating_contracts.StructuredString("1234")))
  dict.get(compact.provenance, "adapter")
  |> should.equal(Ok(operating_contracts.StructuredString("abcde")))
  compact.raw_ref |> should.equal(Some("x://1"))
  compact.candidate_domain_refs |> should.equal(["d:12"])
  compact.candidate_concern_refs |> should.equal(["c:12"])
}

pub fn retention_rejects_oversized_identity_and_reference_fields_test() {
  let oversized = string.repeat("x", 1001)
  [
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      resource: dict.from_list([
        #("kind", operating_contracts.StructuredString("record")),
        #("id", operating_contracts.StructuredString(oversized)),
      ]),
    ),
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      raw_ref: Some("opaque://" <> oversized),
    ),
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      candidate_domain_refs: ["domain:" <> oversized],
    ),
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      external_id: Some(oversized),
    ),
  ]
  |> list.each(fn(value) {
    evidence.apply_retention(value, 6, 5) |> should.be_error
  })
}

pub fn retention_rejects_large_or_deep_collections_test() {
  let chunk = operating_contracts.StructuredString(string.repeat("x", 4000))
  [
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      candidate_domain_refs: list.repeat("domain:fixture", 101),
    ),
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      normalized_data: dict.from_list([
        #(
          "chunks",
          operating_contracts.StructuredArray(list.repeat(chunk, 101)),
        ),
      ]),
    ),
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      normalized_data: dict.from_list([#("nested", nested_object(9))]),
    ),
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      normalized_data: dict.from_list([
        #("chunks", operating_contracts.StructuredArray(list.repeat(chunk, 50))),
      ]),
    ),
  ]
  |> list.each(fn(value) { evidence.normalize(value) |> should.be_error })
}

fn nested_object(depth: Int) -> operating_contracts.StructuredValue {
  case depth {
    0 -> operating_contracts.StructuredString("leaf")
    _ ->
      operating_contracts.StructuredObject(
        dict.from_list([#("child", nested_object(depth - 1))]),
      )
  }
}

pub fn concern_candidates_keep_explicit_confidence_and_provenance_test() {
  let value =
    operating_contracts.EvidenceEvent(
      ..envelope("synthetic", "connector"),
      provenance: dict.from_list([
        #("adapter", operating_contracts.StructuredString("fixture")),
        #("concern_link_confidence", operating_contracts.StructuredFloat(0.82)),
        #(
          "concern_link_provenance",
          operating_contracts.StructuredString("adapter.rule:accounting"),
        ),
        #("concern_link_confirmed", operating_contracts.StructuredBool(False)),
      ]),
      candidate_concern_refs: ["concern:domain:accounts:monthly-close"],
    )
  let links = evidence.evaluate_concern_links(value) |> should.be_ok
  let assert [link] = links
  link.confidence |> should.equal(0.82)
  link.provenance |> should.equal("adapter.rule:accounting")
  link.confirmed |> should.be_false
}

pub fn adapter_supplies_resource_kind_without_core_connector_policy_test() {
  let value =
    operating_contracts.EvidenceEvent(
      ..envelope("new-source", "connector"),
      resource: dict.from_list([
        #("kind", operating_contracts.StructuredString("custom_record")),
        #("id", operating_contracts.StructuredString("r-9")),
      ]),
    )
  let legacy = evidence.to_legacy_event(value) |> should.be_ok
  dict.get(legacy.tags, "resource_kind")
  |> should.equal(Ok("custom_record"))
}
