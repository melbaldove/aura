import aura/connector_activation
import aura/ctl
import aura/db
import aura/google_execution_fixture
import aura/operating_contracts
import aura/time
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlight

pub fn main() {
  gleeunit.main()
}

fn store_final_authorization(
  subject: process.Subject(db.DbMessage),
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> Result(db.StoredCanaryAuthorization, String) {
  let preparation = preparation_authorization()
  use _ <- result.try(db.create_canary_preparation_authorization(
    subject,
    preparation,
  ))
  use _ <- result.try(google_execution_fixture.seed_authorization_proofs(
    subject,
    preparation,
    authorization,
  ))
  db.create_canary_authorization(subject, authorization)
}

pub fn prepare_then_enable_and_disable_the_exact_authorized_set_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)

  let assert Ok(disabled) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "activation:prepare",
      authorization.authorized_by_ref,
    )
  disabled
  |> list.map(fn(activation) { activation.state })
  |> should.equal(["disabled", "disabled"])

  let assert Ok(enabled) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "activation:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  enabled
  |> list.map(fn(activation) { activation.state })
  |> should.equal(["enabled", "enabled"])

  connector_activation.enable_set(
    subject,
    authorization.authorization_id,
    "activation:enable",
    authorization.authorized_by_ref,
    ["connector.enable"],
  )
  |> should.equal(Ok(enabled))
  connector_activation.enable_set(
    subject,
    authorization.authorization_id,
    "activation:enable",
    authorization.authorized_by_ref,
    ["connector.disable"],
  )
  |> should.equal(Error("idempotency_conflict"))

  let assert Ok(disabling) =
    connector_activation.begin_disable_set(
      subject,
      authorization.authorization_id,
      "activation:disable",
      authorization.rollback_owner_ref,
      ["connector.disable"],
    )
  disabling
  |> list.map(fn(activation) { activation.state })
  |> should.equal(["disabling", "disabling"])
  let assert Ok(disabled) =
    connector_activation.finalize_disable_set(
      subject,
      authorization.authorization_id,
      "activation:disable-finalize",
      authorization.rollback_owner_ref,
    )
  disabled
  |> list.map(fn(activation) { activation.state })
  |> should.equal(["disabled", "disabled"])
  db.list_operational_audit(
    subject,
    "connector_activation",
    "activation:gmail-activation-test",
  )
  |> should.be_ok
  |> list.length
  |> should.equal(4)
}

pub fn control_command_requires_explicit_transcript_free_mutation_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)

  ctl.process_connector_activation_command(
    subject,
    activation_command("inferred")
      |> operating_contracts.encode_command_mutation,
  )
  |> should.equal("ERROR: connector_activation_requires_explicit_command")
  ctl.process_connector_activation_command(
    subject,
    activation_command("explicit")
      |> operating_contracts.encode_command_mutation,
  )
  |> should.equal("OK: connector activation count=2")
  ctl.process_connector_activation_command(
    subject,
    activation_command_with("explicit", "connector_activation.expire")
      |> operating_contracts.encode_command_mutation,
  )
  |> should.equal("ERROR: connector_activation_expire_is_internal")
}

pub fn authorization_create_command_requires_the_approved_canonical_hash_test() {
  let assert Ok(subject) = db.start(":memory:")
  let value = preparation_authorization()
  let payload =
    operating_contracts.encode_canary_preparation_authorization(value)
  let payload_hash = hash_payload(payload)

  ctl.process_preparation_authorization_command(
    subject,
    "create " <> hash("f") <> " " <> payload,
  )
  |> should.equal("ERROR: approved_payload_hash_mismatch")
  db.get_canary_preparation_authorization(subject, value.authorization_id)
  |> should.equal(Ok(option.None))
  ctl.process_preparation_authorization_command(
    subject,
    "create " <> payload_hash <> " " <> payload,
  )
  |> should.equal(
    "OK: preparation_authorization="
    <> value.authorization_id
    <> " payload_hash="
    <> payload_hash,
  )
}

