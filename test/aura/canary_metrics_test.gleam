import aura/canary_metrics
import gleam/dict
import gleam/string
import gleeunit/should

pub fn authorized_metrics_accept_counts_and_opaque_refs_only_test() {
  let report =
    canary_metrics.build(
      [
        "metric:evidence.accepted",
        "metric:attention.queued",
        "metric:transcript.violations",
      ],
      [
        canary_metrics.Count("metric:evidence.accepted", 2),
        canary_metrics.Count("metric:attention.queued", 1),
        canary_metrics.Count("metric:transcript.violations", 0),
      ],
      ["audit:canary:local-proof"],
    )
    |> should.be_ok

  dict.get(report.counts, "metric:evidence.accepted")
  |> should.equal(Ok(2))
  report.proof_refs |> should.equal(["audit:canary:local-proof"])
  canary_metrics.encode(report)
  |> string.contains("transcript_text")
  |> should.be_false
}

pub fn unauthorized_metric_and_non_opaque_proof_fail_closed_test() {
  canary_metrics.build(
    ["metric:evidence.accepted"],
    [canary_metrics.Count("metric:attention.queued", 1)],
    ["audit:canary:local-proof"],
  )
  |> should.equal(Error("unauthorized_canary_metric"))

  canary_metrics.build(
    ["metric:evidence.accepted"],
    [canary_metrics.Count("metric:evidence.accepted", 1)],
    ["copied transcript text"],
  )
  |> should.equal(Error("invalid_canary_metric_proof_ref"))
}

pub fn missing_or_duplicate_authorized_metrics_fail_closed_test() {
  canary_metrics.build(
    ["metric:evidence.accepted", "metric:attention.queued"],
    [canary_metrics.Count("metric:evidence.accepted", 1)],
    ["audit:canary:local-proof"],
  )
  |> should.equal(Error("incomplete_canary_metric_set"))

  canary_metrics.build(
    ["metric:evidence.accepted", "metric:attention.queued"],
    [
      canary_metrics.Count("metric:evidence.accepted", 1),
      canary_metrics.Count("metric:evidence.accepted", 1),
    ],
    ["audit:canary:local-proof"],
  )
  |> should.equal(Error("incomplete_canary_metric_set"))
}
