import aura/attention_queue
import aura/cognitive_decision
import aura/db
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlight

pub fn main() {
  gleeunit.main()
}

fn decision(event_id: String) -> cognitive_decision.DecisionEnvelope {
  cognitive_decision.DecisionEnvelope(
    event_id:,
    concern_refs: ["concern:delivery"],
    summary: "A delivery condition needs attention.",
    citations: ["evidence:" <> event_id, "policy:attention"],
    attention: cognitive_decision.AttentionDecision(
      action: "surface_now",
      rationale: "The deferral cost is high.",
      why_now: "The condition is active.",
      deferral_cost: "A delay can increase risk.",
      why_not_digest: "The digest window is too late.",
    ),
    work: cognitive_decision.WorkDecision(
      action: "none",
      target: "",
      proof_required: "",
    ),
    authority: cognitive_decision.AuthorityDecision(
      required: "human_judgment",
      reason: "The user owns the decision.",
    ),
    delivery: cognitive_decision.DeliveryDecision(
      target: "domain:delivery",
      rationale: "Use the selected domain target.",
    ),
    gaps: [],
    proposed_patches: [],
  )
}

fn request(event_id: String, now: Int) -> attention_queue.EnqueueRequest {
  attention_queue.from_decision(decision(event_id), now)
  |> should.be_ok
}

pub fn duplicate_enqueue_returns_one_canonical_item_test() {
  let assert Ok(subject) = db.start(":memory:")
  let input = request("event-1", 100)
  let first = db.enqueue_attention(subject, input) |> should.be_ok
  let second = db.enqueue_attention(subject, input) |> should.be_ok

  second |> should.equal(first)
  db.list_attention(subject, "discord_compat", "pending")
  |> should.be_ok
  |> list.length
  |> should.equal(1)
  db.list_operational_audit(subject, "attention_queue", first.queue_id)
  |> should.be_ok
  |> list.length
  |> should.equal(1)
}

pub fn changed_payload_for_delivery_key_conflicts_test() {
  let assert Ok(subject) = db.start(":memory:")
  let input = request("event-2", 100)
  db.enqueue_attention(subject, input) |> should.be_ok

  db.enqueue_attention(
    subject,
    attention_queue.EnqueueRequest(..input, summary: "Changed summary."),
  )
  |> should.be_error
  |> string.contains("idempotency_conflict")
  |> should.be_true
}

pub fn non_immediate_policy_decision_cannot_enter_queue_test() {
  attention_queue.from_decision(
    cognitive_decision.DecisionEnvelope(
      ..decision("event-record"),
      attention: cognitive_decision.AttentionDecision(
        action: "record",
        rationale: "Record only.",
        why_now: "",
        deferral_cost: "",
        why_not_digest: "",
      ),
    ),
    100,
  )
  |> should.be_error
}

pub fn only_one_worker_claims_pending_item_test() {
  let assert Ok(subject) = db.start(":memory:")
  db.enqueue_attention(subject, request("event-3", 100)) |> should.be_ok

  let assert Ok(Some(claim)) =
    db.claim_attention(subject, "discord_compat", "worker-1", 1000, 101)
  claim.item.lease_owner |> should.equal(Some("worker-1"))
  db.claim_attention(subject, "discord_compat", "worker-2", 1000, 101)
  |> should.equal(Ok(None))
}

pub fn concurrent_workers_get_one_claim_test() {
  let assert Ok(subject) = db.start(":memory:")
  db.enqueue_attention(subject, request("event-concurrent", 100))
  |> should.be_ok
  let replies = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(
        replies,
        db.claim_attention(subject, "discord_compat", "worker-a", 1000, 101),
      )
    })
  let _ =
    process.spawn(fn() {
      process.send(
        replies,
        db.claim_attention(subject, "discord_compat", "worker-b", 1000, 101),
      )
    })
  let assert Ok(first) = process.receive(replies, 1000)
  let assert Ok(second) = process.receive(replies, 1000)
  [first, second]
  |> list.filter(fn(result) {
    case result {
      Ok(Some(_)) -> True
      _ -> False
    }
  })
  |> list.length
  |> should.equal(1)
}