pub fn wrong_enable_authority_keeps_the_set_disabled_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "activation:authority-prepare",
      authorization.authorized_by_ref,
    )

  connector_activation.enable_set(
    subject,
    authorization.authorization_id,
    "activation:authority-enable",
    "operator:wrong-authority",
    ["connector.enable"],
  )
  |> should.equal(Error("invalid_activation_authority"))
  connector_activation.load_effective(
    subject,
    "activation:gmail-activation-test",
    authorization.authorization_id,
  )
  |> should.equal(Ok(option.None))
}

pub fn concurrent_changed_enable_requests_claim_one_idempotency_receipt_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "activation:concurrent-prepare",
      authorization.authorized_by_ref,
    )

  let replies = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(
        replies,
        connector_activation.enable_set(
          subject,
          authorization.authorization_id,
          "activation:concurrent-enable",
          authorization.authorized_by_ref,
          ["connector.enable"],
        ),
      )
    })
  let _ =
    process.spawn(fn() {
      process.send(
        replies,
        connector_activation.enable_set(
          subject,
          authorization.authorization_id,
          "activation:concurrent-enable",
          authorization.authorized_by_ref,
          ["connector.disable", "connector.enable"],
        ),
      )
    })

  let assert Ok(first) = process.receive(replies, 1000)
  let assert Ok(second) = process.receive(replies, 1000)
  [first, second]
  |> list.filter(fn(result) {
    case result {
      Ok(_) -> True
      Error(_) -> False
    }
  })
  |> list.length
  |> should.equal(1)
  [first, second]
  |> list.filter(fn(result) { result == Error("idempotency_conflict") })
  |> list.length
  |> should.equal(1)
  db.list_operational_audit(
    subject,
    "connector_activation",
    "activation:gmail-activation-test",
  )
  |> should.be_ok
  |> list.length
  |> should.equal(2)
}

pub fn replay_returns_the_original_activation_receipt_after_later_transition_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "activation:receipt-prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(enabled) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "activation:receipt-enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(_) =
    connector_activation.begin_disable_set(
      subject,
      authorization.authorization_id,
      "activation:receipt-disable",
      authorization.rollback_owner_ref,
      ["connector.disable"],
    )

  connector_activation.enable_set(
    subject,
    authorization.authorization_id,
    "activation:receipt-enable",
    authorization.authorized_by_ref,
    ["connector.enable"],
  )
  |> should.equal(Ok(enabled))
}

pub fn activation_transition_rolls_back_when_audit_write_fails_test() {
  let path =
    "/tmp/aura-connector-activation-rollback-"
    <> int.to_string(time.now_ms())
    <> ".db"
  let _ = simplifile.delete(path)
  let assert Ok(subject) = db.start(path)
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) = sqlight.exec("DROP TABLE operational_audit", conn)

  connector_activation.prepare_disabled(
    subject,
    authorization.authorization_id,
    "activation:audit-rollback",
    authorization.authorized_by_ref,
  )
  |> should.be_error
  sqlight.query(
    "SELECT COUNT(*) FROM connector_activations WHERE authorization_id = ?",
    on: conn,
    with: [sqlight.text(authorization.authorization_id)],
    expecting: decode.at([0], decode.int),
  )
  |> should.equal(Ok([0]))

  process.send(subject, db.Shutdown)
  let _ = sqlight.close(conn)
  let _ = simplifile.delete(path)
}

pub fn effective_activation_requires_the_exact_authorization_id_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "activation:effective-prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "activation:effective-enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )

  connector_activation.load_effective(
    subject,
    "activation:gmail-activation-test",
    "authorization:other",
  )
  |> should.equal(Ok(option.None))
  connector_activation.load_effective(
    subject,
    "activation:gmail-activation-test",
    authorization.authorization_id,
  )
  |> should.be_ok
  |> should.not_equal(option.None)
}

