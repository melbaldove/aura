import aura/cognitive_context
import aura/cognitive_decision
import aura/cognitive_delivery
import aura/cognitive_event
import aura/config
import aura/connector_activation
import aura/connector_adapter
import aura/connector_registry
import aura/ctl
import aura/db
import aura/event_ingest
import aura/google_calendar_runtime
import aura/google_gmail_runtime
import aura/google_http_client
import aura/google_oauth_client
import aura/google_oauth_http
import aura/google_oauth_runtime
import aura/integrations/calendar_api
import aura/integrations/gmail_api
import aura/oauth
import aura/oauth_loopback
import aura/operating_contracts
import aura/secret
import aura/test_helpers
import aura/time
import aura/xdg
import fakes/fake_discord
import fakes/google_http_fault
import fakes/google_http_server
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import gleeunit
import gleeunit/should
import simplifile

const secret_sentinel = "task9-secret-sentinel-must-not-persist"

const transcript_sentinel = "task9-transcript-sentinel-must-not-persist"

const oauth_secret_sentinel = "task9-oauth-secret-sentinel"

const oauth_code_sentinel = "task9-oauth-code-sentinel"

pub fn main() {
  gleeunit.main()
}

pub fn provider_projections_reject_secret_and_transcript_fields_test() {
  gmail_api.decode_metadata_response(
    "{\"id\":\"m1\",\"threadId\":\"t1\",\"historyId\":\"44\",\"internalDate\":\"1000\",\"sizeEstimate\":42,\"payload\":{\"body\":{\"data\":\""
    <> secret_sentinel
    <> "\"},\"headers\":[]}}",
  )
  |> should.equal(Error("gmail_metadata_response_fields_invalid"))
  calendar_api.decode_events_page_response(
    "{\"items\":[{\"id\":\"e1\",\"etag\":\"v1\",\"status\":\"confirmed\",\"summary\":\"safe\",\"start\":{\"dateTime\":\"2026-08-10T09:00:00Z\"},\"end\":{\"dateTime\":\"2026-08-10T09:30:00Z\"},\"updated\":\"2026-08-09T08:00:00Z\",\"eventType\":\"default\",\"transparency\":\"opaque\",\"visibility\":\"default\",\"description\":\""
    <> transcript_sentinel
    <> "\"}]}",
  )
  |> should.equal(Error("calendar_response_fields_invalid"))
}