pub fn expired_pre_intent_claim_returns_to_pending_test() {
  let assert Ok(subject) = db.start(":memory:")
  db.enqueue_attention(subject, request("event-4", 100)) |> should.be_ok
  let assert Ok(Some(claim)) =
    db.claim_attention(subject, "discord_compat", "worker-1", 10, 101)

  db.recover_attention(subject, "discord_compat", 112)
  |> should.equal(Ok(attention_queue.RecoverySummary(requeued: 1, unknown: 0)))
  let assert Ok(Some(_)) =
    db.claim_attention(subject, "discord_compat", "worker-2", 10, 113)
  db.list_attention_attempts(subject, claim.item.queue_id)
  |> should.be_ok
  |> list.map(fn(attempt) { attempt.phase })
  |> should.equal(["failed", "claimed"])
}

pub fn expired_post_intent_claim_is_effect_unknown_test() {
  let assert Ok(subject) = db.start(":memory:")
  db.enqueue_attention(subject, request("event-5", 100)) |> should.be_ok
  let assert Ok(Some(claim)) =
    db.claim_attention(subject, "discord_compat", "worker-1", 10, 101)
  db.begin_attention_delivery(subject, claim.lease_token, 102) |> should.be_ok

  db.recover_attention(subject, "discord_compat", 112)
  |> should.equal(Ok(attention_queue.RecoverySummary(requeued: 0, unknown: 1)))
  let item = db.get_attention(subject, claim.item.queue_id) |> should.be_ok
  item.state |> should.equal("dead_letter")
  db.claim_attention(subject, "discord_compat", "worker-2", 10, 113)
  |> should.equal(Ok(None))
}