pub fn effective_activation_uses_aura_time_after_authorization_expiry_test() {
  let path =
    "/tmp/aura-connector-activation-expiry-"
    <> int.to_string(time.now_ms())
    <> ".db"
  let _ = simplifile.delete(path)
  let assert Ok(subject) = db.start(path)
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "activation:expiry-prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "activation:expiry-enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec("DROP TRIGGER canary_authorizations_no_update", conn)
  let expired =
    operating_contracts.CanaryAuthorizationV1(..authorization, ends_at_ms: 1)
  sqlight.query(
    "UPDATE canary_authorizations SET canonical_json = ?, ends_at_ms = 1 WHERE authorization_id = ?",
    on: conn,
    with: [
      sqlight.text(operating_contracts.encode_canary_authorization(expired)),
      sqlight.text(authorization.authorization_id),
    ],
    expecting: decode.success(Nil),
  )
  |> should.be_ok

  connector_activation.load_effective(
    subject,
    "activation:gmail-activation-test",
    authorization.authorization_id,
  )
  |> should.equal(Ok(option.None))

  process.send(subject, db.Shutdown)
  let _ = sqlight.close(conn)
  let _ = simplifile.delete(path)
}

pub fn final_authorization_rechecks_preparation_expiry_test() {
  let path =
    "/tmp/aura-preparation-authorization-expiry-"
    <> int.to_string(time.now_ms())
    <> ".db"
  let _ = simplifile.delete(path)
  let assert Ok(subject) = db.start(path)
  let preparation = preparation_authorization()
  let assert Ok(_) =
    db.create_canary_preparation_authorization(subject, preparation)
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "DROP TRIGGER canary_preparation_authorizations_no_update",
      conn,
    )
  let expired =
    operating_contracts.CanaryPreparationAuthorizationV1(
      ..preparation,
      expires_at_ms: 1,
    )
  sqlight.query(
    "UPDATE canary_preparation_authorizations SET canonical_json = ?, expires_at_ms = 1, created_at_ms = 0 WHERE authorization_id = ?",
    on: conn,
    with: [
      sqlight.text(operating_contracts.encode_canary_preparation_authorization(
        expired,
      )),
      sqlight.text(preparation.authorization_id),
    ],
    expecting: decode.success(Nil),
  )
  |> should.be_ok

  db.create_canary_authorization(subject, final_authorization())
  |> should.equal(Error("preparation_authorization_expired"))
  sqlight.query(
    "SELECT COUNT(*) FROM canary_authorizations",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> should.equal(Ok([0]))

  process.send(subject, db.Shutdown)
  let _ = sqlight.close(conn)
  let _ = simplifile.delete(path)
}

pub fn read_attempt_reservation_is_activation_bound_and_drains_disable_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "attempt:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "attempt:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(attempt) =
    db.reserve_connector_read(
      subject,
      "attempt:gmail-read-1",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      1000,
    )
  attempt.phase |> should.equal("reserved")
  db.begin_connector_read(subject, attempt.attempt_id, "worker:fixture")
  |> should.be_ok
  let assert Ok(_) =
    connector_activation.begin_disable_set(
      subject,
      authorization.authorization_id,
      "attempt:disable",
      authorization.rollback_owner_ref,
      ["connector.disable"],
    )
  db.reserve_connector_read(
    subject,
    "attempt:gmail-read-2",
    "activation:gmail-activation-test",
    authorization.authorization_id,
    "worker:fixture",
    1000,
  )
  |> should.equal(Error("connector_activation_not_effective"))
  db.finish_connector_read(
    subject,
    attempt.attempt_id,
    "worker:fixture",
    "discarded",
    "activation_disabled",
  )
  |> should.be_ok
  connector_activation.finalize_disable_set(
    subject,
    authorization.authorization_id,
    "attempt:disable-finalize",
    authorization.rollback_owner_ref,
  )
  |> should.be_ok
}

pub fn authorized_evidence_completes_or_discards_the_read_attempt_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "evidence:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "evidence:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(first) =
    db.reserve_connector_read(
      subject,
      "attempt:evidence-1",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      1000,
    )
  let assert Ok(_) =
    db.begin_connector_read(subject, first.attempt_id, "worker:fixture")
  db.submit_authorized_connector_evidence(
    subject,
    submission_context(first.attempt_id),
    evidence_envelope(),
    [],
  )
  |> should.be_ok
  let assert Ok(option.Some(stored)) =
    db.get_stored_evidence(subject, "event:attempt-evidence")
  dict.get(stored.envelope.provenance, "activation_id")
  |> should.equal(
    Ok(operating_contracts.StructuredString("activation:gmail-activation-test")),
  )
  dict.get(stored.envelope.provenance, "authorization_id")
  |> should.equal(
    Ok(operating_contracts.StructuredString("authorization:activation-test")),
  )
  let assert Ok(second) =
    db.reserve_connector_read(
      subject,
      "attempt:evidence-2",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      1000,
    )
  let assert Ok(_) =
    db.begin_connector_read(subject, second.attempt_id, "worker:fixture")
  let assert Ok(_) =
    connector_activation.begin_disable_set(
      subject,
      authorization.authorization_id,
      "evidence:disable",
      authorization.rollback_owner_ref,
      ["connector.disable"],
    )
  db.submit_authorized_connector_evidence(
    subject,
    submission_context(second.attempt_id),
    evidence_envelope(),
    [],
  )
  |> should.equal(Ok(option.None))
}