pub fn complete_local_google_readonly_protocol_flow_test() {
  let root = "/tmp/aura-google-protocol-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([root])
  let paths = xdg.resolve_with_home(root)
  let gmail_client = install_client(paths, root, "gmail")
  let calendar_client = install_client(paths, root, "calendar")
  let client_set =
    google_oauth_client.create_client_set(
      paths,
      gmail_client.client_ref,
      calendar_client.client_ref,
    )
    |> should.be_ok
  let configurations = [
    connector_configuration("gmail", gmail_client.client_ref),
    connector_configuration("calendar", calendar_client.client_ref),
  ]
  let now = time.now_ms()
  let preparation = protocol_preparation(now, client_set)
  let database_path = root <> "/aura.db"
  let db_subject = db.start(database_path) |> should.be_ok
  db.register_google_oauth_client_set(
    db_subject,
    db.GoogleOAuthClientSet(
      client_set_ref: client_set.client_set_ref,
      client_set_hash: client_set.client_set_hash,
      gmail_client_ref: client_set.gmail_client_ref,
      gmail_client_hash: client_set.gmail_client_hash,
      calendar_client_ref: client_set.calendar_client_ref,
      calendar_client_hash: client_set.calendar_client_hash,
    ),
  )
  |> should.be_ok
  db.create_canary_preparation_authorization(db_subject, preparation)
  |> should.be_ok

  let gmail_request =
    oauth_begin_request(
      "gmail",
      preparation,
      gmail_client.client_ref,
      gmail_client.client_hash,
    )
  let gmail_owner_name = process.new_name("google_protocol_gmail_oauth")
  let gmail_owner =
    google_oauth_runtime.start_named_with_transport_for_test(
      gmail_owner_name,
      db_subject,
      paths,
      configurations,
      5000,
      oauth_fake_server_transport(
        "gmail",
        "https://www.googleapis.com/auth/gmail.readonly",
        "{\"emailAddress\":\"person@example.test\"}",
      ),
    )
    |> should.be_ok
  let gmail_handle =
    google_oauth_runtime.begin(gmail_owner.data, gmail_request) |> should.be_ok
  gmail_handle.authorization_url
  |> string.contains(
    "scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgmail.readonly",
  )
  |> should.be_true
  submit_callback(gmail_handle, oauth_code_sentinel <> "-gmail")
  |> should.be_ok
  let gmail_completion =
    google_oauth_runtime.complete_authorization(
      gmail_owner.data,
      gmail_handle.session_ref,
    )
    |> should.be_ok

  let calendar_request =
    oauth_begin_request(
      "calendar",
      preparation,
      calendar_client.client_ref,
      calendar_client.client_hash,
    )
  let calendar_owner_name = process.new_name("google_protocol_calendar_oauth")
  let calendar_owner =
    google_oauth_runtime.start_named_with_transport_for_test(
      calendar_owner_name,
      db_subject,
      paths,
      configurations,
      5000,
      oauth_fake_server_transport(
        "calendar",
        "https://www.googleapis.com/auth/calendar.readonly",
        "{\"id\":\"primary-calendar@example.test\"}",
      ),
    )
    |> should.be_ok
  let calendar_handle =
    google_oauth_runtime.begin(calendar_owner.data, calendar_request)
    |> should.be_ok
  calendar_handle.authorization_url
  |> string.contains(
    "scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.readonly",
  )
  |> should.be_true
  submit_callback(calendar_handle, oauth_code_sentinel <> "-calendar")
  |> should.be_ok
  let calendar_completion =
    google_oauth_runtime.complete_authorization(
      calendar_owner.data,
      calendar_handle.session_ref,
    )
    |> should.be_ok

  secret.secure_read(oauth.scoped_token_path(
    paths,
    gmail_completion.configuration_ref,
  ))
  |> should.be_ok
  secret.secure_read(oauth.scoped_token_path(
    paths,
    calendar_completion.configuration_ref,
  ))
  |> should.be_ok

  let authorization =
    protocol_authorization(
      now,
      preparation,
      gmail_completion,
      calendar_completion,
    )
  db.create_canary_authorization(db_subject, authorization) |> should.be_ok
  connector_activation.prepare_disabled(
    db_subject,
    authorization.authorization_id,
    "google-protocol:prepare",
    authorization.authorized_by_ref,
  )
  |> should.be_ok
  let enabled =
    connector_activation.enable_set(
      db_subject,
      authorization.authorization_id,
      "google-protocol:enable",
      authorization.authorized_by_ref,
      ["connector.enable"],
    )
    |> should.be_ok

  let gmail_token =
    oauth.load_scoped_token(paths, gmail_completion.configuration_ref)
    |> should.be_ok
  oauth.replace_scoped_token(
    paths,
    gmail_token,
    oauth.ScopedTokenSetV2(..gmail_token, expires_at_ms: time.now_ms() + 1000),
  )
  |> should.be_ok
  google_oauth_runtime.load_or_refresh(
    db_subject,
    paths,
    configurations,
    gmail_completion.configuration_ref,
    oauth_fake_server_transport(
      "gmail",
      "https://www.googleapis.com/auth/gmail.readonly",
      "{\"emailAddress\":\"person@example.test\"}",
    ),
  )
  |> should.be_ok

  let ingest = event_ingest.start(db_subject) |> should.be_ok
  let gmail_activation = find_activation(enabled, "gmail")
  google_gmail_runtime.run_once_with_transports_for_test(
    db_subject,
    ingest.data,
    paths,
    configurations,
    authorization.authorization_id,
    gmail_activation.activation_id,
    "attempt:google-protocol-gmail-seed",
    "worker:google-protocol-gmail",
    fn() { google_oauth_runtime.BeforeDispatch },
    fn(_, _, _, _) { Error("unexpected_forced_refresh") },
    gmail_provider_transport,
  )
  |> should.be_ok
  let gmail_receipt =
    google_gmail_runtime.run_once_with_transports_for_test(
      db_subject,
      ingest.data,
      paths,
      configurations,
      authorization.authorization_id,
      gmail_activation.activation_id,
      "attempt:google-protocol-gmail-poll",
      "worker:google-protocol-gmail",
      fn() { google_oauth_runtime.BeforeDispatch },
      fn(_, _, _, _) { Error("unexpected_forced_refresh") },
      gmail_provider_transport,
    )
    |> should.be_ok
  gmail_receipt.evidence_count |> should.equal(1)

  let calendar_activation = find_activation(enabled, "calendar")
  let calendar_receipt =
    google_calendar_runtime.run_once_with_transports_for_test(
      db_subject,
      ingest.data,
      paths,
      configurations,
      authorization.authorization_id,
      calendar_activation.activation_id,
      "attempt:google-protocol-calendar-poll",
      "worker:google-protocol-calendar",
      fn() { google_oauth_runtime.BeforeDispatch },
      fn(_, _, _, _) { Error("unexpected_forced_refresh") },
      calendar_provider_transport,
    )
    |> should.be_ok
  calendar_receipt.evidence_count |> should.equal(2)
  db.get_connector_checkpoint(
    db_subject,
    gmail_completion.configuration_ref,
    gmail_activation.activation_id,
  )
  |> should.be_ok
  |> should.be_some
  db.get_connector_checkpoint(
    db_subject,
    calendar_completion.configuration_ref,
    calendar_activation.activation_id,
  )
  |> should.be_ok
  |> should.be_some

  let gmail_event = expected_gmail_event(gmail_completion.configuration_ref)
  db.get_stored_evidence(db_subject, gmail_event.event_id)
  |> should.be_ok
  |> should.be_some
  let decision = protocol_decision(gmail_event.event_id, authorization)
  cognitive_decision.validate(
    decision,
    protocol_context(gmail_event.event_id, authorization),
  )
  |> should.be_ok
  let #(discord, discord_transport) = fake_discord.new()
  let reports = process.new_subject()
  let delivery =
    cognitive_delivery.start_with_history(
      paths,
      discord_transport,
      [cognitive_delivery.domain_target("personal-life", "must-not-send")],
      [],
      db_subject,
      Some(reports),
    )
    |> should.be_ok
  cognitive_delivery.deliver_authorized(delivery.data, decision, authorization)
  process.receive(reports, 1000)
  |> should.be_ok
  |> fn(report) { report.status }
  |> should.equal(cognitive_delivery.Queued)
  fake_discord.all_events(discord) |> should.equal([])
  let assert [queued] =
    db.list_attention(db_subject, "codex", "pending") |> should.be_ok
  queued.citations
  |> should.equal([
    "evidence:" <> gmail_event.event_id,
    "policy:personal-life-canary:v1",
  ])

  let status_output =
    ctl.process_google_oauth_status(db_subject, gmail_handle.session_ref)
  let report_path = root <> "/generated-google-readonly-report.txt"
  let snapshot_path = root <> "/generated-google-readonly-snapshot.txt"
  simplifile.write(
    report_path,
    status_output
      <> "\n"
      <> string.inspect(#(gmail_receipt, calendar_receipt, queued.queue_id)),
  )
  |> should.be_ok
  simplifile.write(
    snapshot_path,
    string.inspect(#(queued.queue_id, queued.event_refs, queued.citations)),
  )
  |> should.be_ok
  [oauth_secret_sentinel, oauth_code_sentinel]
  |> list.each(fn(value) {
    string.contains(status_output, value) |> should.be_false
    file_contains(report_path, value) |> should.be_false
    file_contains(snapshot_path, value) |> should.be_false
  })

  connector_activation.begin_disable_set(
    db_subject,
    authorization.authorization_id,
    "google-protocol:disable",
    authorization.rollback_owner_ref,
    ["connector.disable"],
  )
  |> should.be_ok
  connector_activation.finalize_disable_set(
    db_subject,
    authorization.authorization_id,
    "google-protocol:disable-finalize",
    authorization.rollback_owner_ref,
  )
  |> should.be_ok
  let calls = process.new_subject()
  google_gmail_runtime.run_once_with_transports_for_test(
    db_subject,
    ingest.data,
    paths,
    configurations,
    authorization.authorization_id,
    gmail_activation.activation_id,
    "attempt:google-protocol-disabled",
    "worker:google-protocol-disabled",
    fn() { google_oauth_runtime.BeforeDispatch },
    fn(_, _, _, _) { Error("unexpected_forced_refresh") },
    fn(_, _, _) {
      process.send(calls, Nil)
      google_http_client.BeforeDispatch("unexpected_provider_call")
    },
  )
  |> should.be_error
  process.receive(calls, 50) |> should.be_error

  process.send(db_subject, db.Shutdown)
  process.sleep(20)
  [database_path, database_path <> "-wal", database_path <> "-shm"]
  |> list.each(fn(path) {
    case simplifile.is_file(path) {
      Ok(True) ->
        [oauth_secret_sentinel, oauth_code_sentinel]
        |> list.each(fn(value) { file_contains(path, value) |> should.be_false })
      _ -> Nil
    }
  })
  let _ = simplifile.delete_all([root])
}

pub fn compact_evidence_contains_only_reviewed_metadata_test() {
  let gmail =
    gmail_api.metadata_to_result(gmail_api.MetadataMessage(
      message_id: "message-1",
      thread_id: "thread-1",
      history_id: "42",
      internal_date_ms: 1000,
      label_ids: ["INBOX"],
      size_estimate: 128,
      subject: "Bounded subject",
      from: "sender@example.test",
    ))
    |> should.be_ok
  let calendar =
    calendar_api.event_to_result(calendar_api.CalendarEvent(
      event_id: "event-1",
      etag: "etag-1",
      status: "confirmed",
      summary: "Bounded event",
      start: "2026-08-10T09:00:00Z",
      end: "2026-08-10T09:30:00Z",
      updated: "2026-08-09T08:00:00Z",
      recurring_event_id: None,
      event_type: "default",
      transparency: "opaque",
      visibility: "default",
      updated_at_ms: 1,
      observed_at_ms: 1,
    ))
    |> should.be_ok
  gmail.scope
  |> should.equal("https://www.googleapis.com/auth/gmail.readonly")
  calendar.scope
  |> should.equal("https://www.googleapis.com/auth/calendar.readonly")
  gmail.candidate_domain_refs |> should.equal([])
  gmail.candidate_concern_refs |> should.equal([])
  calendar.candidate_domain_refs |> should.equal([])
  calendar.candidate_concern_refs |> should.equal([])
  ["body", "raw", "attachment"]
  |> list.each(fn(key) {
    dict.has_key(gmail.normalized_data, key) |> should.be_false
  })
  ["description", "attendees", "attachments", "conference_data"]
  |> list.each(fn(key) {
    dict.has_key(calendar.normalized_data, key) |> should.be_false
  })
}

pub fn erlang_fault_boundary_rejects_oversized_status_before_body_test() {
  let server =
    google_http_server.start(
      "HTTP/1.1 200 " <> string.repeat("x", 1025) <> "\r\n\r\n",
      0,
    )
    |> should.be_ok
  google_http_fault.direct_get(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId",
    "synthetic-access-token",
    server,
  )
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_status_line_too_large",
  ))
}

