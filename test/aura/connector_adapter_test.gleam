import aura/connector_adapter
import aura/connector_registry
import aura/db
import aura/event_ingest
import aura/operating_contracts
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn registry() {
  let fixtures = [
    #("gmail", "connector"),
    #("calendar", "connector"),
    #("slack", "connector"),
    #("jira", "connector"),
    #("github", "connector"),
    #("codex", "codex"),
    #("claude", "claude"),
    #("mcp", "mcp_tool"),
  ]
  connector_registry.build(
    list.map(fixtures, fn(item) {
      connector_registry.ConnectorDescriptor(
        schema_version: 1,
        connector_id: item.0,
        display_name: item.0,
        source_kind: item.1,
        capabilities: ["resource.read"],
        scopes: ["fixture.records"],
        descriptor_provenance_ref: "descriptor://fixture/" <> item.0,
        summary_limit: 300,
        value_limit: 1000,
        read_authority_ref: None,
        write_authority_ref: None,
        policy_boundary_ref: "policy://attention/default",
      )
    }),
    list.map(fixtures, fn(item) {
      connector_registry.ConnectorActivation(
        schema_version: 1,
        connector_id: item.0,
        state: "enabled",
        configuration_ref: "config://fixture/" <> item.0,
      )
    }),
  )
  |> should.be_ok
}

fn result_fixture(
  connector_id: String,
  source_kind: String,
  source_event_id: String,
) {
  let base =
    operating_contracts.ConnectorResult(
      schema_version: 1,
      connector_id: connector_id,
      source_kind: source_kind,
      capability: "resource.read",
      scope: "fixture.records",
      operation: "read",
      source_event_id: source_event_id,
      event_type: "resource.observed",
      resource: dict.from_list([
        #("kind", operating_contracts.StructuredString("fixture_record")),
        #("id", operating_contracts.StructuredString("record-1")),
      ]),
      observed_at: 1000,
      summary: "A compact fixture result.",
      normalized_data: dict.from_list([
        #("status", operating_contracts.StructuredString("observed")),
      ]),
      raw_ref: "opaque://fixture/result/1",
      content_hash: "pending",
      provenance: dict.from_list([
        #("adapter", operating_contracts.StructuredString("fixture")),
      ]),
      candidate_domain_refs: [],
      candidate_concern_refs: [],
      verification_status: "verified",
      authority_grants: [],
    )
  operating_contracts.ConnectorResult(
    ..base,
    content_hash: connector_adapter.content_hash(base),
  )
}

pub fn named_result_shapes_normalize_through_one_contract_test() {
  let registry = registry()
  [
    #("gmail", "connector"),
    #("calendar", "connector"),
    #("slack", "connector"),
    #("jira", "connector"),
    #("github", "connector"),
    #("codex", "codex"),
    #("claude", "claude"),
    #("mcp", "mcp_tool"),
  ]
  |> list.each(fn(item) {
    let envelope =
      connector_adapter.normalize(
        registry,
        result_fixture(item.0, item.1, "event-1"),
      )
      |> should.be_ok
    envelope.source |> should.equal("connector:" <> item.0)
    envelope.raw_ref |> should.equal(Some("opaque://fixture/result/1"))
  })
}

pub fn result_codec_rejects_transcript_fields_and_non_opaque_refs_test() {
  let valid = result_fixture("mcp", "mcp_tool", "event-codec")
  let raw = operating_contracts.encode_connector_result(valid)
  operating_contracts.decode_connector_result(raw) |> should.be_ok
  operating_contracts.decode_connector_result(
    "{\"schema_version\":1,\"transcript\":\"copied words\"}",
  )
  |> should.equal(Error("Raw conversation transcript fields are not permitted"))
  connector_adapter.normalize(
    registry(),
    operating_contracts.ConnectorResult(..valid, raw_ref: "copied words"),
  )
  |> should.be_error
}

pub fn identity_is_collision_safe_for_delimiter_characters_test() {
  let registry = registry()
  let first =
    connector_adapter.normalize(
      registry,
      result_fixture("mcp", "mcp_tool", "a|scope:b"),
    )
    |> should.be_ok
  let second =
    connector_adapter.normalize(
      registry,
      result_fixture("mcp", "mcp_tool", "a|scope:b|event:c"),
    )
    |> should.be_ok
  { first.external_id == second.external_id } |> should.be_false
  { first.event_id == second.event_id } |> should.be_false
}

pub fn connector_submission_uses_evidence_audit_and_never_queues_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(started) = event_ingest.start(db_subject)
  let ingest_subject = started.data
  let submitted =
    connector_adapter.submit(
      registry(),
      ingest_subject,
      result_fixture("codex", "codex", "submission-1"),
    )
    |> should.be_ok
  let audit =
    db.list_operational_audit(db_subject, "event", submitted.event_id)
    |> should.be_ok
  list.map(audit, fn(item) { item.action })
  |> should.equal(["evidence.stored"])
  db.claim_attention(db_subject, "codex", "monitor-1", 1000, 2000)
  |> should.equal(Ok(None))
  let assert Ok(pid) = process.subject_owner(ingest_subject)
  process.unlink(pid)
  process.kill(pid)
  process.send(db_subject, db.Shutdown)
}

pub fn write_result_requires_and_retains_explicit_authority_test() {
  let write_registry =
    connector_registry.build(
      [
        connector_registry.ConnectorDescriptor(
          schema_version: 1,
          connector_id: "github",
          display_name: "github",
          source_kind: "connector",
          capabilities: ["resource.write"],
          scopes: ["fixture.records"],
          descriptor_provenance_ref: "descriptor://fixture/github",
          summary_limit: 300,
          value_limit: 1000,
          read_authority_ref: None,
          write_authority_ref: Some("authority://fixture/github/write"),
          policy_boundary_ref: "policy://attention/default",
        ),
      ],
      [
        connector_registry.ConnectorActivation(
          schema_version: 1,
          connector_id: "github",
          state: "enabled",
          configuration_ref: "config://fixture/github",
        ),
      ],
    )
    |> should.be_ok
  let base =
    operating_contracts.ConnectorResult(
      ..result_fixture("github", "connector", "write-1"),
      capability: "resource.write",
      operation: "write",
      content_hash: "pending",
    )
  let without_grant =
    operating_contracts.ConnectorResult(
      ..base,
      content_hash: connector_adapter.content_hash(base),
    )
  connector_adapter.normalize(write_registry, without_grant)
  |> should.equal(Error("connector_authority_required"))

  let granted_base =
    operating_contracts.ConnectorResult(..base, authority_grants: [
      "authority://fixture/github/write",
    ])
  let granted =
    operating_contracts.ConnectorResult(
      ..granted_base,
      content_hash: connector_adapter.content_hash(granted_base),
    )
  let evidence =
    connector_adapter.normalize(write_registry, granted)
    |> should.be_ok
  dict.get(evidence.provenance, "authority_grants")
  |> should.equal(
    Ok(
      operating_contracts.StructuredArray([
        operating_contracts.StructuredString("authority://fixture/github/write"),
      ]),
    ),
  )
}