pub fn empty_evidence_batch_advances_checkpoint_and_completes_attempt_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "checkpoint:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "checkpoint:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(attempt) =
    db.reserve_connector_read(
      subject,
      "attempt:checkpoint-1",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      1000,
    )
  let assert Ok(_) =
    db.begin_connector_read(subject, attempt.attempt_id, "worker:fixture")
  db.submit_authorized_connector_evidence_batch_with_checkpoint(
    subject,
    submission_context(attempt.attempt_id),
    [],
    db.GmailHistoryCheckpoint(
      configuration_ref: "configuration:gmail-activation-test",
      activation_id: "activation:gmail-activation-test",
      expected_version: 0,
      history_id: "history:100",
    ),
  )
  |> should.equal(Ok(option.Some([])))
  let assert Ok(option.Some(checkpoint)) =
    db.get_connector_checkpoint(
      subject,
      "configuration:gmail-activation-test",
      "activation:gmail-activation-test",
    )
  checkpoint.cursor_value |> should.equal("history:100")
  checkpoint.version |> should.equal(1)

  let assert Ok(conflict_attempt) =
    db.reserve_connector_read(
      subject,
      "attempt:checkpoint-conflict",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      1000,
    )
  let assert Ok(_) =
    db.begin_connector_read(
      subject,
      conflict_attempt.attempt_id,
      "worker:fixture",
    )
  let conflict_evidence =
    operating_contracts.EvidenceEvent(
      ..evidence_envelope(),
      event_id: "event:checkpoint-rollback",
      external_id: option.Some("resource:checkpoint-rollback"),
      raw_ref: option.Some("opaque://fixture/checkpoint-rollback"),
      content_hash: hash("checkpoint-rollback"),
    )
  db.submit_authorized_connector_evidence_batch_with_checkpoint(
    subject,
    submission_context(conflict_attempt.attempt_id),
    [#(conflict_evidence, [])],
    db.GmailHistoryCheckpoint(
      configuration_ref: "configuration:gmail-activation-test",
      activation_id: "activation:gmail-activation-test",
      expected_version: 0,
      history_id: "history:changed",
    ),
  )
  |> should.equal(Error("connector_checkpoint_version_conflict"))
  db.get_stored_evidence(subject, "event:checkpoint-rollback")
  |> should.equal(Ok(option.None))
  db.finish_connector_read(
    subject,
    conflict_attempt.attempt_id,
    "worker:fixture",
    "failed",
    "checkpoint_version_conflict",
  )
  |> should.be_ok
}

pub fn calendar_checkpoint_due_time_is_derived_by_aura_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "calendar-checkpoint:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "calendar-checkpoint:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(attempt) =
    db.reserve_connector_read(
      subject,
      "attempt:calendar-checkpoint",
      "activation:calendar-activation-test",
      authorization.authorization_id,
      "worker:calendar-checkpoint",
      1000,
    )
  let assert Ok(_) =
    db.begin_connector_read(
      subject,
      attempt.attempt_id,
      "worker:calendar-checkpoint",
    )
  let before = time.now_ms()
  db.submit_authorized_connector_evidence_batch_with_checkpoint(
    subject,
    calendar_submission_context(attempt.attempt_id),
    [],
    db.CalendarPollCheckpoint(
      configuration_ref: "configuration:calendar-activation-test",
      activation_id: "activation:calendar-activation-test",
      expected_version: 0,
      next_due_at_ms: 1,
    ),
  )
  |> should.equal(Ok(option.Some([])))
  let assert Ok(option.Some(checkpoint)) =
    db.get_connector_checkpoint(
      subject,
      "configuration:calendar-activation-test",
      "activation:calendar-activation-test",
    )
  should.be_true(checkpoint.next_due_at_ms >= before + 60_000)
}

