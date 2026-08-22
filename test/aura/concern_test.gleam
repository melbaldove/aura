import aura/concern
import aura/db
import aura/test_helpers
import aura/xdg
import gleam/erlang/process
import gleam/list
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

pub fn audited_start_writes_compact_intent_and_outcome_test() {
  let assert Ok(db_subject) = db.start(":memory:")
  let #(base, paths) = temp_paths("concern-audit")

  concern.apply_with_audit(paths, db_subject, request("start", "cics-342"))
  |> should.be_ok

  let audit =
    db.list_operational_audit(db_subject, "concern", "cics-342")
    |> should.be_ok
  audit
  |> list.map(fn(row) { row.action })
  |> should.equal(["concern.start.intent", "concern.start.outcome"])
  audit
  |> list.any(fn(row) {
    row.action |> string.contains("Payment Reconciliation")
  })
  |> should.be_false

  process.send(db_subject, db.Shutdown)
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

pub fn legacy_concern_remains_readable_until_explicit_domain_migration_test() {
  let #(base, paths) = temp_paths("concern-legacy-migration")
  concern.apply(paths, request("start", "monthly-close")) |> should.be_ok

  let legacy =
    concern.load_for_domain(paths, "personal-life", "monthly-close")
    |> should.be_ok
  legacy.source_ref |> should.equal("concerns/monthly-close.md")
  simplifile.is_file(
    xdg.domain_concerns_dir(paths, "personal-life") <> "/monthly-close.md",
  )
  |> should.equal(Ok(False))

  concern.migrate_legacy(paths, "monthly-close", "personal-life")
  |> should.be_ok
  simplifile.is_file(xdg.concerns_dir(paths) <> "/monthly-close.md")
  |> should.equal(Ok(True))
  let migrated =
    concern.load_for_domain(paths, "personal-life", "monthly-close")
    |> should.be_ok
  migrated.source_ref
  |> should.equal("domains/personal-life/concerns/monthly-close.md")

  let _ = simplifile.delete_all([base])
  Nil
}

pub fn legacy_migration_requires_explicit_target_domain_test() {
  let #(base, paths) = temp_paths("concern-migration-target")
  concern.apply(paths, request("start", "monthly-close")) |> should.be_ok

  concern.migrate_legacy(paths, "monthly-close", "")
  |> should.equal(Error("target_domain_required"))

  let _ = simplifile.delete_all([base])
  Nil
}
