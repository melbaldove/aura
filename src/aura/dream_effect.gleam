import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Classification for one memory tool outcome produced during dreaming.
pub type EffectKind {
  EffectNew
  EffectChanged
  EffectNoop
  EffectRemoved
}

/// One structured memory effect from a dream phase.
pub type DreamEffect {
  DreamEffect(
    phase: String,
    domain: String,
    target: String,
    key: String,
    action: String,
    kind: EffectKind,
    previous_memory_entry_id: Option(Int),
    new_memory_entry_id: Option(Int),
    previous_chars: Option(Int),
    content_chars: Int,
    created_at_ms: Int,
  )
}

/// Aggregate counts for a list of dream effects.
pub type EffectSummary {
  EffectSummary(
    new: Int,
    changed: Int,
    noop: Int,
    removed: Int,
    actual_writes: Int,
  )
}

/// Deterministic follow-up surfaced from dream evidence.
pub type ActionCandidate {
  ActionCandidate(
    domain: String,
    candidate_type: String,
    severity: Int,
    reason: String,
  )
}

/// Current-cycle plus recent-history signals used for candidate detection.
pub type DomainDreamObservation {
  DomainDreamObservation(
    domain: String,
    cycle_count: Int,
    actual_writes: Int,
    noops: Int,
    latest_index_mentions_external_input: Bool,
    latest_index_mentions_closure: Bool,
    non_index_writes: Int,
  )
}

/// Count effects by kind and derive actual write count.
pub fn summarize_effects(effects: List(DreamEffect)) -> EffectSummary {
  let new = list.count(effects, fn(e) { e.kind == EffectNew })
  let changed = list.count(effects, fn(e) { e.kind == EffectChanged })
  let noop = list.count(effects, fn(e) { e.kind == EffectNoop })
  let removed = list.count(effects, fn(e) { e.kind == EffectRemoved })
  EffectSummary(
    new: new,
    changed: changed,
    noop: noop,
    removed: removed,
    actual_writes: new + changed + removed,
  )
}

/// Render an effect kind as the stable DB/report string.
pub fn effect_kind_to_string(kind: EffectKind) -> String {
  case kind {
    EffectNew -> "new"
    EffectChanged -> "changed"
    EffectNoop -> "noop"
    EffectRemoved -> "removed"
  }
}

/// Detect deterministic operational candidates from dream observations.
pub fn detect_action_candidates(
  observations: List(DomainDreamObservation),
) -> List(ActionCandidate) {
  observations
  |> list.flat_map(fn(obs) {
    let sleep = case
      obs.cycle_count >= 3 && obs.actual_writes == 0 && obs.noops > 0
    {
      True -> [
        ActionCandidate(
          domain: obs.domain,
          candidate_type: "sleep_candidate",
          severity: 2,
          reason: "Repeated dream cycles produced no changed memory.",
        ),
      ]
      False -> []
    }

    let external = case
      obs.latest_index_mentions_external_input
      && obs.latest_index_mentions_closure
      && obs.non_index_writes == 0
    {
      True -> [
        ActionCandidate(
          domain: obs.domain,
          candidate_type: "needs_external_input",
          severity: 2,
          reason: "Domain index describes closure without new non-index evidence.",
        ),
      ]
      False -> []
    }

    list.append(sleep, external)
  })
}

/// Return True when text describes waiting on external input.
pub fn mentions_external_input(text: String) -> Bool {
  let lower = string.lowercase(text)
  string.contains(lower, "external input")
  || string.contains(lower, "external trigger")
}

/// Return True when text describes closure, sleep, or archive state.
pub fn mentions_closure(text: String) -> Bool {
  let lower = string.lowercase(text)
  string.contains(lower, "closure")
  || string.contains(lower, "archive")
  || string.contains(lower, "sleep")
}

/// Render a compact one-line before/after effect summary.
pub fn effect_line(effect: DreamEffect) -> String {
  effect_kind_to_string(effect.kind)
  <> " "
  <> effect.domain
  <> "/"
  <> effect.target
  <> "/"
  <> effect.key
  <> ": "
  <> previous_chars_text(effect.previous_chars)
  <> " -> "
  <> int.to_string(effect.content_chars)
  <> " chars"
}

fn previous_chars_text(chars: Option(Int)) -> String {
  case chars {
    Some(value) -> int.to_string(value)
    None -> "new"
  }
}