pub fn connector_read_renewal_requires_exact_owner_and_version_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "renew:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "renew:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(attempt) =
    db.reserve_connector_read(
      subject,
      "attempt:renew-1",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      1000,
    )
  let assert Ok(renewed) =
    db.renew_connector_read(
      subject,
      attempt.attempt_id,
      "worker:fixture",
      attempt.attempt_version,
      1000,
    )
  renewed.attempt_version |> should.equal(2)
  db.renew_connector_read(
    subject,
    attempt.attempt_id,
    "worker:forged",
    renewed.attempt_version,
    1000,
  )
  |> should.equal(Error("connector_read_lease_conflict"))
  db.renew_connector_read(
    subject,
    attempt.attempt_id,
    "worker:fixture",
    attempt.attempt_version,
    1000,
  )
  |> should.equal(Error("connector_read_lease_conflict"))
}

pub fn connector_read_reservation_rejects_unresolved_attempt_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "single-read:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "single-read:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(first) =
    db.reserve_connector_read(
      subject,
      "attempt:single-read-1",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:single-read-1",
      1000,
    )
  let assert Ok(_) =
    db.begin_connector_read(subject, first.attempt_id, "worker:single-read-1")

  db.reserve_connector_read(
    subject,
    "attempt:single-read-2",
    "activation:gmail-activation-test",
    authorization.authorization_id,
    "worker:single-read-2",
    1000,
  )
  |> should.equal(Error("connector_read_attempt_active"))

  let assert Ok(_) =
    db.finish_connector_read(
      subject,
      first.attempt_id,
      "worker:single-read-1",
      "failed",
      "provider_failed",
    )
  db.reserve_connector_read(
    subject,
    "attempt:single-read-3",
    "activation:gmail-activation-test",
    authorization.authorization_id,
    "worker:single-read-3",
    1000,
  )
  |> should.be_ok
}

pub fn provider_failure_atomically_finishes_attempt_and_records_retry_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "failure:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "failure:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(attempt) =
    db.reserve_connector_read(
      subject,
      "attempt:provider-failure",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      1000,
    )
  let assert Ok(_) =
    db.begin_connector_read(subject, attempt.attempt_id, "worker:fixture")
  let assert Ok(finished) =
    db.record_connector_read_failure(
      subject,
      submission_context(attempt.attempt_id),
      time.now_ms() + 60_000,
      "external_read_unknown",
      True,
    )
  finished.phase |> should.equal("interrupted")
  let assert Ok(option.Some(checkpoint)) =
    db.get_connector_checkpoint(
      subject,
      "configuration:gmail-activation-test",
      "activation:gmail-activation-test",
    )
  checkpoint.retry_count |> should.equal(1)
  db.finish_connector_read(
    subject,
    attempt.attempt_id,
    "worker:fixture",
    "completed",
    "",
  )
  |> should.equal(Error("connector_read_not_active"))
}

pub fn expired_lease_cannot_commit_late_evidence_or_checkpoint_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "late:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "late:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(attempt) =
    db.reserve_connector_read(
      subject,
      "attempt:late-evidence",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      20,
    )
  let assert Ok(_) =
    db.begin_connector_read(subject, attempt.attempt_id, "worker:fixture")
  process.sleep(30)
  db.submit_authorized_connector_evidence_batch_with_checkpoint(
    subject,
    submission_context(attempt.attempt_id),
    [#(evidence_envelope(), [])],
    db.GmailHistoryCheckpoint(
      configuration_ref: "configuration:gmail-activation-test",
      activation_id: "activation:gmail-activation-test",
      expected_version: 0,
      history_id: "history:late",
    ),
  )
  |> should.equal(Ok(option.None))
  db.get_stored_evidence(subject, "event:attempt-evidence")
  |> should.equal(Ok(option.None))
  db.get_connector_checkpoint(
    subject,
    "configuration:gmail-activation-test",
    "activation:gmail-activation-test",
  )
  |> should.equal(Ok(option.None))
}

