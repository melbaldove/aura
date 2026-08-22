//// Bounded acceptance metrics for a separately authorized canary.

import aura/db
import aura/operating_contracts
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// One count for an authorized canary metric identifier.
pub type Count {
  Count(metric_id: String, value: Int)
}

/// A compact metric report. It contains counts and opaque proof references.
pub type Report {
  Report(counts: Dict(String, Int), proof_refs: List(String))
}

/// Build one report from the metric identifiers in immutable authorization.
pub fn build(
  authorized_metric_ids: List(String),
  values: List(Count),
  proof_refs: List(String),
) -> Result(Report, String) {
  let value_metric_ids = list.map(values, fn(value) { value.metric_id })
  let unique_metric_count =
    value_metric_ids
    |> list.map(fn(metric_id) { #(metric_id, Nil) })
    |> dict.from_list
    |> dict.to_list
    |> list.length
  use _ <- result.try(
    case
      list.all(values, fn(value) {
        value.value >= 0
        && list.contains(authorized_metric_ids, value.metric_id)
      })
    {
      True -> Ok(Nil)
      False -> Error("unauthorized_canary_metric")
    },
  )
  use _ <- result.try(
    case
      list.sort(value_metric_ids, by: string.compare)
      == list.sort(authorized_metric_ids, by: string.compare)
      && unique_metric_count == list.length(value_metric_ids)
    {
      True -> Ok(Nil)
      False -> Error("incomplete_canary_metric_set")
    },
  )
  use _ <- result.try(case list.all(proof_refs, valid_proof_ref) {
    True -> Ok(Nil)
    False -> Error("invalid_canary_metric_proof_ref")
  })
  Ok(Report(
    counts: values
      |> list.map(fn(value) { #(value.metric_id, value.value) })
      |> dict.from_list,
    proof_refs:,
  ))
}

/// Build authorized counts from persisted Aura operational records.
pub fn collect(
  db_subject: process.Subject(db.DbMessage),
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> Result(Report, String) {
  use counts <- result.try(db.collect_canary_metrics(
    db_subject,
    authorization.authorization_id,
    authorization.metric_ids,
  ))
  build(
    authorization.metric_ids,
    counts
      |> list.map(fn(value) { Count(value.metric_id, value.value) }),
    ["audit:authorization:" <> authorization.authorization_id],
  )
}

/// Encode the bounded report for local acceptance artifacts.
pub fn encode(report: Report) -> String {
  json.object([
    #(
      "counts",
      report.counts
        |> dict.to_list
        |> list.map(fn(entry) { #(entry.0, json.int(entry.1)) })
        |> json.object,
    ),
    #("proof_refs", json.array(report.proof_refs, of: json.string)),
  ])
  |> json.to_string
}

fn valid_proof_ref(value: String) -> Bool {
  let length = string.length(value)
  length > 0
  && length <= 256
  && string.starts_with(value, "audit:")
  && !string.contains(value, " ")
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}
