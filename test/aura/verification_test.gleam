import aura/verification
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn verification_contract_round_trips_test() {
  let value =
    verification.Record(
      schema_version: 1,
      verification_id: "verification-1",
      target_type: "flare",
      target_id: "flare-1",
      requirement: "All checks pass.",
      method: "test suite",
      result: "pass",
      evidence_refs: ["proof-1"],
      verifier: "codex",
      verified_at: 100,
    )

  value
  |> verification.encode
  |> verification.decode
  |> should.equal(Ok(value))
}