pub fn lease_renewal_does_not_move_the_hard_attempt_deadline_test() {
  let path =
    "/tmp/aura-hard-read-deadline-" <> int.to_string(time.now_ms()) <> ".db"
  let _ = simplifile.delete(path)
  let assert Ok(subject) = db.start(path)
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "hard:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "hard:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(attempt) =
    db.reserve_connector_read(
      subject,
      "attempt:hard-deadline",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      1000,
    )
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok([hard_before]) =
    sqlight.query(
      "SELECT hard_expires_at_ms FROM connector_read_attempts WHERE attempt_id = 'attempt:hard-deadline'",
      on: conn,
      with: [],
      expecting: decode.at([0], decode.int),
    )
  let assert Ok(_) =
    db.renew_connector_read(
      subject,
      attempt.attempt_id,
      "worker:fixture",
      attempt.attempt_version,
      300_000,
    )
  sqlight.query(
    "SELECT hard_expires_at_ms FROM connector_read_attempts WHERE attempt_id = 'attempt:hard-deadline'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> should.equal(Ok([hard_before]))
  let _ = sqlight.close(conn)
  let _ = simplifile.delete(path)
}

pub fn missing_audit_table_rolls_back_evidence_checkpoint_and_attempt_test() {
  let path =
    "/tmp/aura-checkpoint-audit-" <> int.to_string(time.now_ms()) <> ".db"
  let _ = simplifile.delete(path)
  let assert Ok(subject) = db.start(path)
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "audit:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "audit:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(attempt) =
    db.reserve_connector_read(
      subject,
      "attempt:audit-rollback",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      1000,
    )
  let assert Ok(_) =
    db.begin_connector_read(subject, attempt.attempt_id, "worker:fixture")
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) = sqlight.exec("DROP TABLE operational_audit", conn)
  db.submit_authorized_connector_evidence_batch_with_checkpoint(
    subject,
    submission_context(attempt.attempt_id),
    [#(evidence_envelope(), [])],
    db.GmailHistoryCheckpoint(
      configuration_ref: "configuration:gmail-activation-test",
      activation_id: "activation:gmail-activation-test",
      expected_version: 0,
      history_id: "history:audit-rollback",
    ),
  )
  |> should.be_error
  db.get_stored_evidence(subject, "event:attempt-evidence")
  |> should.equal(Ok(option.None))
  db.get_connector_checkpoint(
    subject,
    "configuration:gmail-activation-test",
    "activation:gmail-activation-test",
  )
  |> should.equal(Ok(option.None))
  let _ = sqlight.close(conn)
  let _ = simplifile.delete(path)
}

pub fn forged_stale_and_mismatched_submission_contexts_are_rejected_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "context:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "context:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(attempt) =
    db.reserve_connector_read(
      subject,
      "attempt:context",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:fixture",
      1000,
    )
  db.begin_connector_read(subject, attempt.attempt_id, "worker:fixture")
  |> should.be_ok
  db.submit_authorized_connector_evidence(
    subject,
    operating_contracts.ConnectorSubmissionContext(
      ..submission_context(attempt.attempt_id),
      activation_version: 1,
    ),
    evidence_envelope(),
    [],
  )
  |> should.equal(Error("connector_submission_context_mismatch"))
  db.submit_authorized_connector_evidence(
    subject,
    operating_contracts.ConnectorSubmissionContext(
      ..submission_context(attempt.attempt_id),
      account_fingerprint: hash("f"),
    ),
    evidence_envelope(),
    [],
  )
  |> should.equal(Error("connector_submission_context_mismatch"))
  db.submit_authorized_connector_evidence(
    subject,
    operating_contracts.ConnectorSubmissionContext(
      ..submission_context(attempt.attempt_id),
      authorization_id: "authorization:forged",
    ),
    evidence_envelope(),
    [],
  )
  |> should.equal(Error("connector_submission_context_mismatch"))
  db.submit_authorized_connector_evidence(
    subject,
    submission_context(attempt.attempt_id),
    evidence_envelope(),
    [],
  )
  |> should.be_ok
}

