import aura/ctl
import aura/db
import aura/google_oauth_client
import aura/operating_contracts
import aura/secret
import aura/test_helpers
import aura/xdg
import gleam/dict
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import simplifile

pub fn main() {
  gleeunit.main()
}

fn submission(source_kind: String) -> String {
  operating_contracts.EvidenceEvent(
    schema_version: 1,
    event_id: "tool-event-1",
    source: "tool-source",
    source_kind: source_kind,
    event_type: "tool.result",
    external_id: option.Some("tool-result-1"),
    resource: dict.from_list([
      #("kind", operating_contracts.StructuredString("tool_result")),
      #("id", operating_contracts.StructuredString("tool-result-1")),
    ]),
    observed_at: 1000,
    summary: "Tool work finished.",
    normalized_data: dict.new(),
    raw_ref: option.Some("opaque://tool/result-1"),
    content_hash: "hash-1",
    provenance: dict.new(),
    candidate_domain_refs: [],
    candidate_concern_refs: [],
    verification_status: "verified",
  )
  |> operating_contracts.encode_evidence_event
}

pub fn tool_result_submission_executes_common_boundary_test() {
  ["codex", "claude", "mcp_tool"]
  |> list.each(fn(source_kind) {
    ctl.process_evidence_submission(
      "tool-result",
      "submit " <> submission(source_kind),
      fn(_) { Ok(db.EvidenceInsert(event_id: "canonical-1", inserted: True)) },
    )
    |> should.equal("QUEUED canonical-1")
  })
}

pub fn tool_result_submission_rejects_connector_source_test() {
  ctl.process_evidence_submission(
    "tool-result",
    "submit " <> submission("connector"),
    fn(_) { Ok(db.EvidenceInsert(event_id: "unexpected", inserted: True)) },
  )
  |> should.equal(
    "ERROR: tool-result source_kind must be codex, claude, or mcp_tool",
  )
}

pub fn monitor_capability_command_returns_only_reference_and_hash_test() {
  let root = "/tmp/aura-ctl-monitor-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let output = ctl.prepare_monitor_capability(paths)
  string.contains(output, "\"ok\":true") |> should.be_true
  string.contains(output, "monitor-capability:sha256:") |> should.be_true
  let assert Ok([filename]) =
    simplifile.get_files(xdg.monitor_capabilities_dir(paths))
  let raw = simplifile.read(filename) |> should.be_ok
  string.contains(output, raw) |> should.be_false
  let _ = simplifile.delete_all([root])
}

pub fn monitor_commands_reject_time_and_transcript_fields_as_json_test() {
  let assert Ok(subject) = db.start(":memory:")
  let paths = xdg.resolve_with_home("/tmp/aura-ctl-monitor-invalid")
  ctl.process_monitor_claim(
    paths,
    subject,
    "{\"schema_version\":1,\"authorization_id\":\"auth:one\",\"monitor_runtime_ref\":\"codex:runtime:one\",\"monitor_id\":\"monitor:one\",\"authority_grants\":[\"attention.read\",\"attention.claim\"],\"lease_ms\":1000,\"requested_at\":1}",
  )
  |> should.equal("{\"ok\":false,\"error\":\"invalid_monitor_command\"}")
  ctl.process_monitor_outcome(
    paths,
    subject,
    "{\"schema_version\":1,\"authorization_id\":\"auth:one\",\"monitor_runtime_ref\":\"codex:runtime:one\",\"outcome_id\":\"outcome:one\",\"queue_id\":\"queue:one\",\"lease_token\":\"lease:one\",\"monitor_id\":\"monitor:one\",\"disposition\":\"acknowledge\",\"defer_until\":null,\"codex_task_ref\":null,\"codex_conversation_ref\":null,\"codex_turn_ref\":null,\"authority_grants\":[\"attention.acknowledge\"],\"transcript\":\"not allowed\"}",
  )
  |> should.equal("{\"ok\":false,\"error\":\"invalid_monitor_command\"}")
}

