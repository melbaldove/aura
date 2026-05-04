import aura/dream_effect
import aura/dream_report
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn render_cycle_report_includes_counts_and_diffs_test() {
  let report =
    dream_report.render_cycle_report(
      started_local: "2026-05-04 12:00:00 Asia/Manila",
      completed_local: "2026-05-04 12:06:11 Asia/Manila",
      domain_count: 5,
      failed_count: 0,
      effects: [
        dream_effect.DreamEffect(
          phase: "render",
          domain: "cm2",
          target: "memory",
          key: "report-architecture",
          action: "set",
          kind: dream_effect.EffectNew,
          previous_memory_entry_id: None,
          new_memory_entry_id: Some(596),
          previous_chars: None,
          content_chars: 1533,
          created_at_ms: 1_777_867_374_261,
        ),
      ],
      candidates: [],
    )

  report |> string.contains("Dream complete") |> should.be_true
  report
  |> string.contains("cm2/memory/report-architecture")
  |> should.be_true
  report |> string.contains("new") |> should.be_true
}

pub fn render_cycle_report_includes_action_candidates_test() {
  let report =
    dream_report.render_cycle_report(
      started_local: "2026-05-04 12:00:00 Asia/Manila",
      completed_local: "2026-05-04 12:06:11 Asia/Manila",
      domain_count: 5,
      failed_count: 0,
      effects: [],
      candidates: [
        dream_effect.ActionCandidate(
          domain: "arc",
          candidate_type: "needs_external_input",
          severity: 2,
          reason: "Domain is in closure without new non-index evidence.",
        ),
      ],
    )

  report |> string.contains("Action Candidates") |> should.be_true
  report |> string.contains("needs_external_input") |> should.be_true
}
