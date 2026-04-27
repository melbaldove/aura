//// Replay-aware cognitive improvement proposal reports.
////
//// This module does not mutate policy or concern files. It turns correction
//// labels plus current replay outcomes into an auditable proposal artifact so
//// policy changes are grounded in examples, not intuition.

import aura/cognitive_patch
import aura/cognitive_replay
import aura/db
import aura/event
import aura/time
import aura/xdg
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import simplifile

const default_timeout_ms = 120_000

const default_poll_ms = 500

pub type ImproveReport {
  ImproveReport(
    path: String,
    label_count: Int,
    proposal_count: Int,
    passed_count: Int,
    failed_count: Int,
    skipped_count: Int,
    markdown: String,
  )
}

type ImproveGroup {
  ImproveGroup(target_path: String, cases: List(cognitive_replay.CaseResult))
}

/// Run replay for labeled events and write an improvement proposal artifact.
pub fn propose(ctx: cognitive_replay.Context) -> Result(ImproveReport, String) {
  propose_at(ctx, time.now_ms(), default_timeout_ms, default_poll_ms)
}

/// Deterministic entrypoint for tests.
pub fn propose_at(
  ctx: cognitive_replay.Context,
  timestamp_ms: Int,
  timeout_ms: Int,
  poll_ms: Int,
) -> Result(ImproveReport, String) {
  use cases <- result.try(cognitive_replay.run_label_cases_with(
    ctx,
    timeout_ms,
    poll_ms,
  ))

  case cases {
    [] ->
      Ok(ImproveReport(
        path: "",
        label_count: 0,
        proposal_count: 0,
        passed_count: 0,
        failed_count: 0,
        skipped_count: 0,
        markdown: "OK: no cognitive labels found; no improvement proposal generated.",
      ))

    _ -> {
      let groups =
        cases
        |> list.fold([], fn(groups, case_) {
          upsert_group(
            groups,
            cognitive_patch.target_path_for_label(case_.label),
            case_,
          )
        })
        |> list.reverse

      let markdown = render_report(timestamp_ms, ctx, cases, groups)
      let dir = improvement_dir(ctx.paths)
      use _ <- result.try(
        simplifile.create_directory_all(dir)
        |> result.map_error(fn(e) {
          "failed to create cognitive improvement proposal directory "
          <> dir
          <> ": "
          <> string.inspect(e)
        }),
      )
      let path = dir <> "/" <> int.to_string(timestamp_ms) <> ".md"
      use _ <- result.try(
        simplifile.write(path, markdown)
        |> result.map_error(fn(e) {
          "failed to write cognitive improvement proposal "
          <> path
          <> ": "
          <> string.inspect(e)
        }),
      )

      Ok(ImproveReport(
        path: path,
        label_count: list.length(cases),
        proposal_count: list.length(groups),
        passed_count: passed_count(cases),
        failed_count: failed_count(cases),
        skipped_count: skipped_count(cases),
        markdown: markdown,
      ))
    }
  }
}

fn improvement_dir(paths: xdg.Paths) -> String {
  xdg.cognitive_dir(paths) <> "/improvement-proposals"
}

fn upsert_group(
  groups: List(ImproveGroup),
  target_path: String,
  case_: cognitive_replay.CaseResult,
) -> List(ImproveGroup) {
  case groups {
    [] -> [ImproveGroup(target_path: target_path, cases: [case_])]
    [group, ..rest] -> {
      case group.target_path == target_path {
        True -> [ImproveGroup(..group, cases: [case_, ..group.cases]), ..rest]
        False -> [group, ..upsert_group(rest, target_path, case_)]
      }
    }
  }
}

