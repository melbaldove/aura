import aura/concern
import aura/test_helpers
import aura/xdg
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

fn temp_paths(label: String) -> #(String, xdg.Paths) {
  let base = "/tmp/aura-" <> label <> "-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([base])
  #(base, xdg.resolve_with_home(base))
}

fn request(action: String, slug: String) -> concern.TrackRequest {
  concern.TrackRequest(
    action: action,
    slug: slug,
    title: "CICS-342 Payment Reconciliation",
    summary: "Payment reconciliation follow-up is active.",
    why: "Blocked reconciliation can carry incorrect payment state forward.",
    current_state: "Needs triage and owner confirmation.",
    watch_signals: "Status changes, assignee changes, rollback requests.",
    evidence: "Jira CICS-342",
    authority: "Human approval required for production rollback.",
    gaps: "Rollback runbook is not yet linked.",
    note: "Initial tracking note.",
  )
}

pub fn start_creates_markdown_file_test() {
  let #(base, paths) = temp_paths("concern-start")

  let result =
    concern.apply(paths, request("start", "cics-342")) |> should.be_ok
  result.status |> should.equal("active")
  result.source_ref |> should.equal("concerns/cics-342.md")

  let content =
    simplifile.read(xdg.concerns_dir(paths) <> "/cics-342.md")
    |> should.be_ok
  content
  |> string.contains("# CICS-342 Payment Reconciliation")
  |> should.be_true
  content |> string.contains("Status: active") |> should.be_true
  content |> string.contains("## Watch Signals") |> should.be_true
  content |> string.contains("Jira CICS-342") |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn invalid_slug_rejected_test() {
  let #(base, paths) = temp_paths("concern-invalid-slug")

  concern.apply(paths, request("start", "../cics-342")) |> should.be_error
  simplifile.is_file(xdg.concerns_dir(paths) <> "/../cics-342.md")
  |> should.equal(Ok(False))

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn update_requires_existing_concern_test() {
  let #(base, paths) = temp_paths("concern-update-missing")

  concern.apply(paths, request("update", "cics-342")) |> should.be_error
  simplifile.is_file(xdg.concerns_dir(paths) <> "/cics-342.md")
  |> should.equal(Ok(False))

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn close_marks_existing_concern_closed_test() {
  let #(base, paths) = temp_paths("concern-close")
  let _ = concern.apply(paths, request("start", "cics-342")) |> should.be_ok

  let close_request =
    concern.TrackRequest(
      ..request("close", "cics-342"),
      note: "Resolved by rollback approval and reconciliation catch-up.",
    )
  let result = concern.apply(paths, close_request) |> should.be_ok
  result.status |> should.equal("closed")

  let content =
    simplifile.read(xdg.concerns_dir(paths) <> "/cics-342.md")
    |> should.be_ok
  content |> string.contains("Status: closed") |> should.be_true
  content
  |> string.contains("[close] Resolved by rollback approval")
  |> should.be_true

  let _ = simplifile.delete_all([base])
  Nil
}
