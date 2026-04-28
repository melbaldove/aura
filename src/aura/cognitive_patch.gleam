//// Cognitive patch proposal reports from replay correction labels.
////
//// This module does not apply policy changes. It turns user/operator labels
//// into a durable markdown artifact that a human or model can review before
//// editing ordinary text policy and concern files.

import aura/cognitive_label
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

pub type ProposalReport {
  ProposalReport(
    path: String,
    label_count: Int,
    proposal_count: Int,
    markdown: String,
  )
}

type ProposalCase {
  ProposalCase(
    event_id: String,
    label: String,
    diagnosis: String,
    expected_attention: String,
    note: String,
    event_summary: String,
  )
}

type ProposalGroup {
  ProposalGroup(target_path: String, cases: List(ProposalCase))
}

/// Propose text-policy or concern-file patch briefs from captured labels.
pub fn propose_from_labels(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
) -> Result(ProposalReport, String) {
  propose_from_labels_at(paths, db_subject, time.now_ms())
}

/// Propose patch briefs with an injected timestamp for deterministic tests.
pub fn propose_from_labels_at(
  paths: xdg.Paths,
  db_subject: process.Subject(db.DbMessage),
  timestamp_ms: Int,
) -> Result(ProposalReport, String) {
  use labels <- result.try(cognitive_replay.load_labels(paths))
  case labels {
    [] ->
      Ok(ProposalReport(
        path: "",
        label_count: 0,
        proposal_count: 0,
        markdown: "OK: no cognitive labels found; no patch proposals generated.",
      ))

    _ -> {
      let groups =
        labels
        |> list.fold([], fn(groups, label) {
          let case_ = label_to_case(label, db_subject)
          upsert_group(groups, target_path_for_label(label.label), case_)
        })
        |> list.reverse

      let markdown = render_report(timestamp_ms, labels, groups)
      let dir = proposals_dir(paths)
      use _ <- result.try(
        simplifile.create_directory_all(dir)
        |> result.map_error(fn(e) {
          "failed to create cognitive patch proposal directory "
          <> dir
          <> ": "
          <> string.inspect(e)
        }),
      )
      let path = dir <> "/" <> int.to_string(timestamp_ms) <> ".md"
      use _ <- result.try(
        simplifile.write(path, markdown)
        |> result.map_error(fn(e) {
          "failed to write cognitive patch proposal "
          <> path
          <> ": "
          <> string.inspect(e)
        }),
      )

      Ok(ProposalReport(
        path: path,
        label_count: list.length(labels),
        proposal_count: list.length(groups),
        markdown: markdown,
      ))
    }
  }
}

fn proposals_dir(paths: xdg.Paths) -> String {
  xdg.cognitive_dir(paths) <> "/patch-proposals"
}

fn label_to_case(
  label: cognitive_replay.Label,
  db_subject: process.Subject(db.DbMessage),
) -> ProposalCase {
  ProposalCase(
    event_id: label.event_id,
    label: label.label,
    diagnosis: cognitive_label.diagnosis_for_label(label.label),
    expected_attention: expected_attention(label.attention_any),
    note: label.note,
    event_summary: event_summary(db_subject, label.event_id),
  )
}

fn upsert_group(
  groups: List(ProposalGroup),
  target_path: String,
  case_: ProposalCase,
) -> List(ProposalGroup) {
  case groups {
    [] -> [ProposalGroup(target_path: target_path, cases: [case_])]
    [group, ..rest] -> {
      case group.target_path == target_path {
        True -> [ProposalGroup(..group, cases: [case_, ..group.cases]), ..rest]
        False -> [group, ..upsert_group(rest, target_path, case_)]
      }
    }
  }
}

pub fn target_path_for_label(label: String) -> String {
  case string.lowercase(label) {
    "false_interrupt" | "missed_important" | "bad_deferral" | "useful_digest" ->
      "policies/attention.md"
    "bad_concern_match" -> "policies/concerns.md"
    "bad_authority_call" -> "policies/authority.md"
    "verification_burden_reduced" | "planning_burden_reduced" ->
      "policies/work.md"
    _ -> "policies/learning.md"
  }
}

fn expected_attention(values: List(String)) -> String {
  case values {
    [] -> "unspecified"
    _ -> string.join(values, ", ")
  }
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

fn render_report(
  timestamp_ms: Int,
  labels: List(cognitive_replay.Label),
  groups: List(ProposalGroup),
) -> String {
  "# Cognitive Patch Proposals\n\n"
  <> "Generated timestamp_ms: "
  <> int.to_string(timestamp_ms)
  <> "\n"
  <> "Source: `labels.jsonl`\n"
  <> "Labels: "
  <> int.to_string(list.length(labels))
  <> "\n"
  <> "Proposal groups: "
  <> int.to_string(list.length(groups))
  <> "\n\n"
  <> "This is a proposal artifact only. Do not apply changes automatically. "
  <> "Use it to patch ordinary text policy or concern files through the normal "
  <> "approval path.\n\n"
  <> string.join(list.map(groups, render_group), "\n\n")
}

fn render_group(group: ProposalGroup) -> String {
  let cases = list.reverse(group.cases)

  "## `"
  <> group.target_path
  <> "`\n\n"
  <> "Case count: "
  <> int.to_string(list.length(cases))
  <> "\n\n"
  <> "Patch brief: "
  <> patch_brief(group.target_path, cases)
  <> "\n\n"
  <> "Cases:\n"
  <> string.join(list.map(cases, render_case), "\n")
}

fn render_case(case_: ProposalCase) -> String {
  "- `"
  <> case_.event_id
  <> "` "
  <> case_.event_summary
  <> " | Label: "
  <> blank_dash(case_.label)
  <> " | Expected attention: "
  <> case_.expected_attention
  <> " | Surface: "
  <> blank_dash(case_.diagnosis)
  <> " | Note: "
  <> blank_dash(case_.note)
}

pub fn patch_brief_for_target(target_path: String) -> String {
  case target_path {
    "policies/attention.md" ->
      "Calibrate interruption timing using the labeled cases below. Tighten "
      <> "when similar events should stay record/digest, and clarify when "
      <> "deadline, material risk, or explicit user-decision language should "
      <> "become surface_now or ask_now."
    "policies/concerns.md" ->
      "Clarify how Aura maps events to existing concern files, when a missing "
      <> "concern is itself a gap, and what evidence is enough before creating "
      <> "or updating a durable concern."
    "policies/authority.md" ->
      "Clarify when Aura may proceed autonomously versus when approval, "
      <> "credentials, tools, or human judgment are required."
    "policies/work.md" ->
      "Clarify how Aura should reduce planning or verification burden before "
      <> "asking the user, including what proof packet makes the next human "
      <> "judgment cheaper."
    _ ->
      "Review these labeled cases and decide whether an existing text policy "
      <> "or concern file needs a reusable rule."
  }
}

fn patch_brief(target_path: String, _cases: List(ProposalCase)) -> String {
  patch_brief_for_target(target_path)
}

fn blank_dash(value: String) -> String {
  case string.trim(value) {
    "" -> "-"
    trimmed -> trimmed
  }
}