fn render_report(
  timestamp_ms: Int,
  ctx: cognitive_replay.Context,
  cases: List(cognitive_replay.CaseResult),
  groups: List(ImproveGroup),
) -> String {
  "# Cognitive Improvement Proposal\n\n"
  <> "Generated timestamp_ms: "
  <> int.to_string(timestamp_ms)
  <> "\n"
  <> "Source: `labels.jsonl` + live cognitive replay\n"
  <> "Labels: "
  <> int.to_string(list.length(cases))
  <> "\n"
  <> "Replay: passed="
  <> int.to_string(passed_count(cases))
  <> " failed="
  <> int.to_string(failed_count(cases))
  <> " skipped="
  <> int.to_string(skipped_count(cases))
  <> " total="
  <> int.to_string(list.length(cases))
  <> "\n"
  <> "Proposal groups: "
  <> int.to_string(list.length(groups))
  <> "\n\n"
  <> "This is a proposal artifact only. Do not apply changes automatically. "
  <> "Use it to patch ordinary text policy or concern files through the normal "
  <> "approval path, then rerun replay for before/after proof.\n\n"
  <> string.join(
    list.map(groups, fn(group) { render_group(group, ctx) }),
    "\n\n",
  )
}

fn render_group(group: ImproveGroup, ctx: cognitive_replay.Context) -> String {
  let cases = list.reverse(group.cases)

  "## `"
  <> group.target_path
  <> "`\n\n"
  <> "Cases: "
  <> int.to_string(list.length(cases))
  <> " (failed="
  <> int.to_string(failed_count(cases))
  <> ", passed="
  <> int.to_string(passed_count(cases))
  <> ", skipped="
  <> int.to_string(skipped_count(cases))
  <> ")\n\n"
  <> "Patch brief: "
  <> cognitive_patch.patch_brief_for_target(group.target_path)
  <> "\n\n"
  <> "Replay evidence:\n"
  <> string.join(list.map(cases, fn(case_) { render_case(case_, ctx) }), "\n")
}

fn render_case(
  case_: cognitive_replay.CaseResult,
  ctx: cognitive_replay.Context,
) -> String {
  status(case_)
  <> " `"
  <> case_.event_id
  <> "` "
  <> event_summary(ctx.db_subject, case_.event_id)
  <> " | Label: "
  <> blank_dash(case_.label)
  <> " | Actual: attention="
  <> blank_dash(case_.attention_action)
  <> " work="
  <> blank_dash(case_.work_action)
  <> " authority="
  <> blank_dash(case_.authority_required)
  <> " citations="
  <> int.to_string(case_.citation_count)
  <> " gaps="
  <> int.to_string(case_.gap_count)
  <> " | Errors: "
  <> errors(case_.errors)
  <> " | Note: "
  <> blank_dash(case_.note)
}

fn event_summary(
  db_subject: process.Subject(db.DbMessage),
  event_id: String,
) -> String {
  case db.get_event(db_subject, event_id) {
    Ok(option.Some(e)) -> format_event_summary(e)
    Ok(option.None) -> "event not found"
    Error(err) -> "event lookup failed: " <> err
  }
}

fn format_event_summary(e: event.AuraEvent) -> String {
  e.source <> "/" <> e.type_ <> " \"" <> e.subject <> "\""
}

fn status(case_: cognitive_replay.CaseResult) -> String {
  case case_.skipped, case_.passed {
    True, _ -> "SKIP"
    False, True -> "PASS"
    False, False -> "FAIL"
  }
}

fn errors(errors: List(String)) -> String {
  case errors {
    [] -> "-"
    _ -> string.join(errors, "; ")
  }
}

fn passed_count(cases: List(cognitive_replay.CaseResult)) -> Int {
  cases
  |> list.filter(fn(case_) { case_.passed && !case_.skipped })
  |> list.length
}

fn failed_count(cases: List(cognitive_replay.CaseResult)) -> Int {
  cases
  |> list.filter(fn(case_) { !case_.passed && !case_.skipped })
  |> list.length
}

fn skipped_count(cases: List(cognitive_replay.CaseResult)) -> Int {
  cases
  |> list.filter(fn(case_) { case_.skipped })
  |> list.length
}

fn blank_dash(value: String) -> String {
  case string.trim(value) {
    "" -> "-"
    trimmed -> trimmed
  }
}