pub fn erlang_fault_boundary_frames_one_bounded_authenticated_get_test() {
  let server =
    google_http_server.start(
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
      0,
    )
    |> should.be_ok
  google_http_fault.direct_get(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId",
    "synthetic-access-token",
    server,
  )
  |> should.equal(
    google_http_client.Response(google_http_client.HttpResponse(200, 0, "{}")),
  )
  let request = google_http_server.last_request()
  request
  |> string.starts_with(
    "GET /gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId HTTP/1.1\r\n",
  )
  |> should.be_true
  request
  |> string.contains("authorization: Bearer synthetic-access-token\r\n")
  |> should.be_true
}

pub fn erlang_fault_boundary_enforces_absolute_timeout_test() {
  let server =
    google_http_server.start_drip(
      "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
      20,
    )
    |> should.be_ok
  google_http_fault.direct_get_with_timeout(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId",
    "synthetic-access-token",
    server,
    100,
  )
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_request_timeout",
  ))
}

pub fn erlang_fault_boundary_rejects_oversized_chunk_before_allocation_test() {
  let server =
    google_http_server.start(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100001\r\n",
      0,
    )
    |> should.be_ok
  google_http_fault.direct_get(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId",
    "synthetic-access-token",
    server,
  )
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_response_too_large",
  ))
}

