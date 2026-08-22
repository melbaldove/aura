import aura/attention_queue
import aura/cognitive_decision
import aura/cognitive_delivery
import aura/db
import aura/db_schema
import aura/discord/message as discord_message
import aura/test_helpers
import aura/transport.{Transport}
import aura/xdg
import fakes/fake_discord
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import sqlight

pub fn main() {
  gleeunit.main()
}

fn temp_paths(label: String) -> #(String, xdg.Paths) {
  let base = "/tmp/aura-" <> label <> "-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  #(base, xdg.resolve_with_home(base))
}

fn targets() -> List(cognitive_delivery.DeliveryTarget) {
  [
    cognitive_delivery.default_target("aura-channel"),
    cognitive_delivery.domain_target("cm2", "cm2-channel"),
  ]
}

fn decision(
  event_id: String,
  attention_action: String,
  target: String,
) -> cognitive_decision.DecisionEnvelope {
  cognitive_decision.DecisionEnvelope(
    event_id: event_id,
    concern_refs: [],
    summary: "Checkout rollback needs attention.",
    citations: ["evidence:e1", "policy:attention.md"],
    attention: cognitive_decision.AttentionDecision(
      action: attention_action,
      rationale: "This is the right attention level.",
      why_now: "The relevant condition is active now.",
      deferral_cost: "Delay could cost user time or risk.",
      why_not_digest: "Digest would be too late.",
    ),
    work: cognitive_decision.WorkDecision(
      action: "prepare",
      target: "checkout context",
      proof_required: "context is summarized",
    ),
    authority: cognitive_decision.AuthorityDecision(
      required: "human_judgment",
      reason: "The user owns the risk tradeoff.",
    ),
    delivery: cognitive_decision.DeliveryDecision(
      target: target,
      rationale: "Route to the selected validated target.",
    ),
    gaps: ["Need user judgment."],
    proposed_patches: [],
  )
}

fn record_decision(event_id: String) -> cognitive_decision.DecisionEnvelope {
  cognitive_decision.DecisionEnvelope(
    ..decision(event_id, "record", "none"),
    attention: cognitive_decision.AttentionDecision(
      action: "record",
      rationale: "Routine update should be recorded only.",
      why_now: "",
      deferral_cost: "",
      why_not_digest: "",
    ),
    work: cognitive_decision.WorkDecision(
      action: "none",
      target: "",
      proof_required: "",
    ),
    authority: cognitive_decision.AuthorityDecision(
      required: "none",
      reason: "",
    ),
  )
}

fn digest_decision(event_id: String) -> cognitive_decision.DecisionEnvelope {
  cognitive_decision.DecisionEnvelope(
    ..decision(event_id, "digest", "default"),
    attention: cognitive_decision.AttentionDecision(
      action: "digest",
      rationale: "Useful but not urgent.",
      why_now: "",
      deferral_cost: "",
      why_not_digest: "",
    ),
    authority: cognitive_decision.AuthorityDecision(
      required: "none",
      reason: "",
    ),
  )
}

fn start_delivery(
  paths: xdg.Paths,
) -> #(
  fake_discord.FakeDiscord,
  process.Subject(cognitive_delivery.Message),
  process.Subject(cognitive_delivery.Report),
) {
  let #(fake, discord) = fake_discord.new()
  let reports = process.new_subject()
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(started) =
    cognitive_delivery.start_with_history(
      paths,
      discord,
      targets(),
      [],
      db_subject,
      Some(reports),
    )
  #(fake, started.data, reports)
}

fn start_delivery_with_history(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
) -> #(
  fake_discord.FakeDiscord,
  process.Subject(cognitive_delivery.Message),
  process.Subject(cognitive_delivery.Report),
) {
  let #(fake, discord) = fake_discord.new()
  let reports = process.new_subject()
  let assert Ok(started) =
    cognitive_delivery.start_with_history(
      paths,
      discord,
      targets(),
      [],
      db_subject,
      Some(reports),
    )
  #(fake, started.data, reports)
}

