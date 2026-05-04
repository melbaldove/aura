import aura/dream_effect
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

pub fn summarize_effects_counts_actual_writes_and_noops_test() {
  let effects = [
    dream_effect.DreamEffect(
      phase: "render",
      domain: "arc",
      target: "memory",
      key: "domain-index",
      action: "set",
      kind: dream_effect.EffectChanged,
      previous_memory_entry_id: Some(1),
      new_memory_entry_id: Some(2),
      previous_chars: Some(47),
      content_chars: 756,
      created_at_ms: 1_777_867_368_328,
    ),
    dream_effect.DreamEffect(
      phase: "render",
      domain: "khoc-accounts",
      target: "memory",
      key: "domain-index",
      action: "set",
      kind: dream_effect.EffectNoop,
      previous_memory_entry_id: Some(3),
      new_memory_entry_id: None,
      previous_chars: Some(97),
      content_chars: 97,
      created_at_ms: 1_777_867_272_604,
    ),
  ]

  let summary = dream_effect.summarize_effects(effects)

  summary.changed |> should.equal(1)
  summary.noop |> should.equal(1)
  summary.actual_writes |> should.equal(1)
}

pub fn detect_noop_only_domain_as_sleep_candidate_test() {
  let candidates =
    dream_effect.detect_action_candidates([
      dream_effect.DomainDreamObservation(
        domain: "empty-domain",
        cycle_count: 4,
        actual_writes: 0,
        noops: 4,
        latest_index_mentions_external_input: False,
        latest_index_mentions_closure: False,
        non_index_writes: 0,
      ),
    ])

  candidates
  |> list.any(fn(c) {
    c.domain == "empty-domain" && c.candidate_type == "sleep_candidate"
  })
  |> should.be_true
}

pub fn detect_closure_without_external_input_test() {
  let candidates =
    dream_effect.detect_action_candidates([
      dream_effect.DomainDreamObservation(
        domain: "strategy-domain",
        cycle_count: 5,
        actual_writes: 2,
        noops: 0,
        latest_index_mentions_external_input: True,
        latest_index_mentions_closure: True,
        non_index_writes: 0,
      ),
    ])

  candidates
  |> list.any(fn(c) {
    c.domain == "strategy-domain" && c.candidate_type == "needs_external_input"
  })
  |> should.be_true
}

pub fn effect_kind_roundtrips_to_db_string_test() {
  dream_effect.effect_kind_to_string(dream_effect.EffectChanged)
  |> should.equal("changed")
}