pub fn erlang_fault_boundary_reports_disconnect_after_dispatch_test() {
  let server = google_http_server.start("", 0) |> should.be_ok
  google_http_fault.direct_get(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId",
    "synthetic-access-token",
    server,
  )
  |> should.equal(google_http_client.AfterDispatch(
    "google_http_transport_failed",
  ))
}

pub fn checked_in_provider_fixtures_contain_no_task9_sentinel_test() {
  [
    "gmail-profile.json",
    "gmail-history-page-1.json",
    "gmail-history-page-2.json",
    "gmail-message-1.json",
    "gmail-message-2.json",
    "calendar-events-page-1.json",
    "calendar-events-page-2.json",
  ]
  |> list.each(fn(name) {
    let raw = simplifile.read("test/fixtures/google/" <> name) |> should.be_ok
    string.contains(raw, secret_sentinel) |> should.be_false
    string.contains(raw, transcript_sentinel) |> should.be_false
  })
}

fn install_client(paths: xdg.Paths, root: String, connector_id: String) {
  let source = root <> "/" <> connector_id <> "-client.json"
  let raw =
    "{\"installed\":{\"client_id\":\""
    <> connector_id
    <> "-protocol.apps.googleusercontent.com\",\"client_secret\":\""
    <> oauth_secret_sentinel
    <> "-"
    <> connector_id
    <> "\"}}"
  secret.atomic_write(source, raw) |> should.be_ok
  google_oauth_client.install(paths, connector_id, source, secret.sha256(raw))
  |> should.be_ok
}