fn failing_discord(error: String) {
  Transport(
    send_message: fn(_, _) { Error(error) },
    edit_message: fn(_, _, _) { Ok(Nil) },
    trigger_typing: fn(_) { Ok(Nil) },
    get_channel_parent: fn(_) { Ok("") },
    send_message_with_attachment: fn(_, _, _) { Error(error) },
    create_thread_from_message: fn(_, _, _) { Error(error) },
  )
}

type ScriptedSend {
  Send(reply_to: process.Subject(Result(String, String)))
}

fn partial_failure_discord() {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(count, message) {
      let Send(reply_to:) = message
      case count {
        0 -> process.send(reply_to, Ok("message-1"))
        _ -> process.send(reply_to, Error("connection lost"))
      }
      actor.continue(count + 1)
    })
    |> actor.start
  Transport(
    send_message: fn(_, _) {
      process.call(started.data, 1000, fn(reply_to) { Send(reply_to:) })
    },
    edit_message: fn(_, _, _) { Ok(Nil) },
    trigger_typing: fn(_) { Ok(Nil) },
    get_channel_parent: fn(_) { Ok("") },
    send_message_with_attachment: fn(_, _, _) { Error("not used") },
    create_thread_from_message: fn(_, _, _) { Error("not used") },
  )
}

fn channel_history(
  db_subject: process.Subject(db.DbMessage),
  channel_id: String,
) -> List(db.StoredMessage) {
  let convo_id =
    db.resolve_conversation(db_subject, "discord", channel_id, 1)
    |> should.be_ok
  db.load_messages(db_subject, convo_id, 50)
  |> should.be_ok
}

fn write_ledger(paths: xdg.Paths, lines: List(String)) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(xdg.cognitive_dir(paths))
  let assert Ok(Nil) =
    simplifile.write(
      xdg.deliveries_path(paths),
      string.join(lines, "\n") <> "\n",
    )
  Nil
}

fn ledger_line(
  event_id: String,
  status: String,
  attention_action: String,
  target: String,
  channel_id: String,
  error: String,
) -> String {
  "{\"timestamp_ms\":1,\"event_id\":\""
  <> event_id
  <> "\",\"status\":\""
  <> status
  <> "\",\"attention_action\":\""
  <> attention_action
  <> "\",\"target\":\""
  <> target
  <> "\",\"channel_id\":\""
  <> channel_id
  <> "\",\"summary\":\"Old digest summary\",\"rationale\":\"Useful but not urgent.\",\"authority_required\":\"none\",\"citations\":[\"e1\"],\"gaps\":[],\"error\":\""
  <> error
  <> "\"}"
}

fn stop_subject(subject) -> Nil {
  case process.subject_owner(subject) {
    Ok(pid) -> {
      process.unlink(pid)
      process.kill(pid)
    }
    Error(_) -> Nil
  }
}

pub fn record_writes_ledger_without_sending_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-record")
  let #(fake, subject, reports) = start_delivery(paths)

  cognitive_delivery.deliver(subject, record_decision("ev-record"))

  let assert Ok(report) = process.receive(reports, 1000)
  report.status |> should.equal(cognitive_delivery.Recorded)
  fake_discord.all_sent_to(fake, "aura-channel") |> should.equal([])
  let log = simplifile.read(xdg.deliveries_path(paths)) |> should.be_ok
  log |> string.contains("\"event_id\":\"ev-record\"") |> should.be_true
  log |> string.contains("\"status\":\"recorded\"") |> should.be_true

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

fn block_delivery_ledger(paths: xdg.Paths) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(paths.data)
  let assert Ok(Nil) = simplifile.write(xdg.cognitive_dir(paths), "blocked")
  Nil
}

