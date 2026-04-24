import aura/cognitive_event
import aura/cognitive_interpretation as ci
import aura/cognitive_validator
import aura/event
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn evidence() -> cognitive_event.EvidenceBundle {
  event.AuraEvent(
    id: "ev-1",
    source: "gmail",
    type_: "email.received",
    subject: "Please review REL-42 tomorrow",
    time_ms: 1000,
    tags: dict.from_list([#("from", "alice@example.com")]),
    external_id: "msg-1",
    data: "{\"from\":\"alice@example.com\",\"thread_id\":\"t-1\"}",
  )
  |> cognitive_event.from_event
  |> cognitive_event.extract_evidence
}

fn first_ref(bundle: cognitive_event.EvidenceBundle) -> String {
  let assert [first, ..] = bundle.atoms
  first.id
}

fn base_interpretation(
  bundle: cognitive_event.EvidenceBundle,
) -> ci.CognitiveInterpretation {
  let ref = first_ref(bundle)
  ci.CognitiveInterpretation(
    observation_id: bundle.observation_id,
    concern_matches: [],
    proposed_concerns: [],
    semantic_claims: [
      ci.SemanticClaim(
        kind: "contains_request",
        subject: "msg-1",
        object: "review REL-42",
        confidence: 0.8,
        evidence_refs: [ref],
        explanation: "The message asks for review.",
        verification_status: "source_observed",
      ),
    ],
    attention_judgment: ci.AttentionJudgment(
      action: ci.Record,
      reason: "Record in log-only mode.",
      confidence: 0.9,
      trigger_or_schedule: "",
      user_decision_required: "",
      deferral_cost: "",
      why_not_digest: "",
      review_condition: "",
      correction_path: "Correct interpretation if wrong.",
      evidence_refs: [ref],
    ),
    work_disposition: ci.WorkDisposition(
      action: ci.NoWork,
      target: "",
      reason: "No work dispatched in log-only mode.",
      proof_required: "",
      expected_result: "",
      evidence_refs: [],
    ),
    authority_requirement: ci.AuthorityRequirement(
      requirement: ci.NoAuthority,
      reason: "No external action taken.",
      resolver: "aura",
      evidence_refs: [],
    ),
    gap_events: [],
    explanation: "Valid interpretation fixture.",
    confidence: 0.9,
  )
}

pub fn validator_accepts_cited_record_interpretation_test() {
  let bundle = evidence()
  let interpretation = base_interpretation(bundle)

  cognitive_validator.validate(interpretation, bundle) |> should.be_ok
}

pub fn validator_rejects_missing_evidence_ref_test() {
  let bundle = evidence()
  let base = base_interpretation(bundle)
  let bad_claim =
    ci.SemanticClaim(
      kind: "contains_request",
      subject: "msg-1",
      object: "review REL-42",
      confidence: 0.8,
      evidence_refs: ["missing-ref"],
      explanation: "The message asks for review.",
      verification_status: "source_observed",
    )
  let interpretation =
    ci.CognitiveInterpretation(..base, semantic_claims: [bad_claim])

  let assert Error(errors) =
    cognitive_validator.validate(interpretation, bundle)
  has_error(errors, "unknown evidence ref") |> should.be_true
}

pub fn validator_rejects_surface_now_without_attention_proof_test() {
  let bundle = evidence()
  let base = base_interpretation(bundle)
  let ref = first_ref(bundle)
  let attention =
    ci.AttentionJudgment(
      action: ci.SurfaceNow,
      reason: "Looks important.",
      confidence: 0.9,
      trigger_or_schedule: "",
      user_decision_required: "",
      deferral_cost: "",
      why_not_digest: "",
      review_condition: "",
      correction_path: "Correct interpretation if wrong.",
      evidence_refs: [ref],
    )
  let interpretation =
    ci.CognitiveInterpretation(..base, attention_judgment: attention)

  let assert Error(errors) =
    cognitive_validator.validate(interpretation, bundle)
  has_error(errors, "user_decision_required") |> should.be_true
  has_error(errors, "deferral_cost") |> should.be_true
  has_error(errors, "why_not_digest") |> should.be_true
}

pub fn validator_accepts_preference_gap_with_prompt_test() {
  let bundle = evidence()
  let base = base_interpretation(bundle)
  let ref = first_ref(bundle)
  let gap =
    ci.GapEvent(
      kind: "preference",
      scope: "domain",
      observed_during: "attention judgment",
      blocks: False,
      attempted: "Checked existing defaults.",
      self_help_available: False,
      impact: "Could choose digest or interrupt next time.",
      resolver: "user",
      options: ["digest_later", "surface_now"],
      recommended_next_step: "Use digest_later by default.",
      durable: True,
      risk_if_ignored: "Aura may ask too often.",
      evidence_refs: [ref],
      interrupt: False,
      batch_key: "attention-preference",
      preference_prompt: Some(
        ci.PreferencePrompt(
          situation: "A request arrived with a deadline.",
          evidence: ref,
          reusable_question: "Should similar requests interrupt you?",
          recommended_default: "Digest unless due today.",
          consequences: "Less interruption, possible later awareness.",
          answer_shortcuts: ["use default", "always ask"],
        ),
      ),
    )
  let interpretation = ci.CognitiveInterpretation(..base, gap_events: [gap])

  cognitive_validator.validate(interpretation, bundle) |> should.be_ok
}

pub fn validator_rejects_gap_without_resolution_path_test() {
  let bundle = evidence()
  let base = base_interpretation(bundle)
  let ref = first_ref(bundle)
  let gap =
    ci.GapEvent(
      kind: "capability",
      scope: "jira",
      observed_during: "interpretation",
      blocks: True,
      attempted: "Checked connected sources.",
      self_help_available: False,
      impact: "Cannot verify ticket state.",
      resolver: "",
      options: [],
      recommended_next_step: "",
      durable: False,
      risk_if_ignored: "State may be stale.",
      evidence_refs: [ref],
      interrupt: True,
      batch_key: "capability",
      preference_prompt: None,
    )
  let interpretation = ci.CognitiveInterpretation(..base, gap_events: [gap])

  let assert Error(errors) =
    cognitive_validator.validate(interpretation, bundle)
  has_error(errors, "resolver") |> should.be_true
  has_error(errors, "options") |> should.be_true
  has_error(errors, "recommended_next_step") |> should.be_true
}

fn has_error(errors: List(String), needle: String) -> Bool {
  list.any(errors, fn(error) { string.contains(error, needle) })
}
