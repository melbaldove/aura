import aura/acp/flare_manager
import gleeunit/should

// ---------------------------------------------------------------------------
// status_to_string / status_from_string roundtrip
// ---------------------------------------------------------------------------

pub fn status_active_roundtrip_test() {
  flare_manager.Active
  |> flare_manager.status_to_string
  |> flare_manager.status_from_string
  |> should.equal(flare_manager.Active)
}

pub fn status_parked_roundtrip_test() {
  flare_manager.Parked
  |> flare_manager.status_to_string
  |> flare_manager.status_from_string
  |> should.equal(flare_manager.Parked)
}

pub fn status_archived_roundtrip_test() {
  flare_manager.Archived
  |> flare_manager.status_to_string
  |> flare_manager.status_from_string
  |> should.equal(flare_manager.Archived)
}

pub fn status_failed_with_reason_roundtrip_test() {
  flare_manager.Failed("timed_out")
  |> flare_manager.status_to_string
  |> flare_manager.status_from_string
  |> should.equal(flare_manager.Failed("timed_out"))
}

pub fn status_failed_with_complex_reason_roundtrip_test() {
  flare_manager.Failed("killed:by:user")
  |> flare_manager.status_to_string
  |> flare_manager.status_from_string
  |> should.equal(flare_manager.Failed("killed:by:user"))
}

// ---------------------------------------------------------------------------
// status_to_string output
// ---------------------------------------------------------------------------

pub fn status_to_string_active_test() {
  flare_manager.status_to_string(flare_manager.Active)
  |> should.equal("active")
}

pub fn status_to_string_parked_test() {
  flare_manager.status_to_string(flare_manager.Parked)
  |> should.equal("parked")
}

pub fn status_to_string_archived_test() {
  flare_manager.status_to_string(flare_manager.Archived)
  |> should.equal("archived")
}

pub fn status_to_string_failed_test() {
  flare_manager.status_to_string(flare_manager.Failed("oops"))
  |> should.equal("failed:oops")
}

// ---------------------------------------------------------------------------
// status_from_string edge cases
// ---------------------------------------------------------------------------

pub fn status_from_string_active_test() {
  flare_manager.status_from_string("active")
  |> should.equal(flare_manager.Active)
}

pub fn status_from_string_parked_test() {
  flare_manager.status_from_string("parked")
  |> should.equal(flare_manager.Parked)
}

pub fn status_from_string_archived_test() {
  flare_manager.status_from_string("archived")
  |> should.equal(flare_manager.Archived)
}

pub fn status_from_string_failed_with_reason_test() {
  flare_manager.status_from_string("failed:connection refused")
  |> should.equal(flare_manager.Failed("connection refused"))
}

pub fn status_from_string_plain_failed_test() {
  // "failed" without a colon should be treated as Failed with "failed" as reason
  flare_manager.status_from_string("failed")
  |> should.equal(flare_manager.Failed("failed"))
}

pub fn status_from_string_unknown_string_test() {
  // Unknown strings become Failed with the full string as reason
  flare_manager.status_from_string("something_weird")
  |> should.equal(flare_manager.Failed("something_weird"))
}

pub fn status_from_string_empty_failed_reason_test() {
  // "failed:" with empty reason
  flare_manager.status_from_string("failed:")
  |> should.equal(flare_manager.Failed(""))
}