pub fn lease_renewal_and_reschedule_use_owned_attempt_test() {
  let assert Ok(subject) = db.start(":memory:")
  let queued =
    db.enqueue_attention(subject, request("event-lease", 100)) |> should.be_ok
  let assert Ok(Some(first_claim)) =
    db.claim_attention(subject, "discord_compat", "worker-1", 10, 101)
  db.renew_attention_lease(subject, first_claim.lease_token, 100, 105)
  |> should.be_ok
  db.recover_attention(subject, "discord_compat", 112)
  |> should.equal(Ok(attention_queue.RecoverySummary(requeued: 0, unknown: 0)))
  db.reschedule_attention(
    subject,
    first_claim.lease_token,
    "target unavailable",
    200,
    113,
  )
  |> should.be_ok
  db.get_attention(subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("deferred")
  db.claim_attention(subject, "discord_compat", "worker-2", 10, 199)
  |> should.equal(Ok(None))
  let assert Ok(Some(_)) =
    db.claim_attention(subject, "discord_compat", "worker-2", 10, 200)
  db.list_operational_audit(subject, "attention_queue", queued.queue_id)
  |> should.be_ok
  |> list.map(fn(record) { record.action })
  |> string.join(",")
  |> string.contains("attention.rescheduled")
  |> should.be_true
}

pub fn due_pending_item_expires_with_audit_test() {
  let assert Ok(subject) = db.start(":memory:")
  let input = request("event-expire", 100)
  let queued =
    db.enqueue_attention(
      subject,
      attention_queue.EnqueueRequest(..input, expires_at: Some(110)),
    )
    |> should.be_ok
  db.expire_attention(subject, "discord_compat", 109) |> should.equal(Ok(0))
  db.expire_attention(subject, "discord_compat", 110) |> should.equal(Ok(1))
  db.get_attention(subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("expired")
  db.list_operational_audit(subject, "attention_queue", queued.queue_id)
  |> should.be_ok
  |> list.map(fn(record) { record.action })
  |> should.equal(["attention.enqueued", "attention.expired"])
}

pub fn complete_and_acknowledge_are_atomic_with_audit_and_history_test() {
  let assert Ok(subject) = db.start(":memory:")
  let queued =
    db.enqueue_attention(subject, request("event-6", 100)) |> should.be_ok
  let assert Ok(Some(claim)) =
    db.claim_attention(subject, "discord_compat", "worker-1", 1000, 101)
  db.begin_attention_delivery(subject, claim.lease_token, 102) |> should.be_ok
  db.complete_attention_delivery(
    subject,
    claim.lease_token,
    "channel-1",
    "Visible content.",
    ["message-1"],
    103,
  )
  |> should.be_ok
  db.acknowledge_attention(subject, queued.queue_id, "discord:user", 104)
  |> should.be_ok

  let item = db.get_attention(subject, queued.queue_id) |> should.be_ok
  item.state |> should.equal("acknowledged")
  let conversation =
    db.resolve_conversation(subject, "discord", "channel-1", 104)
    |> should.be_ok
  db.load_messages(subject, conversation, 10)
  |> should.be_ok
  |> list.map(fn(message) { message.content })
  |> should.equal(["Visible content."])
  db.list_operational_audit(subject, "attention_queue", queued.queue_id)
  |> should.be_ok
  |> list.map(fn(record) { record.action })
  |> string.join(",")
  |> fn(actions) {
    actions |> string.contains("attention.delivered") |> should.be_true
    actions |> string.contains("attention.acknowledged") |> should.be_true
  }
}

pub fn partial_effect_persists_known_visible_prefix_test() {
  let assert Ok(subject) = db.start(":memory:")
  let queued =
    db.enqueue_attention(subject, request("event-7", 100)) |> should.be_ok
  let assert Ok(Some(claim)) =
    db.claim_attention(subject, "discord_compat", "worker-1", 1000, 101)
  db.begin_attention_delivery(subject, claim.lease_token, 102) |> should.be_ok
  db.mark_attention_effect_unknown(
    subject,
    claim.lease_token,
    "channel-1",
    "First visible chunk.",
    ["message-1"],
    "connection lost",
    103,
  )
  |> should.be_ok

  db.get_attention(subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("dead_letter")
  let conversation =
    db.resolve_conversation(subject, "discord", "channel-1", 104)
    |> should.be_ok
  db.load_messages(subject, conversation, 10)
  |> should.be_ok
  |> list.map(fn(message) { message.content })
  |> should.equal(["First visible chunk."])
}

pub fn enqueue_rolls_back_when_audit_write_fails_test() {
  let path = "/tmp/aura-attention-enqueue-rollback.db"
  let _ = simplifile.delete(path)
  let assert Ok(subject) = db.start(path)
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) = sqlight.exec("DROP TABLE operational_audit", conn)

  db.enqueue_attention(subject, request("event-audit-fail", 100))
  |> should.be_error
  sqlight.query(
    "SELECT COUNT(*) FROM attention_queue WHERE queue_id = 'attention:event-audit-fail'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> should.equal(Ok([0]))
  process.send(subject, db.Shutdown)
  let _ = sqlight.close(conn)
  let _ = simplifile.delete(path)
}

pub fn delivery_outcome_rolls_back_when_audit_write_fails_test() {
  let path = "/tmp/aura-attention-outcome-rollback.db"
  let _ = simplifile.delete(path)
  let assert Ok(subject) = db.start(path)
  let queued =
    db.enqueue_attention(subject, request("event-outcome-audit-fail", 100))
    |> should.be_ok
  let assert Ok(Some(claim)) =
    db.claim_attention(subject, "discord_compat", "worker", 1000, 101)
  db.begin_attention_delivery(subject, claim.lease_token, 102) |> should.be_ok
  let assert Ok(conn) = sqlight.open(path)
  let assert Ok(_) = sqlight.exec("DROP TABLE operational_audit", conn)

  db.complete_attention_delivery(
    subject,
    claim.lease_token,
    "channel",
    "Visible content.",
    ["message-1"],
    103,
  )
  |> should.be_error
  let unchanged = db.get_attention(subject, queued.queue_id) |> should.be_ok
  unchanged.state |> should.equal("leased")
  db.list_attention_attempts(subject, queued.queue_id)
  |> should.be_ok
  |> list.map(fn(attempt) { attempt.phase })
  |> should.equal(["intent"])
  sqlight.query(
    "SELECT COUNT(*) FROM messages WHERE content = 'Visible content.'",
    on: conn,
    with: [],
    expecting: decode.at([0], decode.int),
  )
  |> should.equal(Ok([0]))
  process.send(subject, db.Shutdown)
  let _ = sqlight.close(conn)
  let _ = simplifile.delete(path)
}
