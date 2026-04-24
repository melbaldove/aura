import aura/cognitive_event
import gleam/list
import gleam/option.{type Option}

/// Model or fixture output describing what an observation means.
pub type CognitiveInterpretation {
  CognitiveInterpretation(
    observation_id: String,
    concern_matches: List(ConcernMatch),
    proposed_concerns: List(ProposedConcern),
    semantic_claims: List(SemanticClaim),
    attention_judgment: AttentionJudgment,
    work_disposition: WorkDisposition,
    authority_requirement: AuthorityRequirement,
    gap_events: List(GapEvent),
    explanation: String,
    confidence: Float,
  )
}

pub type ConcernMatch {
  ConcernMatch(
    concern_id: String,
    relation: String,
    confidence: Float,
    evidence_refs: List(String),
    explanation: String,
  )
}

pub type ProposedConcern {
  ProposedConcern(
    label: String,
    kind: String,
    reason: String,
    evidence_refs: List(String),
    lineage_ref: String,
    activation_status: String,
  )
}

pub type SemanticClaim {
  SemanticClaim(
    kind: String,
    subject: String,
    object: String,
    confidence: Float,
    evidence_refs: List(String),
    explanation: String,
    verification_status: String,
  )
}

pub type AttentionAction {
  Suppress
  Record
  DigestLater
  SurfaceNow
  AskNow
  DeferUntilCondition
}

pub type AttentionJudgment {
  AttentionJudgment(
    action: AttentionAction,
    reason: String,
    confidence: Float,
    trigger_or_schedule: String,
    user_decision_required: String,
    deferral_cost: String,
    why_not_digest: String,
    review_condition: String,
    correction_path: String,
    evidence_refs: List(String),
  )
}

pub type WorkAction {
  NoWork
  Prepare
  Delegate
  Execute
}

pub type WorkDisposition {
  WorkDisposition(
    action: WorkAction,
    target: String,
    reason: String,
    proof_required: String,
    expected_result: String,
    evidence_refs: List(String),
  )
}

pub type AuthorityRequirementKind {
  NoAuthority
  Approval
  Credential
  Permission
  Capability
  Context
  HumanJudgment
}

pub type AuthorityRequirement {
  AuthorityRequirement(
    requirement: AuthorityRequirementKind,
    reason: String,
    resolver: String,
    evidence_refs: List(String),
  )
}

pub type PreferencePrompt {
  PreferencePrompt(
    situation: String,
    evidence: String,
    reusable_question: String,
    recommended_default: String,
    consequences: String,
    answer_shortcuts: List(String),
  )
}

pub type GapEvent {
  GapEvent(
    kind: String,
    scope: String,
    observed_during: String,
    blocks: Bool,
    attempted: String,
    self_help_available: Bool,
    impact: String,
    resolver: String,
    options: List(String),
    recommended_next_step: String,
    durable: Bool,
    risk_if_ignored: String,
    evidence_refs: List(String),
    interrupt: Bool,
    batch_key: String,
    preference_prompt: Option(PreferencePrompt),
  )
}

/// Conservative production fallback until model-backed interpretation lands.
pub fn record_only(
  observation: cognitive_event.Observation,
  evidence: cognitive_event.EvidenceBundle,
) -> CognitiveInterpretation {
  CognitiveInterpretation(
    observation_id: observation.id,
    concern_matches: [],
    proposed_concerns: [],
    semantic_claims: [],
    attention_judgment: AttentionJudgment(
      action: Record,
      reason: "Recorded external observation for later cognitive interpretation.",
      confidence: 1.0,
      trigger_or_schedule: "",
      user_decision_required: "",
      deferral_cost: "",
      why_not_digest: "",
      review_condition: "",
      correction_path: "Correct the source event or future interpretation.",
      evidence_refs: first_evidence_ref(evidence),
    ),
    work_disposition: WorkDisposition(
      action: NoWork,
      target: "",
      reason: "No autonomous work is dispatched in the log-only slice.",
      proof_required: "",
      expected_result: "",
      evidence_refs: [],
    ),
    authority_requirement: AuthorityRequirement(
      requirement: NoAuthority,
      reason: "No external action is taken.",
      resolver: "aura",
      evidence_refs: [],
    ),
    gap_events: [],
    explanation: "Log-only interpretation generated without mutating state.",
    confidence: 1.0,
  )
}

pub fn attention_action_to_string(action: AttentionAction) -> String {
  case action {
    Suppress -> "suppress"
    Record -> "record"
    DigestLater -> "digest_later"
    SurfaceNow -> "surface_now"
    AskNow -> "ask_now"
    DeferUntilCondition -> "defer_until_condition"
  }
}

pub fn work_action_to_string(action: WorkAction) -> String {
  case action {
    NoWork -> "none"
    Prepare -> "prepare"
    Delegate -> "delegate"
    Execute -> "execute"
  }
}

fn first_evidence_ref(evidence: cognitive_event.EvidenceBundle) -> List(String) {
  case evidence.atoms {
    [first, ..] -> [first.id]
    [] -> []
  }
}

/// Count interrupting gaps without exposing the representation to workers.
pub fn interrupting_gap_count(gaps: List(GapEvent)) -> Int {
  gaps
  |> list.filter(fn(gap) { gap.interrupt })
  |> list.length
}
