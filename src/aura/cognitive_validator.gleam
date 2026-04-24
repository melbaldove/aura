import aura/cognitive_event
import aura/cognitive_interpretation as ci
import gleam/list
import gleam/option

/// Validate model or fixture interpretation before it can affect any state.
pub fn validate(
  interpretation: ci.CognitiveInterpretation,
  evidence: cognitive_event.EvidenceBundle,
) -> Result(ci.CognitiveInterpretation, List(String)) {
  let errors =
    []
    |> require(
      interpretation.observation_id == evidence.observation_id,
      "interpretation observation_id does not match evidence bundle",
    )
    |> require(
      interpretation.explanation != "",
      "interpretation explanation is required",
    )
    |> validate_confidence(
      "interpretation confidence",
      interpretation.confidence,
    )
    |> validate_concern_matches(interpretation.concern_matches, evidence)
    |> validate_proposed_concerns(interpretation.proposed_concerns, evidence)
    |> validate_semantic_claims(interpretation.semantic_claims, evidence)
    |> validate_attention(interpretation.attention_judgment, evidence)
    |> validate_work(interpretation.work_disposition, evidence)
    |> validate_authority(interpretation.authority_requirement, evidence)
    |> validate_gaps(interpretation.gap_events, evidence)

  case errors {
    [] -> Ok(interpretation)
    _ -> Error(list.reverse(errors))
  }
}

fn validate_concern_matches(
  errors: List(String),
  matches: List(ci.ConcernMatch),
  evidence: cognitive_event.EvidenceBundle,
) -> List(String) {
  list.fold(matches, errors, fn(errs, match) {
    errs
    |> require(match.concern_id != "", "concern match concern_id is required")
    |> require(match.relation != "", "concern match relation is required")
    |> require(match.explanation != "", "concern match explanation is required")
    |> validate_confidence("concern match confidence", match.confidence)
    |> validate_required_refs("concern match", match.evidence_refs, evidence)
  })
}

fn validate_proposed_concerns(
  errors: List(String),
  concerns: List(ci.ProposedConcern),
  evidence: cognitive_event.EvidenceBundle,
) -> List(String) {
  list.fold(concerns, errors, fn(errs, concern) {
    errs
    |> require(concern.label != "", "proposed concern label is required")
    |> require(concern.kind != "", "proposed concern kind is required")
    |> require(concern.reason != "", "proposed concern reason is required")
    |> require(
      concern.activation_status != "",
      "proposed concern activation_status is required",
    )
    |> validate_required_refs(
      "proposed concern",
      concern.evidence_refs,
      evidence,
    )
  })
}

fn validate_semantic_claims(
  errors: List(String),
  claims: List(ci.SemanticClaim),
  evidence: cognitive_event.EvidenceBundle,
) -> List(String) {
  list.fold(claims, errors, fn(errs, claim) {
    errs
    |> require(claim.kind != "", "semantic claim kind is required")
    |> require(claim.subject != "", "semantic claim subject is required")
    |> require(
      claim.explanation != "",
      "semantic claim explanation is required",
    )
    |> require(
      claim.verification_status != "",
      "semantic claim verification_status is required",
    )
    |> validate_confidence("semantic claim confidence", claim.confidence)
    |> validate_required_refs("semantic claim", claim.evidence_refs, evidence)
  })
}

fn validate_attention(
  errors: List(String),
  attention: ci.AttentionJudgment,
  evidence: cognitive_event.EvidenceBundle,
) -> List(String) {
  let errors =
    errors
    |> require(attention.reason != "", "attention reason is required")
    |> require(
      attention.correction_path != "",
      "attention correction_path is required",
    )
    |> validate_confidence("attention confidence", attention.confidence)
    |> validate_optional_refs("attention", attention.evidence_refs, evidence)

  case attention.action {
    ci.SurfaceNow | ci.AskNow ->
      errors
      |> require(
        attention.evidence_refs != [],
        "attention-spending action must cite evidence",
      )
      |> require(
        attention.user_decision_required != "",
        "attention-spending action requires user_decision_required",
      )
      |> require(
        attention.deferral_cost != "",
        "attention-spending action requires deferral_cost",
      )
      |> require(
        attention.why_not_digest != "",
        "attention-spending action requires why_not_digest",
      )
    _ -> errors
  }
}

