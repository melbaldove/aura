import aura/operational_audit
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn audit_contract_round_trips_test() {
  let value =
    operational_audit.Record(
      schema_version: 1,
      audit_id: "audit-1",
      record_type: "state_transition",
      actor: "aura",
      source: "event_ingest",
      action: "event.inserted",
      target_type: "event",
      target_id: "event-1",
      before_version: None,
      after_version: Some(1),
      idempotency_key: None,
      evidence_refs: ["event-1"],
      proof_refs: [],
      authority_ref: None,
      result: "succeeded",
      error_code: None,
      occurred_at: 100,
    )

  value
  |> operational_audit.encode
  |> operational_audit.decode
  |> should.equal(Ok(value))
}