fn connector_configuration(
  connector_id: String,
  oauth_client_ref: String,
) -> config.ConnectorConfiguration {
  let configuration_ref = "configuration:" <> connector_id <> "-protocol"
  let scope = "https://www.googleapis.com/auth/" <> connector_id <> ".readonly"
  config.ConnectorConfiguration(
    configuration_ref:,
    connector_id:,
    oauth_client_ref:,
    credential_ref: "credential:" <> connector_id <> "-protocol",
    resource_ref: "resource:" <> connector_id <> "-primary",
    oauth_scope: scope,
    configuration_hash: hash(configuration_ref),
  )
}

fn protocol_preparation(
  now: Int,
  client_set: google_oauth_client.ClientSetReceipt,
) -> operating_contracts.CanaryPreparationAuthorizationV1 {
  operating_contracts.CanaryPreparationAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:google-protocol-preparation",
    canary_id: "canary:google-protocol",
    oauth_client_ref: client_set.client_set_ref,
    oauth_client_hash: client_set.client_set_hash,
    connectors: [
      operating_contracts.PreparationConnectorV1(
        connector_id: "calendar",
        configuration_ref: "configuration:calendar-protocol",
        oauth_scope: "https://www.googleapis.com/auth/calendar.readonly",
        identity_endpoint_id: "calendar.calendars.get",
      ),
      operating_contracts.PreparationConnectorV1(
        connector_id: "gmail",
        configuration_ref: "configuration:gmail-protocol",
        oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
        identity_endpoint_id: "gmail.users.getProfile",
      ),
    ],
    grants: ["connector.identity.read", "oauth.authorize"],
    expires_at_ms: now + 900_000,
    authorized_by_ref: "operator:google-protocol",
  )
}

fn oauth_begin_request(
  connector_id: String,
  preparation: operating_contracts.CanaryPreparationAuthorizationV1,
  oauth_client_ref: String,
  oauth_client_hash: String,
) -> google_oauth_runtime.BeginRequest {
  let configuration_ref = "configuration:" <> connector_id <> "-protocol"
  google_oauth_runtime.BeginRequest(
    connector_id:,
    preparation_authorization_id: preparation.authorization_id,
    configuration_ref:,
    configuration_hash: hash(configuration_ref),
    client_set_ref: preparation.oauth_client_ref,
    client_set_hash: preparation.oauth_client_hash,
    oauth_client_ref:,
    oauth_client_hash:,
  )
}