pub fn expired_read_attempts_recover_without_evidence_test() {
  let assert Ok(subject) = db.start(":memory:")
  let authorization = final_authorization()
  let assert Ok(_) = store_final_authorization(subject, authorization)
  let assert Ok(_) =
    connector_activation.prepare_disabled(
      subject,
      authorization.authorization_id,
      "recovery:prepare",
      authorization.authorized_by_ref,
    )
  let assert Ok(_) =
    connector_activation.enable_set(
      subject,
      authorization.authorization_id,
      "recovery:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
  let assert Ok(reserved) =
    db.reserve_connector_read(
      subject,
      "attempt:recovery-reserved",
      "activation:gmail-activation-test",
      authorization.authorization_id,
      "worker:recovery",
      50,
    )
  let assert Ok(started) =
    db.reserve_connector_read(
      subject,
      "attempt:recovery-started",
      "activation:calendar-activation-test",
      authorization.authorization_id,
      "worker:recovery",
      50,
    )
  db.begin_connector_read(subject, started.attempt_id, "worker:recovery")
  |> should.be_ok
  process.sleep(60)
  db.recover_expired_connector_reads(subject)
  |> should.equal(Ok(2))
  db.finish_connector_read(
    subject,
    reserved.attempt_id,
    "worker:recovery",
    "completed",
    "",
  )
  |> should.equal(Error("connector_read_not_active"))
  db.finish_connector_read(
    subject,
    started.attempt_id,
    "worker:recovery",
    "completed",
    "",
  )
  |> should.equal(Error("connector_read_not_active"))
  let started_audit =
    db.list_operational_audit(
      subject,
      "connector_read_attempt",
      started.attempt_id,
    )
    |> should.be_ok
  started_audit
  |> list.map(fn(record) { record.action })
  |> should.equal([
    "connector.read.reserved",
    "connector.read.request_started",
    "connector.read.interrupted",
  ])
}

fn evidence_envelope() -> operating_contracts.EvidenceEvent {
  operating_contracts.EvidenceEvent(
    schema_version: 1,
    event_id: "event:attempt-evidence",
    source: "connector:gmail",
    source_kind: "connector",
    event_type: "resource.changed",
    external_id: option.Some("resource:attempt-evidence"),
    resource: dict.from_list([
      #("kind", operating_contracts.StructuredString("external_resource")),
      #("id", operating_contracts.StructuredString("resource-attempt")),
    ]),
    observed_at: 1,
    summary: "Compact fixture evidence.",
    normalized_data: dict.new(),
    raw_ref: option.Some("opaque://fixture/attempt"),
    content_hash: hash("e"),
    provenance: dict.from_list([
      #("capability", operating_contracts.StructuredString("read")),
      #(
        "scope",
        operating_contracts.StructuredString(
          "https://www.googleapis.com/auth/gmail.readonly",
        ),
      ),
    ]),
    candidate_domain_refs: [],
    candidate_concern_refs: [],
    verification_status: "verified",
  )
}

fn submission_context(
  attempt_id: String,
) -> operating_contracts.ConnectorSubmissionContext {
  operating_contracts.ConnectorSubmissionContext(
    activation_id: "activation:gmail-activation-test",
    activation_version: 2,
    authorization_id: "authorization:activation-test",
    attempt_id:,
    worker_id: "worker:fixture",
    connector_id: "gmail",
    capability: "read",
    oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
    configuration_hash: hash("d"),
    account_fingerprint: hash("e"),
    domain_id: "domain:activation-test",
    concern_id: "concern:domain:activation-test:awareness",
  )
}

fn calendar_submission_context(
  attempt_id: String,
) -> operating_contracts.ConnectorSubmissionContext {
  operating_contracts.ConnectorSubmissionContext(
    activation_id: "activation:calendar-activation-test",
    activation_version: 2,
    authorization_id: "authorization:activation-test",
    attempt_id:,
    worker_id: "worker:calendar-checkpoint",
    connector_id: "calendar",
    capability: "read",
    oauth_scope: "https://www.googleapis.com/auth/calendar.readonly",
    configuration_hash: hash("d"),
    account_fingerprint: hash("e"),
    domain_id: "domain:activation-test",
    concern_id: "concern:domain:activation-test:awareness",
  )
}

