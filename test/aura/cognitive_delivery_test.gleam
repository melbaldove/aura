import aura/cognitive_decision
import aura/cognitive_delivery
import aura/test_helpers
import aura/xdg
import fakes/fake_discord
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

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
  let assert Ok(started) =
    cognitive_delivery.start_with(paths, discord, targets(), [], Some(reports))
  #(fake, started.data, reports)
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