pub fn google_client_commands_return_secret_free_receipts_and_register_set_test() {
  let root = "/tmp/aura-ctl-google-client-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let assert Ok(subject) = db.start(":memory:")
  let secret_sentinel = "ctl-client-secret-must-not-escape"
  let gmail_source = root <> "/gmail client.json"
  let calendar_source = root <> "/calendar.json"
  let assert Ok(_) =
    secret.atomic_write(
      gmail_source,
      installed_client_json("gmail-ctl", secret_sentinel),
    )
  let assert Ok(_) =
    secret.atomic_write(
      calendar_source,
      installed_client_json("calendar-ctl", secret_sentinel),
    )
  let gmail_hash = google_oauth_client.sha256_file(gmail_source) |> should.be_ok
  let calendar_hash =
    google_oauth_client.sha256_file(calendar_source) |> should.be_ok
  let gmail_output =
    ctl.process_google_oauth_client_command(
      paths,
      subject,
      "google-client install "
        <> google_oauth_client.encode_install_command(
        "gmail",
        gmail_source,
        gmail_hash,
      ),
    )
  let calendar_output =
    ctl.process_google_oauth_client_command(
      paths,
      subject,
      "google-client install "
        <> google_oauth_client.encode_install_command(
        "calendar",
        calendar_source,
        calendar_hash,
      ),
    )
  string.contains(gmail_output, secret_sentinel) |> should.be_false
  string.contains(calendar_output, secret_sentinel) |> should.be_false
  let assert Ok(gmail) =
    google_oauth_client.install_receipt_from_json(gmail_output)
  let assert Ok(calendar) =
    google_oauth_client.install_receipt_from_json(calendar_output)
  let set_output =
    ctl.process_google_oauth_client_command(
      paths,
      subject,
      "google-client-set create "
        <> google_oauth_client.encode_client_set_command(
        gmail.client_ref,
        calendar.client_ref,
      ),
    )
  string.contains(set_output, secret_sentinel) |> should.be_false
  string.contains(set_output, "oauth-client-set:sha256:") |> should.be_true
  string.contains(set_output, "gmail_client_ref") |> should.be_false
  string.contains(set_output, "calendar_client_ref") |> should.be_false
  let _ = simplifile.delete_all([root])
}

pub fn google_client_set_command_recovers_exact_orphan_manifest_test() {
  let root = "/tmp/aura-ctl-google-recover-" <> test_helpers.random_suffix()
  let paths = xdg.resolve_with_home(root)
  let assert Ok(subject) = db.start(":memory:")
  let gmail_source = root <> "/gmail.json"
  let calendar_source = root <> "/calendar.json"
  let assert Ok(_) =
    secret.atomic_write(gmail_source, installed_client_json("gmail", "secret"))
  let assert Ok(_) =
    secret.atomic_write(
      calendar_source,
      installed_client_json("calendar", "secret"),
    )
  let gmail_hash = google_oauth_client.sha256_file(gmail_source) |> should.be_ok
  let calendar_hash =
    google_oauth_client.sha256_file(calendar_source) |> should.be_ok
  let gmail =
    google_oauth_client.install(paths, "gmail", gmail_source, gmail_hash)
    |> should.be_ok
  let calendar =
    google_oauth_client.install(
      paths,
      "calendar",
      calendar_source,
      calendar_hash,
    )
    |> should.be_ok
  let orphan =
    google_oauth_client.create_client_set(
      paths,
      gmail.client_ref,
      calendar.client_ref,
    )
    |> should.be_ok

  let output =
    ctl.process_google_oauth_client_command(
      paths,
      subject,
      "google-client-set create "
        <> google_oauth_client.encode_client_set_command(
        gmail.client_ref,
        calendar.client_ref,
      ),
    )
  output |> should.equal(google_oauth_client.encode_client_set_receipt(orphan))
  let _ = simplifile.delete_all([root])
}

fn installed_client_json(name: String, client_secret: String) -> String {
  "{\"installed\":{\"client_id\":\""
  <> name
  <> ".apps.googleusercontent.com\",\"auth_uri\":\"https://accounts.google.com/o/oauth2/auth\",\"token_uri\":\"https://oauth2.googleapis.com/token\",\"client_secret\":\""
  <> client_secret
  <> "\",\"redirect_uris\":[\"http://localhost\"]}}"
}