fn activation_command(
  creation_basis: String,
) -> operating_contracts.CommandMutation {
  activation_command_with(creation_basis, "connector_activation.prepare")
}

fn activation_command_with(
  creation_basis: String,
  intent_kind: String,
) -> operating_contracts.CommandMutation {
  operating_contracts.CommandMutation(
    schema_version: 1,
    command_id: "command:activation-prepare",
    idempotency_key: "activation:command-prepare",
    origin: "codex_voice",
    codex_task_ref: option.None,
    codex_conversation_ref: option.None,
    codex_turn_ref: option.None,
    intent_kind:,
    structured_payload: dict.from_list([
      #(
        "authorization_id",
        operating_contracts.StructuredString("authorization:activation-test"),
      ),
      #(
        "actor_ref",
        operating_contracts.StructuredString("operator:activation-reviewer"),
      ),
    ]),
    creation_basis:,
    issued_at: 0,
  )
}

fn preparation_authorization() -> operating_contracts.CanaryPreparationAuthorizationV1 {
  operating_contracts.CanaryPreparationAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:preparation-activation-test",
    canary_id: "canary:activation-test",
    oauth_client_ref: "oauth-client:activation-test",
    oauth_client_hash: hash("a"),
    connectors: [
      operating_contracts.PreparationConnectorV1(
        connector_id: "calendar",
        configuration_ref: "configuration:calendar-activation-test",
        oauth_scope: "https://www.googleapis.com/auth/calendar.readonly",
        identity_endpoint_id: "calendar.calendars.get",
      ),
      operating_contracts.PreparationConnectorV1(
        connector_id: "gmail",
        configuration_ref: "configuration:gmail-activation-test",
        oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
        identity_endpoint_id: "gmail.users.getProfile",
      ),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: 9_999_999_999_999,
    authorized_by_ref: "operator:activation-reviewer",
  )
}

fn final_authorization() -> operating_contracts.CanaryAuthorizationV1 {
  operating_contracts.CanaryAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:activation-test",
    preparation_authorization_id: "authorization:preparation-activation-test",
    canary_id: "canary:activation-test",
    domain_id: "domain:activation-test",
    concern_id: "concern:domain:activation-test:awareness",
    policy_refs: ["policy:activation-test"],
    connectors: [
      connector("calendar", "activation:calendar-activation-test"),
      connector("gmail", "activation:gmail-activation-test"),
    ],
    activation_grants: ["connector.disable", "connector.enable"],
    monitor_id: "monitor:activation-test",
    monitor_capability_hash: hash("b"),
    monitor_runtime_ref: "runtime:activation-test",
    monitor_prompt_hash: hash("c"),
    monitor_interval_ms: 60_000,
    monitor_grants: ["attention.claim", "attention.read"],
    attention_owner: "codex",
    attention_target: "codex_monitor",
    discord_delivery_allowed: False,
    starts_at_ms: 0,
    ends_at_ms: 9_999_999_999_999,
    metric_ids: ["metric:activation-test"],
    metric_review_owner_ref: "operator:metrics-reviewer",
    authorized_by_ref: "operator:activation-reviewer",
    rollback_owner_ref: "operator:activation-rollback",
  )
}

fn connector(
  connector_id: String,
  activation_id: String,
) -> operating_contracts.AuthorizedConnectorV1 {
  operating_contracts.AuthorizedConnectorV1(
    connector_id:,
    activation_id:,
    configuration_ref: "configuration:" <> connector_id <> "-activation-test",
    configuration_hash: hash("d"),
    account_fingerprint: hash("e"),
    oauth_proof_ref: "proof:" <> connector_id <> "-oauth",
    identity_proof_ref: "proof:" <> connector_id <> "-identity",
    oauth_scope: "https://www.googleapis.com/auth/"
      <> connector_id
      <> ".readonly",
    capability: "read",
    retention_policy_ref: "retention:" <> connector_id <> "-compact",
    poll_interval_ms: 60_000,
    max_pages_per_poll: 1,
    max_items_per_poll: 10,
    max_response_bytes: 4096,
  )
}

fn hash(character: String) -> String {
  string.repeat(character, 64)
}

fn hash_payload(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
}
