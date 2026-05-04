import aura/dream_effect
import gleam/int
import gleam/list
import gleam/string

/// Render the compact markdown report written after each full dream cycle.
pub fn render_cycle_report(
  started_local started_local: String,
  completed_local completed_local: String,
  domain_count domain_count: Int,
  failed_count failed_count: Int,
  effects effects: List(dream_effect.DreamEffect),
  candidates candidates: List(dream_effect.ActionCandidate),
) -> String {
  let summary = dream_effect.summarize_effects(effects)
  "# Dream Report\n\n"
  <> "Started: "
  <> started_local
  <> "\n"
  <> "Completed: "
  <> completed_local
  <> "\n"
  <> "Dream complete: "
  <> int.to_string(domain_count - failed_count)
  <> " domains ok, "
  <> int.to_string(failed_count)
  <> " failed\n\n"
  <> "## Counts\n\n"
  <> "- New: "
  <> int.to_string(summary.new)
  <> "\n"
  <> "- Changed: "
  <> int.to_string(summary.changed)
  <> "\n"
  <> "- No-op: "
  <> int.to_string(summary.noop)
  <> "\n"
  <> "- Removed: "
  <> int.to_string(summary.removed)
  <> "\n"
  <> "- Actual writes: "
  <> int.to_string(summary.actual_writes)
  <> "\n\n"
  <> "## Action Candidates\n\n"
  <> render_candidates(candidates)
  <> "\n## Diffs\n\n"
  <> render_effects(effects)
}

fn render_candidates(candidates: List(dream_effect.ActionCandidate)) -> String {
  case candidates {
    [] -> "- None\n"
    _ ->
      candidates
      |> list.map(fn(candidate) {
        "- [severity "
        <> int.to_string(candidate.severity)
        <> "] "
        <> candidate.domain
        <> ": "
        <> candidate.candidate_type
        <> " - "
        <> candidate.reason
        <> "\n"
      })
      |> string.concat
  }
}

fn render_effects(effects: List(dream_effect.DreamEffect)) -> String {
  case effects {
    [] -> "- No memory effects recorded\n"
    _ ->
      effects
      |> list.map(fn(effect) {
        "- " <> dream_effect.effect_line(effect) <> "\n"
      })
      |> string.concat
  }
}