pub fn ledger_failure_prevents_recorded_transition_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-record-ledger-failure")
  block_delivery_ledger(paths)
  let #(fake, subject, reports) = start_delivery(paths)

  cognitive_delivery.deliver(subject, record_decision("ev-record-failed"))

  let assert Ok(report) = process.receive(reports, 1000)
  report.status |> should.equal(cognitive_delivery.Failed)
  report.error
  |> string.contains("delivery ledger write failed")
  |> should.be_true
  fake_discord.all_sent_to(fake, "aura-channel") |> should.equal([])

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn ledger_failure_does_not_write_successful_operational_audit_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-delivery-ledger-audit-order")
  block_delivery_ledger(paths)
  let #(_, subject, reports) = start_delivery_with_history(paths, db_subject)

  cognitive_delivery.deliver(subject, record_decision("ev-ledger-audit-failed"))
  let assert Ok(report) = process.receive(reports, 1000)
  report.status |> should.equal(cognitive_delivery.Failed)
  db.list_operational_audit(db_subject, "delivery", "ev-ledger-audit-failed")
  |> should.equal(Ok([]))

  process.send(db_subject, db.Shutdown)
  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn ledger_failure_prevents_immediate_send_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-send-ledger-failure")
  block_delivery_ledger(paths)
  let #(fake, subject, reports) = start_delivery(paths)

  cognitive_delivery.deliver(
    subject,
    decision("ev-send-failed", "surface_now", "default"),
  )

  let assert Ok(report) = process.receive(reports, 1000)
  report.status |> should.equal(cognitive_delivery.Failed)
  report.error
  |> string.contains("delivery ledger write failed")
  |> should.be_true
  fake_discord.all_sent_to(fake, "aura-channel") |> should.equal([])

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn restart_reports_interrupted_immediate_delivery_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-effect-unknown")
  write_ledger(paths, [
    ledger_line(
      "ev-effect-unknown",
      "sending",
      "surface_now",
      "default",
      "aura-channel",
      "",
    ),
  ])
  let #(fake, subject, reports) = start_delivery(paths)

  let assert Ok(report) = process.receive(reports, 1000)
  report.status |> should.equal(cognitive_delivery.Failed)
  report.error |> string.contains("effect is unknown") |> should.be_true
  fake_discord.all_sent_to(fake, "aura-channel") |> should.equal([])

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn digest_queues_then_flushes_one_group_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-digest")
  let #(fake, subject, reports) = start_delivery(paths)

  cognitive_delivery.deliver(subject, digest_decision("ev-digest"))
  let assert Ok(queued) = process.receive(reports, 1000)
  queued.status |> should.equal(cognitive_delivery.Queued)
  fake_discord.all_sent_to(fake, "aura-channel") |> should.equal([])

  cognitive_delivery.flush_digest(subject)
  let assert Ok(delivered) = process.receive(reports, 1000)
  delivered.status |> should.equal(cognitive_delivery.Delivered)
  let sent = fake_discord.all_sent_to(fake, "aura-channel")
  list.length(sent) |> should.equal(1)
  let assert [digest] = sent
  digest |> string.contains("Aura digest") |> should.be_true
  digest |> string.contains("ev-digest") |> should.be_true

  let log = simplifile.read(xdg.deliveries_path(paths)) |> should.be_ok
  log |> string.contains("\"status\":\"queued\"") |> should.be_true
  log |> string.contains("\"status\":\"delivered\"") |> should.be_true

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn digest_flush_persists_sent_message_to_channel_history_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-delivery-digest-history")
  let #(fake, subject, reports) = start_delivery_with_history(paths, db_subject)

  cognitive_delivery.deliver(subject, digest_decision("ev-digest-history"))
  let assert Ok(queued) = process.receive(reports, 1000)
  queued.status |> should.equal(cognitive_delivery.Queued)

  cognitive_delivery.flush_digest(subject)
  let assert Ok(delivered) = process.receive(reports, 1000)
  delivered.status |> should.equal(cognitive_delivery.Delivered)

  let assert [sent] = fake_discord.all_sent_to(fake, "aura-channel")
  sent |> string.contains("Aura digest") |> should.be_true
  sent |> string.contains("ev-digest-history") |> should.be_true

  let history = channel_history(db_subject, "aura-channel")
  list.length(history) |> should.equal(1)
  let assert [stored] = history
  stored.role |> should.equal("assistant")
  stored.content |> should.equal(sent)
  stored.author_id |> should.equal("aura")
  stored.author_name |> should.equal("Aura")

  process.send(db_subject, db.Shutdown)
  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn digest_send_failure_writes_dead_letter_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-dead-letter")
  let reports = process.new_subject()
  let assert Ok(started) =
    cognitive_delivery.start_with(
      paths,
      failing_discord("discord unavailable"),
      targets(),
      [],
      Some(reports),
    )
  let subject = started.data

  cognitive_delivery.deliver(subject, digest_decision("ev-dlq"))
  let assert Ok(queued) = process.receive(reports, 1000)
  queued.status |> should.equal(cognitive_delivery.Queued)

  cognitive_delivery.flush_digest(subject)
  let assert Ok(dead_letter) = process.receive(reports, 1000)
  dead_letter.status |> should.equal(cognitive_delivery.DeadLetter)
  dead_letter.error |> should.equal("discord unavailable")
  let log = simplifile.read(xdg.deliveries_path(paths)) |> should.be_ok
  log |> string.contains("\"event_id\":\"ev-dlq\"") |> should.be_true
  log |> string.contains("\"status\":\"dead_letter\"") |> should.be_true
  log |> string.contains("discord unavailable") |> should.be_true

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn digest_send_failure_does_not_persist_channel_history_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-delivery-digest-history-fail")
  let reports = process.new_subject()
  let assert Ok(started) =
    cognitive_delivery.start_with_history(
      paths,
      failing_discord("discord unavailable"),
      targets(),
      [],
      db_subject,
      Some(reports),
    )
  let subject = started.data

  cognitive_delivery.deliver(subject, digest_decision("ev-history-dlq"))
  let assert Ok(queued) = process.receive(reports, 1000)
  queued.status |> should.equal(cognitive_delivery.Queued)

  cognitive_delivery.flush_digest(subject)
  let assert Ok(dead_letter) = process.receive(reports, 1000)
  dead_letter.status |> should.equal(cognitive_delivery.DeadLetter)

  channel_history(db_subject, "aura-channel") |> should.equal([])

  process.send(db_subject, db.Shutdown)
  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn retry_dead_letters_resends_legacy_failed_digest_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-retry-legacy")
  write_ledger(paths, [
    ledger_line("ev-old", "queued", "digest", "default", "aura", ""),
    ledger_line(
      "ev-old",
      "failed",
      "digest",
      "default",
      "aura",
      "Unexpected status 400",
    ),
  ])
  let #(fake, subject, reports) = start_delivery(paths)

  let summary =
    cognitive_delivery.retry_dead_letters(subject)
    |> should.be_ok
  summary.retryable |> should.equal(1)
  summary.delivered |> should.equal(1)
  summary.failed |> should.equal(0)
  summary.skipped |> should.equal(0)

  let assert Ok(delivered) = process.receive(reports, 1000)
  delivered.status |> should.equal(cognitive_delivery.Delivered)
  let sent = fake_discord.all_sent_to(fake, "aura-channel")
  list.length(sent) |> should.equal(1)
  let assert [digest] = sent
  digest |> string.contains("Aura digest") |> should.be_true
  digest |> string.contains("ev-old") |> should.be_true

  let log = simplifile.read(xdg.deliveries_path(paths)) |> should.be_ok
  log |> string.contains("\"status\":\"delivered\"") |> should.be_true
  log |> string.contains("\"channel_id\":\"aura-channel\"") |> should.be_true

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn ask_now_sends_immediately_and_duplicate_does_not_resend_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-immediate")
  let #(fake, subject, reports) = start_delivery(paths)
  let d = decision("ev-ask", "ask_now", "default")

  cognitive_delivery.deliver(subject, d)
  let assert Ok(delivered) = process.receive(reports, 1000)
  delivered.status |> should.equal(cognitive_delivery.Delivered)
  let first_sent = fake_discord.all_sent_to(fake, "aura-channel")
  list.length(first_sent) |> should.equal(1)
  let assert [message] = first_sent
  message |> string.contains("Aura needs a decision") |> should.be_true
  message |> string.contains("Why now") |> should.be_true

  cognitive_delivery.deliver(subject, d)
  let assert Ok(duplicate) = process.receive(reports, 1000)
  duplicate.status |> should.equal(cognitive_delivery.DuplicateSuppressed)
  fake_discord.all_sent_to(fake, "aura-channel") |> should.equal(first_sent)

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn partial_chunk_send_becomes_effect_unknown_and_is_not_retryable_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-partial-send")
  let reports = process.new_subject()
  let assert Ok(db_subject) = db.start(":memory:")
  let assert Ok(started) =
    cognitive_delivery.start_with_history(
      paths,
      partial_failure_discord(),
      targets(),
      [],
      db_subject,
      Some(reports),
    )
  let subject = started.data
  let long_decision =
    cognitive_decision.DecisionEnvelope(
      ..decision("ev-partial", "surface_now", "default"),
      summary: string.repeat("x", 4500),
    )

  cognitive_delivery.deliver(subject, long_decision)
  let assert Ok(report) = process.receive(reports, 1000)
  report.status |> should.equal(cognitive_delivery.Failed)
  report.error |> string.contains("effect_unknown") |> should.be_true
  let log = simplifile.read(xdg.deliveries_path(paths)) |> should.be_ok
  log |> string.contains("\"status\":\"effect_unknown\"") |> should.be_true
  let queued =
    db.get_attention(db_subject, "attention:ev-partial") |> should.be_ok
  queued.state |> should.equal("dead_letter")
  let assert [visible_prefix] = channel_history(db_subject, "aura-channel")
  string.length(visible_prefix.content)
  |> should.equal(discord_message.discord_max_chars)
  visible_prefix.content
  |> string.contains("Aura noticed something attention-worthy")
  |> should.be_true
  let retry = cognitive_delivery.retry_dead_letters(subject) |> should.be_ok
  retry.retryable |> should.equal(0)

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn ask_now_persists_sent_message_to_channel_history_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-delivery-immediate-history")
  let #(fake, subject, reports) = start_delivery_with_history(paths, db_subject)

  cognitive_delivery.deliver(
    subject,
    decision("ev-ask-history", "ask_now", "default"),
  )
  let assert Ok(delivered) = process.receive(reports, 1000)
  delivered.status |> should.equal(cognitive_delivery.Delivered)

  let assert [sent] = fake_discord.all_sent_to(fake, "aura-channel")
  sent |> string.contains("Aura needs a decision") |> should.be_true
  sent |> string.contains("ev-ask-history") |> should.be_true

  let history = channel_history(db_subject, "aura-channel")
  list.length(history) |> should.equal(1)
  let assert [stored] = history
  stored.role |> should.equal("assistant")
  stored.content |> should.equal(sent)
  stored.author_id |> should.equal("aura")
  stored.author_name |> should.equal("Aura")

  let queued =
    db.get_attention(db_subject, "attention:ev-ask-history") |> should.be_ok
  queued.state |> should.equal("delivered")
  queued.delivery_target |> should.equal("default")
  queued.event_refs |> should.equal(["ev-ask-history"])
  queued.citations
  |> should.equal(["evidence:e1", "policy:attention.md"])

  let audit =
    db.list_operational_audit(
      db_subject,
      "attention_queue",
      "attention:ev-ask-history",
    )
    |> should.be_ok
  audit
  |> list.map(fn(row) { row.action })
  |> should.equal([
    "attention.enqueued",
    "attention.claimed",
    "attention.lease_renewed",
    "attention.delivery_intended",
    "attention.delivered",
  ])

  process.send(db_subject, db.Shutdown)
  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn startup_recovers_expired_pre_intent_claim_and_delivers_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-delivery-queue-recovery")
  let request =
    attention_queue.from_decision(
      decision("ev-queue-recovery", "surface_now", "default"),
      1,
    )
    |> should.be_ok
  let queued = db.enqueue_attention(db_subject, request) |> should.be_ok
  let assert Ok(Some(_)) =
    db.claim_attention(db_subject, "discord_compat", "interrupted-worker", 1, 1)
  let #(fake, subject, reports) = start_delivery_with_history(paths, db_subject)

  let assert Ok(delivered) = process.receive(reports, 1000)
  delivered.event_id |> should.equal("ev-queue-recovery")
  delivered.status |> should.equal(cognitive_delivery.Delivered)
  fake_discord.all_sent_to(fake, "aura-channel")
  |> list.length
  |> should.equal(1)
  db.get_attention(db_subject, queued.queue_id)
  |> should.be_ok
  |> fn(item) { item.state }
  |> should.equal("delivered")
  db.list_attention_attempts(db_subject, queued.queue_id)
  |> should.be_ok
  |> list.map(fn(attempt) { attempt.phase })
  |> should.equal(["failed", "succeeded"])

  stop_subject(subject)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn startup_does_not_deliver_untrusted_v13_queue_row_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-v13-quarantine")
  simplifile.create_directory_all(base) |> should.be_ok
  let db_path = base <> "/aura.db"
  create_v13_queue_fixture(db_path) |> should.be_ok
  let assert Ok(db_subject) = db.start(db_path)
  let #(fake, subject, reports) = start_delivery_with_history(paths, db_subject)

  process.receive(reports, 50) |> should.be_error
  fake_discord.all_events(fake) |> should.equal([])
  let quarantined = db.get_attention(db_subject, "legacy-queue") |> should.be_ok
  quarantined.state |> should.equal("dead_letter")
  quarantined.delivery_target |> should.equal("")

  stop_subject(subject)
  process.send(db_subject, db.Shutdown)
  let _ = simplifile.delete_all([base])
  Nil
}