fn oauth_fake_server_transport(
  connector_id: String,
  scope: String,
  identity_body: String,
) -> google_oauth_runtime.Transport {
  fn(request: google_oauth_http.HttpRequest) {
    let body = case request.method {
      "POST" ->
        case string.contains(request.body, "grant_type=refresh_token") {
          True ->
            "{\"access_token\":\""
            <> oauth_secret_sentinel
            <> "-refreshed-"
            <> connector_id
            <> "\",\"scope\":\""
            <> scope
            <> "\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
          False ->
            "{\"access_token\":\""
            <> oauth_secret_sentinel
            <> "-access-"
            <> connector_id
            <> "\",\"refresh_token\":\""
            <> oauth_secret_sentinel
            <> "-refresh-"
            <> connector_id
            <> "\",\"scope\":\""
            <> scope
            <> "\",\"token_type\":\"Bearer\",\"expires_in\":3600}"
        }
      _ -> identity_body
    }
    let origin = start_json_response(body)
    let outcome = case request.method {
      "POST" -> google_http_server.execute_post(request, 1, origin)
      _ -> {
        let assert [#("authorization", authorization)] = request.headers
        let token = string.drop_start(authorization, string.length("Bearer "))
        google_http_server.execute_get(
          case connector_id {
            "gmail" -> google_http_client.GmailIdentity
            _ -> google_http_client.CalendarIdentity
          },
          request.url,
          token,
          1,
          origin,
        )
      }
    }
    transport_outcome(outcome)
  }
}

fn transport_outcome(
  outcome: google_http_client.Outcome,
) -> google_oauth_runtime.TransportOutcome {
  case outcome {
    google_http_client.BeforeDispatch(_) -> google_oauth_runtime.BeforeDispatch
    google_http_client.AfterDispatch(_) -> google_oauth_runtime.AfterDispatch
    google_http_client.Response(response) ->
      google_oauth_runtime.Response(google_oauth_http.HttpResponse(
        response.status,
        response.body,
      ))
  }
}

fn submit_callback(
  handle: google_oauth_runtime.AuthorizationHandle,
  code: String,
) -> Result(String, String) {
  let state = query_value(handle.authorization_url, "state")
  let host = "127.0.0.1:" <> int.to_string(handle.loopback_port)
  oauth_loopback.request_once(
    handle.loopback_port,
    "GET /callback?state="
      <> state
      <> "&code="
      <> code
      <> " HTTP/1.1\r\nHost: "
      <> host
      <> "\r\n\r\n",
  )
}

fn query_value(url: String, key: String) -> String {
  let assert Ok(parsed) = uri.parse(url)
  let assert Some(query) = parsed.query
  query
  |> string.split("&")
  |> list.find_map(fn(pair) {
    case string.split_once(pair, "=") {
      Ok(#(found, value)) if found == key -> uri.percent_decode(value)
      _ -> Error(Nil)
    }
  })
  |> should.be_ok
}

fn protocol_authorization(
  now: Int,
  preparation: operating_contracts.CanaryPreparationAuthorizationV1,
  gmail: google_oauth_runtime.CompletionReceipt,
  calendar: google_oauth_runtime.CompletionReceipt,
) -> operating_contracts.CanaryAuthorizationV1 {
  operating_contracts.CanaryAuthorizationV1(
    schema_version: 1,
    authorization_id: "authorization:google-protocol",
    preparation_authorization_id: preparation.authorization_id,
    canary_id: preparation.canary_id,
    domain_id: "domain:personal-life",
    concern_id: "concern:domain:personal-life:google-awareness",
    policy_refs: ["policy:personal-life-canary:v1"],
    connectors: [
      protocol_connector("calendar", calendar),
      protocol_connector("gmail", gmail),
    ],
    activation_grants: ["connector.disable", "connector.enable"],
    monitor_id: "monitor:google-protocol",
    monitor_capability_hash: hash("google-protocol-capability"),
    monitor_runtime_ref: "codex:runtime:google-protocol",
    monitor_prompt_hash: hash("google-protocol-prompt"),
    monitor_interval_ms: 60_000,
    monitor_grants: ["attention.claim", "attention.read"],
    attention_owner: "codex",
    attention_target: "codex_monitor",
    discord_delivery_allowed: False,
    starts_at_ms: now - 1000,
    ends_at_ms: now + 600_000,
    metric_ids: ["metric:evidence.accepted"],
    metric_review_owner_ref: "operator:google-protocol-metrics",
    authorized_by_ref: "operator:google-protocol",
    rollback_owner_ref: "operator:google-protocol-rollback",
  )
}

fn protocol_connector(
  connector_id: String,
  completion: google_oauth_runtime.CompletionReceipt,
) -> operating_contracts.AuthorizedConnectorV1 {
  let capability = case connector_id {
    "gmail" -> "mail.read"
    _ -> "calendar.read"
  }
  operating_contracts.AuthorizedConnectorV1(
    connector_id:,
    activation_id: "activation:" <> connector_id <> "-protocol",
    configuration_ref: completion.configuration_ref,
    configuration_hash: hash(completion.configuration_ref),
    account_fingerprint: completion.account_fingerprint,
    oauth_proof_ref: completion.oauth_proof_ref,
    identity_proof_ref: completion.identity_proof_ref,
    oauth_scope: "https://www.googleapis.com/auth/"
      <> connector_id
      <> ".readonly",
    capability:,
    retention_policy_ref: "retention:" <> connector_id <> "-compact",
    poll_interval_ms: 60_000,
    max_pages_per_poll: 2,
    max_items_per_poll: 4,
    max_response_bytes: 100_000,
  )
}

fn find_activation(
  values: List(operating_contracts.ConnectorActivationV1),
  connector_id: String,
) -> operating_contracts.ConnectorActivationV1 {
  list.find(values, fn(value) { value.connector_id == connector_id })
  |> should.be_ok
}

fn gmail_provider_transport(
  guard: google_http_client.ReadGuard,
  url: String,
  attempt_number: Int,
) -> google_http_client.Outcome {
  let body = case string.contains(url, "/profile?") {
    True -> fixture("gmail-profile.json")
    False ->
      case string.contains(url, "/history?") {
        True ->
          "{\"history\":[{\"messagesAdded\":[{\"message\":{\"id\":\"message-1\"}}]}],\"historyId\":\"101\"}"
        False -> fixture("gmail-message-1.json")
      }
  }
  execute_provider_get(guard, url, attempt_number, body)
}

fn calendar_provider_transport(
  guard: google_http_client.ReadGuard,
  url: String,
  attempt_number: Int,
) -> google_http_client.Outcome {
  let body = case string.contains(url, "pageToken=page-2") {
    True -> fixture("calendar-events-page-2.json")
    False -> fixture("calendar-events-page-1.json")
  }
  execute_provider_get(guard, url, attempt_number, body)
}

fn execute_provider_get(
  guard: google_http_client.ReadGuard,
  url: String,
  attempt_number: Int,
  body: String,
) -> google_http_client.Outcome {
  google_http_server.execute_get(
    guard,
    url,
    oauth_secret_sentinel <> "-provider-access",
    attempt_number,
    start_json_response(body),
  )
}

fn start_json_response(body: String) -> String {
  google_http_server.start(
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
      <> int.to_string(string.byte_size(body))
      <> "\r\n\r\n"
      <> body,
    0,
  )
  |> should.be_ok
}

fn fixture(name: String) -> String {
  simplifile.read("test/fixtures/google/" <> name) |> should.be_ok
}

fn expected_gmail_event(
  configuration_ref: String,
) -> operating_contracts.EvidenceEvent {
  let connector_result =
    fixture("gmail-message-1.json")
    |> gmail_api.decode_metadata_response
    |> should.be_ok
    |> gmail_api.metadata_to_result
    |> should.be_ok
  connector_adapter.normalize(
    protocol_registry("gmail", "mail.read", configuration_ref),
    connector_result,
  )
  |> should.be_ok
}

fn protocol_registry(
  connector_id: String,
  capability: String,
  configuration_ref: String,
) -> connector_registry.Registry {
  connector_registry.build(
    [
      connector_registry.ConnectorDescriptor(
        schema_version: 1,
        connector_id:,
        display_name: connector_id,
        source_kind: "connector",
        capabilities: [capability],
        scopes: [
          "https://www.googleapis.com/auth/" <> connector_id <> ".readonly",
        ],
        descriptor_provenance_ref: "descriptor://aura/"
          <> connector_id
          <> "-readonly/v1",
        summary_limit: 512,
        value_limit: 1024,
        read_authority_ref: None,
        write_authority_ref: None,
        policy_boundary_ref: "policy://aura/evidence/v1",
      ),
    ],
    [
      connector_registry.ConnectorActivation(
        schema_version: 1,
        connector_id:,
        state: "enabled",
        configuration_ref:,
      ),
    ],
  )
  |> should.be_ok
}

fn protocol_context(
  event_id: String,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> cognitive_context.ContextPacket {
  cognitive_context.ContextPacket(
    observation: cognitive_event.Observation(
      id: event_id,
      source: "connector:gmail",
      resource_id: "message:message-1",
      resource_type: "gmail_message",
      event_type: "gmail.message.metadata_observed",
      event_time_ms: 1_770_000_000_000,
      actors: [],
      tags: dict.new(),
      text: "Synthetic reminder",
      state_before: "",
      state_after: "",
      raw_ref: "gmail://message/message-1",
      raw_data: "{}",
    ),
    evidence: cognitive_event.EvidenceBundle(
      observation_id: event_id,
      atoms: [
        cognitive_event.EvidenceAtom(
          id: event_id,
          kind: "metadata_summary",
          value: "Synthetic reminder",
          source_path: "summary",
          text_span: "",
          confidence: 1.0,
          provenance: "connector:gmail",
        ),
      ],
      resource_refs: [],
      raw_refs: [],
    ),
    policies: [
      cognitive_context.PolicyFile(
        name: "Personal Life canary",
        path: "policies/personal-life-canary.md",
        source_ref: "policy:personal-life-canary:v1",
        content: "Surface the current verified signal.",
      ),
    ],
    context_files: [],
    concerns: [
      cognitive_context.ConcernFile(
        name: "Google awareness",
        path: "concerns/google-awareness.md",
        source_ref: authorization.concern_id,
        content: "Review current verified personal signals.",
      ),
    ],
    delivery_targets: ["domain:personal-life"],
    digest_windows: [],
    current_local_time: "2026-08-10T09:00:00+08:00",
    recent_decisions: "",
  )
}

fn protocol_decision(
  event_id: String,
  authorization: operating_contracts.CanaryAuthorizationV1,
) -> cognitive_decision.DecisionEnvelope {
  cognitive_decision.DecisionEnvelope(
    event_id:,
    concern_refs: [authorization.concern_id],
    summary: "A verified personal signal needs review.",
    citations: [
      "evidence:" <> event_id,
      "policy:personal-life-canary:v1",
    ],
    attention: cognitive_decision.AttentionDecision(
      action: "surface_now",
      rationale: "The verified policy condition is true.",
      why_now: "The verified signal is current.",
      deferral_cost: "A later review can miss the window.",
      why_not_digest: "The window closes before the digest.",
    ),
    work: cognitive_decision.WorkDecision(
      action: "prepare",
      target: "personal review context",
      proof_required: "stored evidence is cited",
    ),
    authority: cognitive_decision.AuthorityDecision(
      required: "human_judgment",
      reason: "The user owns the decision.",
    ),
    delivery: cognitive_decision.DeliveryDecision(
      target: "domain:personal-life",
      rationale: "Use the selected domain context.",
    ),
    gaps: [],
    proposed_patches: [],
  )
}

fn file_contains(path: String, value: String) -> Bool {
  case simplifile.read(path) {
    Ok(raw) -> string.contains(raw, value)
    Error(_) -> False
  }
}

fn hash(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}