fn validate_work(
  errors: List(String),
  work: ci.WorkDisposition,
  evidence: cognitive_event.EvidenceBundle,
) -> List(String) {
  let errors =
    errors
    |> require(work.reason != "", "work disposition reason is required")
    |> validate_optional_refs("work disposition", work.evidence_refs, evidence)

  case work.action {
    ci.NoWork -> errors
    _ ->
      errors
      |> require(work.target != "", "non-empty work target is required")
      |> require(
        work.expected_result != "",
        "non-empty work expected_result is required",
      )
  }
}

fn validate_authority(
  errors: List(String),
  authority: ci.AuthorityRequirement,
  evidence: cognitive_event.EvidenceBundle,
) -> List(String) {
  let errors =
    errors
    |> require(authority.reason != "", "authority reason is required")
    |> require(authority.resolver != "", "authority resolver is required")
    |> validate_optional_refs(
      "authority requirement",
      authority.evidence_refs,
      evidence,
    )

  case authority.requirement {
    ci.NoAuthority -> errors
    _ ->
      errors
      |> require(
        authority.evidence_refs != [],
        "non-empty authority requirement must cite evidence",
      )
  }
}

fn validate_gaps(
  errors: List(String),
  gaps: List(ci.GapEvent),
  evidence: cognitive_event.EvidenceBundle,
) -> List(String) {
  list.fold(gaps, errors, fn(errs, gap) {
    errs
    |> require(gap.kind != "", "gap kind is required")
    |> require(gap.scope != "", "gap scope is required")
    |> require(gap.observed_during != "", "gap observed_during is required")
    |> require(gap.attempted != "", "gap attempted is required")
    |> require(gap.impact != "", "gap impact is required")
    |> require(gap.resolver != "", "gap resolver is required")
    |> require(gap.options != [], "gap options are required")
    |> require(
      gap.recommended_next_step != "",
      "gap recommended_next_step is required",
    )
    |> validate_required_refs("gap event", gap.evidence_refs, evidence)
    |> validate_gap_prompt(gap)
  })
}

fn validate_gap_prompt(errors: List(String), gap: ci.GapEvent) -> List(String) {
  case gap.preference_prompt {
    option.Some(prompt) ->
      errors
      |> require(
        prompt.situation != "",
        "preference prompt situation is required",
      )
      |> require(
        prompt.reusable_question != "",
        "preference prompt question is required",
      )
      |> require(
        prompt.recommended_default != "",
        "preference prompt recommended_default is required",
      )
    option.None -> errors
  }
}

fn validate_confidence(
  errors: List(String),
  label: String,
  value: Float,
) -> List(String) {
  errors
  |> require(
    value >=. 0.0 && value <=. 1.0,
    label <> " must be between 0 and 1",
  )
}

fn validate_required_refs(
  errors: List(String),
  label: String,
  refs: List(String),
  evidence: cognitive_event.EvidenceBundle,
) -> List(String) {
  errors
  |> require(refs != [], label <> " must cite evidence")
  |> validate_optional_refs(label, refs, evidence)
}

fn validate_optional_refs(
  errors: List(String),
  label: String,
  refs: List(String),
  evidence: cognitive_event.EvidenceBundle,
) -> List(String) {
  list.fold(refs, errors, fn(errs, ref) {
    errs
    |> require(
      evidence_ref_exists(ref, evidence),
      label <> " references unknown evidence ref: " <> ref,
    )
  })
}

fn evidence_ref_exists(
  ref: String,
  evidence: cognitive_event.EvidenceBundle,
) -> Bool {
  list.any(evidence.atoms, fn(atom) { atom.id == ref })
}

fn require(
  errors: List(String),
  condition: Bool,
  message: String,
) -> List(String) {
  case condition {
    True -> errors
    False -> [message, ..errors]
  }
}