fn create_v13_queue_fixture(path: String) -> Result(Nil, String) {
  use conn <- sqlight.with_connection(path)
  use _ <- result.try(db_schema.initialize(conn))
  use _ <- result.try(
    sqlight.exec(
      "INSERT INTO attention_queue (queue_id, schema_version, decision_id, domain_id, action, summary, rationale, state, delivery_owner, delivery_key, available_at_ms, created_at_ms, updated_at_ms, version) VALUES ('legacy-queue', 1, 'legacy-decision', 'legacy-domain', 'digest', 'Legacy summary', 'Legacy rationale', 'pending', 'discord_compat', 'legacy-delivery', 1, 1, 1, 1)",
      conn,
    )
    |> result.map_error(string.inspect),
  )
  use _ <- result.try(
    sqlight.exec("UPDATE schema_version SET version = 13", conn)
    |> result.map_error(string.inspect),
  )
  use _ <- result.try(
    sqlight.exec("DROP INDEX idx_attention_queue_authorized_route", conn)
    |> result.map_error(string.inspect),
  )
  use _ <- result.try(
    sqlight.exec(
      "ALTER TABLE attention_queue DROP COLUMN route_authorization_id",
      conn,
    )
    |> result.map_error(string.inspect),
  )
  use _ <- result.try(
    sqlight.exec(
      "ALTER TABLE attention_queue DROP COLUMN route_activation_ids_json",
      conn,
    )
    |> result.map_error(string.inspect),
  )
  use _ <- result.try(
    sqlight.exec(
      "ALTER TABLE attention_queue DROP COLUMN delivery_target",
      conn,
    )
    |> result.map_error(string.inspect),
  )
  use _ <- result.try(
    sqlight.exec("ALTER TABLE attention_queue DROP COLUMN payload_hash", conn)
    |> result.map_error(string.inspect),
  )
  sqlight.exec("DROP TABLE attention_delivery_attempts", conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(string.inspect)
}

pub fn suppressed_event_blocks_later_delivery_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-suppressed")
  let #(fake, subject, reports) = start_delivery(paths)

  cognitive_delivery.suppress_event(subject, "ev-suppressed", "test fixture")
  let assert Ok(suppressed) = process.receive(reports, 1000)
  suppressed.status |> should.equal(cognitive_delivery.Suppressed)

  cognitive_delivery.deliver(
    subject,
    decision("ev-suppressed", "surface_now", "default"),
  )
  let assert Ok(duplicate) = process.receive(reports, 1000)
  duplicate.status |> should.equal(cognitive_delivery.DuplicateSuppressed)
  fake_discord.all_sent_to(fake, "aura-channel") |> should.equal([])

  let log = simplifile.read(xdg.deliveries_path(paths)) |> should.be_ok
  log |> string.contains("\"status\":\"suppressed\"") |> should.be_true

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn deliver_hook_notify_sends_and_ledgers_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-hook-notify")
  let #(fake, subject, reports) = start_delivery(paths)

  let result =
    cognitive_delivery.deliver_hook_notify(
      subject,
      "hk-1",
      "linkedin",
      "default",
      "Challenge up",
    )
  result |> should.be_ok |> should.equal("delivered")

  let sent = fake_discord.all_sent_to(fake, "aura-channel")
  let assert [message] = sent
  message |> should.equal("Challenge up")

  let log = simplifile.read(xdg.deliveries_path(paths)) |> should.be_ok
  log |> string.contains("\"event_id\":\"hk-1\"") |> should.be_true
  log |> string.contains("\"status\":\"delivered\"") |> should.be_true
  log
  |> string.contains("\"attention_action\":\"surface_now\"")
  |> should.be_true
  log
  |> string.contains("\"rationale\":\"hook-declared: linkedin\"")
  |> should.be_true

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn deliver_hook_notify_dedupes_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-hook-dedupe")
  let #(fake, subject, reports) = start_delivery(paths)

  cognitive_delivery.deliver_hook_notify(
    subject,
    "hk-1",
    "linkedin",
    "default",
    "first",
  )
  |> should.be_ok
  |> should.equal("delivered")

  cognitive_delivery.deliver_hook_notify(
    subject,
    "hk-1",
    "linkedin",
    "default",
    "second",
  )
  |> should.be_ok
  |> should.equal("deduped")

  let assert [_] = fake_discord.all_sent_to(fake, "aura-channel")

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn interrupted_hook_delivery_reports_effect_unknown_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-hook-effect-unknown")
  write_ledger(paths, [
    ledger_line(
      "hk-effect-unknown",
      "sending",
      "surface_now",
      "default",
      "aura-channel",
      "",
    ),
  ])
  let #(fake, subject, _) = start_delivery(paths)

  cognitive_delivery.deliver_hook_notify(
    subject,
    "hk-effect-unknown",
    "synthetic",
    "default",
    "Do not duplicate",
  )
  |> should.be_error
  |> string.contains("effect is unknown")
  |> should.be_true
  fake_discord.all_sent_to(fake, "aura-channel") |> should.equal([])

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn deliver_hook_notify_unknown_target_test() {
  let #(base, paths) = temp_paths("cognitive-delivery-hook-unknown")
  let #(fake, subject, reports) = start_delivery(paths)

  cognitive_delivery.deliver_hook_notify(
    subject,
    "hk-2",
    "linkedin",
    "domain:nope",
    "x",
  )
  |> should.be_error
  |> string.contains("unknown delivery target")
  |> should.be_true

  let log = simplifile.read(xdg.deliveries_path(paths)) |> should.be_ok
  log |> string.contains("\"status\":\"dead_letter\"") |> should.be_true
  fake_discord.all_sent_to(fake, "aura-channel") |> should.equal([])

  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}

pub fn record_hook_delivery_appends_without_sending_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("cognitive-delivery-hook-record")
  let #(fake, subject, reports) = start_delivery_with_history(paths, db_subject)

  cognitive_delivery.record_hook_delivery(
    subject,
    "hk-3",
    "linkedin",
    "default",
    "aura-channel",
    "Ask posted elsewhere",
  )
  |> should.be_ok

  let log = simplifile.read(xdg.deliveries_path(paths)) |> should.be_ok
  log |> string.contains("\"event_id\":\"hk-3\"") |> should.be_true
  log |> string.contains("\"attention_action\":\"ask_now\"") |> should.be_true
  log |> string.contains("\"status\":\"delivered\"") |> should.be_true

  // invariant 9: the ask message lands in channel history even though the
  // transport was not called for a send
  fake_discord.all_sent_to(fake, "aura-channel") |> should.equal([])
  let history = channel_history(db_subject, "aura-channel")
  list.length(history) |> should.equal(1)
  let assert [stored] = history
  stored.content |> should.equal("Ask posted elsewhere")
  let assert [history_audit, delivery_audit] =
    db.list_operational_audit(db_subject, "delivery", "hk-3")
    |> should.be_ok
  history_audit.action |> should.equal("delivery.history_persisted")
  delivery_audit.action |> should.equal("delivery.delivered")

  process.send(db_subject, db.Shutdown)
  stop_subject(subject)
  let _ = simplifile.delete_all([base])
  Nil
}
