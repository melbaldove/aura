import aura/config
import aura/db
import aura/google_oauth_client
import aura/google_oauth_http
import aura/google_oauth_runtime
import aura/oauth
import aura/oauth_loopback
import aura/operating_contracts
import aura/secret
import aura/test_helpers
import aura/time
import aura/xdg
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/string
import gleeunit/should
import simplifile

const gmail_scope = "https://www.googleapis.com/auth/gmail.readonly"

const calendar_scope = "https://www.googleapis.com/auth/calendar.readonly"

pub fn one_shot_runtime_claims_durable_session_without_returning_code_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_test")
  let assert Ok(started) =
    google_oauth_runtime.start_named(
      name,
      subject,
      paths,
      configurations(request),
    )
  let assert Ok(handle) = google_oauth_runtime.begin(started.data, request)
  handle.authorization_url
  |> string.contains("https://accounts.google.com/o/oauth2/auth?")
  |> should.be_true
  handle.authorization_url
  |> string.contains("scope=" <> percent_scope())
  |> should.be_true
  handle.authorization_url
  |> string.contains("prompt=consent")
  |> should.be_true
  handle.authorization_url
  |> string.contains("calendar.readonly")
  |> should.be_false
  handle.authorization_url
  |> string.contains("code=provider-code")
  |> should.be_false

  let state = query_value(handle.authorization_url, "state")
  let host = "127.0.0.1:" <> int.to_string(handle.loopback_port)
  let assert Ok(response) =
    oauth_loopback.request_once(
      handle.loopback_port,
      "GET /callback?state="
        <> state
        <> "&code=provider-code HTTP/1.1\r\nHost: "
        <> host
        <> "\r\n\r\n",
    )
  response |> string.contains("200 OK") |> should.be_true
  response |> string.contains("provider-code") |> should.be_false
  google_oauth_runtime.phase(started.data, handle.session_ref)
  |> should.equal(Ok("callback_claimed"))
  db.claim_google_oauth_session(subject, handle.session_ref)
  |> should.equal(Error("oauth_session_not_waiting"))
  oauth_loopback.request_once(
    handle.loopback_port,
    "GET /callback?state="
      <> state
      <> "&code=again HTTP/1.1\r\nHost: "
      <> host
      <> "\r\n\r\n",
  )
  |> should.be_error
  let _ = simplifile.delete_all([root])
}

pub fn runtime_rejects_caller_configuration_substitution_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_binding_test")
  let assert Ok(started) =
    google_oauth_runtime.start_named(
      name,
      subject,
      paths,
      configurations(request),
    )
  google_oauth_runtime.begin(
    started.data,
    google_oauth_runtime.BeginRequest(
      ..request,
      configuration_hash: hash("caller-substitution"),
    ),
  )
  |> should.equal(Error("oauth_configuration_binding_mismatch"))
  let _ = simplifile.delete_all([root])
}

pub fn calendar_runtime_uses_only_the_calendar_readonly_scope_test() {
  let #(root, paths, subject, request) =
    setup_for(
      "calendar",
      calendar_scope,
      "configuration:calendar-runtime",
      "calendar.events.list",
    )
  let name = process.new_name("google_calendar_oauth_runtime_test")
  let assert Ok(started) =
    google_oauth_runtime.start_named(
      name,
      subject,
      paths,
      configurations_with_scope(request, calendar_scope),
    )
  let assert Ok(handle) = google_oauth_runtime.begin(started.data, request)
  handle.authorization_url
  |> string.contains(
    "scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.readonly",
  )
  |> should.be_true
  handle.authorization_url
  |> string.contains("gmail.readonly")
  |> should.be_false
  let state = query_value(handle.authorization_url, "state")
  let host = "127.0.0.1:" <> int.to_string(handle.loopback_port)
  let assert Ok(_) =
    oauth_loopback.request_once(
      handle.loopback_port,
      "GET /callback?state="
        <> state
        <> "&error=access_denied HTTP/1.1\r\nHost: "
        <> host
        <> "\r\n\r\n",
    )
  let _ = simplifile.delete_all([root])
}

pub fn wrong_state_and_access_denied_are_terminal_without_exchange_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_terminal_test")
  let assert Ok(started) =
    google_oauth_runtime.start_named(
      name,
      subject,
      paths,
      configurations(request),
    )
  let assert Ok(wrong) = google_oauth_runtime.begin(started.data, request)
  let wrong_host = "127.0.0.1:" <> int.to_string(wrong.loopback_port)
  let assert Ok(wrong_response) =
    oauth_loopback.request_once(
      wrong.loopback_port,
      "GET /callback?state=wrong-state&code=code HTTP/1.1\r\nHost: "
        <> wrong_host
        <> "\r\n\r\n",
    )
  wrong_response |> string.contains("400 Bad Request") |> should.be_true
  google_oauth_runtime.phase(started.data, wrong.session_ref) |> should.be_error

  let assert Ok(denied) = google_oauth_runtime.begin(started.data, request)
  let denied_state = query_value(denied.authorization_url, "state")
  let denied_host = "127.0.0.1:" <> int.to_string(denied.loopback_port)
  let assert Ok(denied_response) =
    oauth_loopback.request_once(
      denied.loopback_port,
      "GET /callback?state="
        <> denied_state
        <> "&error=access_denied HTTP/1.1\r\nHost: "
        <> denied_host
        <> "\r\n\r\n",
    )
  denied_response |> string.contains("400 Bad Request") |> should.be_true
  denied_response |> string.contains("access_denied") |> should.be_false
  google_oauth_runtime.phase(started.data, denied.session_ref)
  |> should.be_error
  let _ = simplifile.delete_all([root])
}

pub fn supervised_owner_restart_closes_listener_and_expires_session_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_restart_test")
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(google_oauth_runtime.supervised(
      name,
      subject,
      paths,
      configurations(request),
    ))
    |> static_supervisor.start
  process.unlink(supervisor.pid)
  let stable = process.named_subject(name)
  let assert Ok(handle) = google_oauth_runtime.begin(stable, request)
  let assert Ok(first_pid) = process.named(name)
  process.kill(first_pid)
  process.sleep(100)
  google_oauth_runtime.phase(stable, handle.session_ref) |> should.be_error
  oauth_loopback.request_once(
    handle.loopback_port,
    "GET /callback?state=stale&code=stale HTTP/1.1\r\nHost: 127.0.0.1:"
      <> int.to_string(handle.loopback_port)
      <> "\r\n\r\n",
  )
  |> should.be_error
  let audits =
    db.list_operational_audit(
      subject,
      "connector_oauth_session",
      handle.session_ref,
    )
    |> should.be_ok
  audits
  |> list.any(fn(record) { record.action == "google.oauth.session.expired" })
  |> should.be_true
  process.kill(supervisor.pid)
  let _ = simplifile.delete_all([root])
}

pub fn supervised_owner_restart_fails_a_claimed_code_that_is_no_longer_held_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_claimed_restart_test")
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(google_oauth_runtime.supervised(
      name,
      subject,
      paths,
      configurations(request),
    ))
    |> static_supervisor.start
  process.unlink(supervisor.pid)
  let stable = process.named_subject(name)
  let assert Ok(handle) = google_oauth_runtime.begin(stable, request)
  let state = query_value(handle.authorization_url, "state")
  let host = "127.0.0.1:" <> int.to_string(handle.loopback_port)
  let assert Ok(response) =
    oauth_loopback.request_once(
      handle.loopback_port,
      "GET /callback?state="
        <> state
        <> "&code=claimed-before-restart HTTP/1.1\r\nHost: "
        <> host
        <> "\r\n\r\n",
    )
  response |> string.contains("200 OK") |> should.be_true
  let assert Ok(first_pid) = process.named(name)
  process.kill(first_pid)
  process.sleep(100)
  let audits =
    db.list_operational_audit(
      subject,
      "connector_oauth_session",
      handle.session_ref,
    )
    |> should.be_ok
  audits
  |> list.any(fn(record) {
    record.action == "google.oauth.session.failed_before_effect"
  })
  |> should.be_true
  google_oauth_runtime.phase(stable, handle.session_ref) |> should.be_error
  process.kill(supervisor.pid)
  let _ = simplifile.delete_all([root])
}

pub fn delayed_callback_cannot_claim_after_its_acceptance_deadline_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_deadline_test")
  let assert Ok(started) =
    google_oauth_runtime.start_named_for_test(
      name,
      subject,
      paths,
      configurations(request),
      25,
    )
  let assert Ok(handle) = google_oauth_runtime.begin(started.data, request)
  let assert Ok(_) = google_oauth_runtime.block_for_test(started.data, 75)
  let state = query_value(handle.authorization_url, "state")
  let host = "127.0.0.1:" <> int.to_string(handle.loopback_port)
  let assert Ok(response) =
    oauth_loopback.request_once(
      handle.loopback_port,
      "GET /callback?state="
        <> state
        <> "&code=late-code HTTP/1.1\r\nHost: "
        <> host
        <> "\r\n\r\n",
    )
  response |> string.contains("400 Bad Request") |> should.be_true
  google_oauth_runtime.phase(started.data, handle.session_ref)
  |> should.be_error
  db.claim_google_oauth_session(subject, handle.session_ref)
  |> should.equal(Error("oauth_session_not_waiting"))
  let _ = simplifile.delete_all([root])
}

pub fn database_transition_failure_stops_the_oauth_owner_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_db_failure_test")
  let assert Ok(started) =
    google_oauth_runtime.start_named(
      name,
      subject,
      paths,
      configurations(request),
    )
  let assert Ok(handle) = google_oauth_runtime.begin(started.data, request)
  let assert Ok(other_handle) =
    google_oauth_runtime.begin(started.data, request)
  process.unlink(started.pid)
  let owner_monitor = process.monitor(started.pid)
  process.send(subject, db.Shutdown)
  process.sleep(20)
  let state = query_value(handle.authorization_url, "state")
  let host = "127.0.0.1:" <> int.to_string(handle.loopback_port)
  let _ =
    oauth_loopback.request_once(
      handle.loopback_port,
      "GET /callback?state="
        <> state
        <> "&error=access_denied HTTP/1.1\r\nHost: "
        <> host
        <> "\r\n\r\n",
    )
  process.selector_receive(
    process.new_selector()
      |> process.select_specific_monitor(owner_monitor, fn(down) { down }),
    6000,
  )
  |> should.be_ok
  oauth_loopback.request_once(
    other_handle.loopback_port,
    "GET /callback?state=stale&code=stale HTTP/1.1\r\nHost: 127.0.0.1:"
      <> int.to_string(other_handle.loopback_port)
      <> "\r\n\r\n",
  )
  |> should.be_error
  let _ = simplifile.delete_all([root])
}

pub fn exchange_and_identity_promote_one_exact_private_v2_token_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_exchange_test")
  let calls = process.new_subject()
  let assert Ok(started) =
    google_oauth_runtime.start_named_with_transport_for_test(
      name,
      subject,
      paths,
      configurations(request),
      5000,
      successful_gmail_transport(calls),
    )
  let assert Ok(handle) = google_oauth_runtime.begin(started.data, request)
  submit_code(handle, "one-shot-code") |> should.be_ok
  let receipt =
    google_oauth_runtime.complete_authorization(
      started.data,
      handle.session_ref,
    )
    |> should.be_ok
  receipt.connector_id |> should.equal("gmail")
  string.length(receipt.account_fingerprint) |> should.equal(64)
  let token =
    oauth.load_scoped_token(paths, request.configuration_ref) |> should.be_ok
  token.account_fingerprint |> should.equal(receipt.account_fingerprint)
  token.granted_scope |> should.equal(gmail_scope)
  token.oauth_proof_ref |> should.equal(receipt.oauth_proof_ref)
  token.identity_proof_ref |> should.equal(receipt.identity_proof_ref)
  oauth.load_pending_token(paths, request.configuration_ref) |> should.be_error
  process.receive(calls, 1000) |> should.be_ok
  process.receive(calls, 1000) |> should.be_ok
  google_oauth_runtime.complete_authorization(started.data, handle.session_ref)
  |> should.be_error
  let _ = simplifile.delete_all([root])
}

pub fn production_mode_automatically_completes_claimed_callback_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_auto_complete_test")
  let calls = process.new_subject()
  let assert Ok(started) =
    google_oauth_runtime.start_named_with_auto_transport_for_test(
      name,
      subject,
      paths,
      configurations(request),
      5000,
      successful_gmail_transport(calls),
    )
  let handle = google_oauth_runtime.begin(started.data, request) |> should.be_ok
  submit_code(handle, "auto-one-shot-code") |> should.be_ok
  process.receive(calls, 1000) |> should.be_ok
  process.receive(calls, 1000) |> should.be_ok
  process.sleep(20)
  let token =
    oauth.load_scoped_token(paths, request.configuration_ref) |> should.be_ok
  token.granted_scope |> should.equal(gmail_scope)
  google_oauth_runtime.complete_authorization(started.data, handle.session_ref)
  |> should.be_error
  let _ = simplifile.delete_all([root])
}

pub fn local_pre_intent_failure_terminalizes_the_claimed_session_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_pre_intent_failure_test")
  let calls = process.new_subject()
  let assert Ok(started) =
    google_oauth_runtime.start_named_with_transport_for_test(
      name,
      subject,
      paths,
      configurations(request),
      5000,
      successful_gmail_transport(calls),
    )
  let handle = google_oauth_runtime.begin(started.data, request) |> should.be_ok
  submit_code(handle, "pre-intent-code") |> should.be_ok
  simplifile.delete(google_oauth_client.client_path(
    paths,
    request.oauth_client_ref,
  ))
  |> should.be_ok

  google_oauth_runtime.complete_authorization(started.data, handle.session_ref)
  |> should.be_error
  let audits =
    db.list_operational_audit(
      subject,
      "connector_oauth_session",
      handle.session_ref,
    )
    |> should.be_ok
  audits
  |> list.any(fn(record) {
    record.action == "google.oauth.session.failed_before_effect"
  })
  |> should.be_true
  let _ = simplifile.delete_all([root])
}

pub fn restart_marks_an_unresolved_exchange_intent_effect_unknown_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_intent_restart_test")
  let dispatched = process.new_subject()
  let release = process.new_subject()
  let transport = fn(_request) {
    process.send(dispatched, Nil)
    let _ = process.receive(release, 10_000)
    google_oauth_runtime.BeforeDispatch
  }
  let child =
    supervision.worker(fn() {
      google_oauth_runtime.start_named_with_auto_transport_for_test(
        name,
        subject,
        paths,
        configurations(request),
        5000,
        transport,
      )
    })
    |> supervision.map_data(fn(_) { Nil })
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child)
    |> static_supervisor.start
  process.unlink(supervisor.pid)
  let stable = process.named_subject(name)
  let handle = google_oauth_runtime.begin(stable, request) |> should.be_ok
  submit_code(handle, "crash-after-intent-code") |> should.be_ok
  process.receive(dispatched, 1000) |> should.be_ok
  let effect_id = "effect:oauth:" <> hash(handle.session_ref)
  let assert Ok(Some(intent)) =
    db.get_google_external_effect(subject, effect_id)
  intent.phase |> should.equal("intent")

  let assert Ok(first_pid) = process.named(name)
  process.kill(first_pid)
  process.sleep(100)
  process.is_alive(first_pid) |> should.be_false
  google_oauth_runtime.phase(stable, handle.session_ref) |> should.be_error
  let assert Ok(Some(recovered)) =
    db.get_google_external_effect(subject, effect_id)
  recovered.phase |> should.equal("effect_unknown")
  recovered.error_class |> should.equal("transport_after_dispatch")
  process.receive(dispatched, 50) |> should.be_error
  process.kill(supervisor.pid)
  let _ = simplifile.delete_all([root])
}

pub fn exchange_transport_unknown_consumes_code_and_does_not_retry_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_unknown_test")
  let calls = process.new_subject()
  let assert Ok(started) =
    google_oauth_runtime.start_named_with_transport_for_test(
      name,
      subject,
      paths,
      configurations(request),
      5000,
      fn(request) {
        process.send(calls, request)
        google_oauth_runtime.AfterDispatch
      },
    )
  let assert Ok(handle) = google_oauth_runtime.begin(started.data, request)
  submit_code(handle, "unknown-code") |> should.be_ok
  google_oauth_runtime.complete_authorization(started.data, handle.session_ref)
  |> should.equal(Error("google_oauth_effect_unknown"))
  google_oauth_runtime.complete_authorization(started.data, handle.session_ref)
  |> should.be_error
  process.receive(calls, 1000) |> should.be_ok
  process.receive(calls, 20) |> should.be_error
  oauth.load_scoped_token(paths, request.configuration_ref) |> should.be_error
  let _ = simplifile.delete_all([root])
}

pub fn refresh_keeps_exact_scope_and_rotates_the_private_token_atomically_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_runtime_refresh_test")
  let assert Ok(started) =
    google_oauth_runtime.start_named_with_transport_for_test(
      name,
      subject,
      paths,
      configurations(request),
      5000,
      successful_gmail_transport(process.new_subject()),
    )
  let assert Ok(handle) = google_oauth_runtime.begin(started.data, request)
  submit_code(handle, "refresh-code") |> should.be_ok
  let _ =
    google_oauth_runtime.complete_authorization(
      started.data,
      handle.session_ref,
    )
    |> should.be_ok
  let before =
    oauth.load_scoped_token(paths, request.configuration_ref) |> should.be_ok
  let fresh_calls = process.new_subject()
  google_oauth_runtime.load_or_refresh(
    subject,
    paths,
    configurations(request),
    request.configuration_ref,
    fn(http_request) {
      process.send(fresh_calls, http_request)
      google_oauth_runtime.BeforeDispatch
    },
  )
  |> should.equal(Ok(before))
  process.receive(fresh_calls, 20) |> should.be_error
  let expiring =
    oauth.ScopedTokenSetV2(
      ..before,
      issued_at_ms: before.issued_at_ms + 1,
      expires_at_ms: time.now_ms() + 60_000,
    )
  oauth.replace_scoped_token(paths, before, expiring) |> should.be_ok
  let refresh_calls = process.new_subject()
  let refreshed =
    google_oauth_runtime.load_or_refresh(
      subject,
      paths,
      configurations(request),
      request.configuration_ref,
      fn(http_request) {
        process.send(refresh_calls, http_request)
        google_oauth_runtime.Response(google_oauth_http.HttpResponse(
          200,
          "{\"access_token\":\"rotated-access\",\"token_type\":\"Bearer\",\"expires_in\":3600}",
        ))
      },
    )
    |> should.be_ok
  refreshed.refresh_token |> should.equal(before.refresh_token)
  refreshed.granted_scope |> should.equal(gmail_scope)
  refreshed.token_effect_ref |> should.not_equal(before.token_effect_ref)
  oauth.load_scoped_token(paths, request.configuration_ref)
  |> should.equal(Ok(refreshed))
  process.receive(refresh_calls, 1000) |> should.be_ok

  let second_expiring =
    oauth.ScopedTokenSetV2(
      ..refreshed,
      issued_at_ms: refreshed.issued_at_ms + 1,
      expires_at_ms: time.now_ms() + 60_000,
    )
  oauth.replace_scoped_token(paths, refreshed, second_expiring) |> should.be_ok
  let second_refreshed =
    google_oauth_runtime.load_or_refresh(
      subject,
      paths,
      configurations(request),
      request.configuration_ref,
      fn(_) {
        google_oauth_runtime.Response(google_oauth_http.HttpResponse(
          200,
          "{\"access_token\":\"second-access\",\"token_type\":\"Bearer\",\"expires_in\":3600}",
        ))
      },
    )
    |> should.be_ok
  second_refreshed.token_effect_ref
  |> should.not_equal(refreshed.token_effect_ref)

  let expired_paths = xdg.resolve_with_home(root <> "/expired")
  let now_ms = time.now_ms()
  let expired_effect_id = "effect:refresh:" <> hash("expired-intent")
  let expired_result_hash = hash("expired-result")
  db.begin_google_external_effect(
    subject,
    db.GoogleExternalEffect(
      effect_id: expired_effect_id,
      preparation_authorization_id: before.preparation_authorization_id,
      authorization_id: "",
      activation_id: "",
      configuration_ref: before.configuration_ref,
      configuration_hash: before.configuration_hash,
      connector_id: before.connector_id,
      oauth_client_ref: before.oauth_client_ref,
      oauth_client_hash: before.oauth_client_hash,
      client_set_ref: before.client_set_ref,
      client_set_hash: before.client_set_hash,
      effect_kind: "oauth_refresh",
      logical_effect_key: "refresh:"
        <> hash(
        second_refreshed.configuration_ref
        <> ":"
        <> second_refreshed.token_effect_ref,
      ),
      attempt_number: 1,
      request_hash: hash("expired-refresh-request"),
      phase: "intent",
      proof_ref: "",
      oauth_scope: before.granted_scope,
      account_fingerprint: "",
      result_hash: "",
      error_class: "",
    ),
  )
  |> should.be_ok
  let expired =
    oauth.ScopedTokenSetV2(
      ..second_refreshed,
      token_effect_ref: expired_effect_id,
      token_effect_result_hash: expired_result_hash,
      issued_at_ms: now_ms - 2000,
      expires_at_ms: now_ms - 1000,
    )
  oauth.save_scoped_token(expired_paths, expired) |> should.be_ok
  google_oauth_runtime.load_or_refresh(
    subject,
    expired_paths,
    configurations(request),
    request.configuration_ref,
    fn(_) { google_oauth_runtime.BeforeDispatch },
  )
  |> should.equal(Error("google_oauth_token_expired"))
  let assert Ok(Some(expired_effect)) =
    db.get_google_external_effect(subject, expired_effect_id)
  expired_effect.phase |> should.equal("succeeded")
  let _ = simplifile.delete_all([root])
}

pub fn startup_reconciles_pending_exchange_without_repeating_the_code_post_test() {
  let #(root, paths, subject, request) = setup()
  let pending = seed_pending_exchange(paths, subject, request)
  let calls = process.new_subject()
  let name = process.new_name("google_oauth_pending_recovery_test")
  let assert Ok(_) =
    google_oauth_runtime.start_named_with_transport_for_test(
      name,
      subject,
      paths,
      configurations(request),
      5000,
      fn(http_request) {
        process.send(calls, http_request)
        google_oauth_runtime.Response(google_oauth_http.HttpResponse(
          200,
          "{\"emailAddress\":\"recovered@example.test\"}",
        ))
      },
    )
  let request_seen = process.receive(calls, 1000) |> should.be_ok
  request_seen.method |> should.equal("GET")
  process.receive(calls, 20) |> should.be_error
  oauth.load_pending_token(paths, request.configuration_ref) |> should.be_error
  let recovered =
    oauth.load_scoped_token(paths, request.configuration_ref) |> should.be_ok
  recovered.oauth_result_hash |> should.equal(pending.oauth_result_hash)
  let assert Ok(Some(effect)) =
    db.get_google_external_effect(subject, pending.effect_id)
  effect.phase |> should.equal("succeeded")
  let _ = simplifile.delete_all([root])
}

pub fn startup_reconciles_final_token_before_session_commit_test() {
  let #(root, paths, subject, request) = setup()
  let pending = seed_pending_exchange(paths, subject, request)
  db.finish_google_external_effect(
    subject,
    pending.effect_id,
    "succeeded",
    pending.oauth_proof_ref,
    "",
    pending.oauth_result_hash,
    "",
  )
  |> should.be_ok
  let identity_effect_id =
    "effect:identity:" <> hash(pending.session_ref <> ":1")
  let identity_proof_ref = "proof:identity:" <> hash(identity_effect_id)
  let identity_result_hash = hash("final-identity-result")
  let account_fingerprint =
    oauth.account_fingerprint(
      pending.identity_hmac_key,
      "recovered-final@example.test",
    )
  db.begin_google_external_effect(
    subject,
    db.GoogleExternalEffect(
      effect_id: identity_effect_id,
      preparation_authorization_id: pending.preparation_authorization_id,
      authorization_id: "",
      activation_id: "",
      configuration_ref: pending.configuration_ref,
      configuration_hash: pending.configuration_hash,
      connector_id: pending.connector_id,
      oauth_client_ref: pending.oauth_client_ref,
      oauth_client_hash: pending.oauth_client_hash,
      client_set_ref: pending.client_set_ref,
      client_set_hash: pending.client_set_hash,
      effect_kind: "identity_read",
      logical_effect_key: "identity:" <> hash(pending.session_ref),
      attempt_number: 1,
      request_hash: hash("final-identity-request"),
      phase: "intent",
      proof_ref: "",
      oauth_scope: pending.granted_scope,
      account_fingerprint: "",
      result_hash: "",
      error_class: "",
    ),
  )
  |> should.be_ok
  db.finish_google_external_effect(
    subject,
    identity_effect_id,
    "succeeded",
    identity_proof_ref,
    account_fingerprint,
    identity_result_hash,
    "",
  )
  |> should.be_ok
  let final =
    oauth.ScopedTokenSetV2(
      session_ref: pending.session_ref,
      oauth_effect_ref: pending.effect_id,
      preparation_authorization_id: pending.preparation_authorization_id,
      connector_id: pending.connector_id,
      configuration_ref: pending.configuration_ref,
      configuration_hash: pending.configuration_hash,
      oauth_client_ref: pending.oauth_client_ref,
      oauth_client_hash: pending.oauth_client_hash,
      client_set_ref: pending.client_set_ref,
      client_set_hash: pending.client_set_hash,
      oauth_proof_ref: pending.oauth_proof_ref,
      oauth_result_hash: pending.oauth_result_hash,
      identity_proof_ref:,
      identity_result_hash:,
      token_effect_ref: pending.token_effect_ref,
      token_effect_result_hash: pending.token_effect_result_hash,
      account_fingerprint:,
      granted_scope: pending.granted_scope,
      issued_at_ms: pending.issued_at_ms,
      expires_at_ms: pending.expires_at_ms,
      access_token: pending.access_token,
      refresh_token: pending.refresh_token,
      identity_hmac_key: pending.identity_hmac_key,
    )
  oauth.save_scoped_token(paths, final) |> should.be_ok
  oauth.remove_pending_token(paths, pending) |> should.be_ok
  let calls = process.new_subject()
  let name = process.new_name("google_oauth_final_recovery_test")
  let assert Ok(_) =
    google_oauth_runtime.start_named_with_transport_for_test(
      name,
      subject,
      paths,
      configurations(request),
      5000,
      fn(http_request) {
        process.send(calls, http_request)
        google_oauth_runtime.BeforeDispatch
      },
    )
  process.receive(calls, 20) |> should.be_error
  db.list_operational_audit(
    subject,
    "connector_oauth_session",
    pending.session_ref,
  )
  |> should.be_ok
  |> list.any(fn(record) { record.action == "google.oauth.session.succeeded" })
  |> should.be_true
  let _ = simplifile.delete_all([root])
}

pub fn invalid_identity_is_audited_and_removes_the_pending_secret_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_identity_invalid_test")
  let assert Ok(started) =
    google_oauth_runtime.start_named_with_transport_for_test(
      name,
      subject,
      paths,
      configurations(request),
      5000,
      fn(http_request) {
        case http_request.method {
          "POST" ->
            google_oauth_runtime.Response(google_oauth_http.HttpResponse(
              200,
              "{\"access_token\":\"identity-access\",\"refresh_token\":\"identity-refresh\",\"scope\":\""
                <> gmail_scope
                <> "\",\"token_type\":\"Bearer\",\"expires_in\":3600}",
            ))
          _ ->
            google_oauth_runtime.Response(google_oauth_http.HttpResponse(
              200,
              "{\"unexpected\":true}",
            ))
        }
      },
    )
  let assert Ok(handle) = google_oauth_runtime.begin(started.data, request)
  submit_code(handle, "identity-invalid-code") |> should.be_ok
  google_oauth_runtime.complete_authorization(started.data, handle.session_ref)
  |> should.equal(Error("google_oauth_safe_disable_required"))
  oauth.load_pending_token(paths, request.configuration_ref) |> should.be_error
  oauth.load_scoped_token(paths, request.configuration_ref) |> should.be_error
  let identity_key = "identity:" <> hash(handle.session_ref)
  let assert Ok(Some(effect)) =
    db.get_latest_google_external_effect(subject, identity_key)
  effect.phase |> should.equal("failed_before_effect")
  effect.error_class |> should.equal("identity_mismatch")
  let _ = simplifile.delete_all([root])
}

pub fn identity_effect_unknown_retries_only_the_read_and_promotes_pending_test() {
  let #(root, paths, subject, request) = setup()
  let name = process.new_name("google_oauth_identity_unknown_test")
  let identity_marker = root <> "/identity-attempted"
  let assert Ok(started) =
    google_oauth_runtime.start_named_with_transport_for_test(
      name,
      subject,
      paths,
      configurations(request),
      5000,
      fn(http_request) {
        case http_request.method {
          "POST" ->
            google_oauth_runtime.Response(google_oauth_http.HttpResponse(
              200,
              "{\"access_token\":\"unknown-access\",\"refresh_token\":\"unknown-refresh\",\"scope\":\""
                <> gmail_scope
                <> "\",\"token_type\":\"Bearer\",\"expires_in\":3600}",
            ))
          _ ->
            case simplifile.is_file(identity_marker) {
              Ok(False) -> {
                let assert Ok(_) =
                  simplifile.write(identity_marker, "attempted")
                google_oauth_runtime.AfterDispatch
              }
              _ ->
                google_oauth_runtime.Response(google_oauth_http.HttpResponse(
                  200,
                  "{\"emailAddress\":\"retried@example.test\"}",
                ))
            }
        }
      },
    )
  let assert Ok(handle) = google_oauth_runtime.begin(started.data, request)
  submit_code(handle, "identity-unknown-code") |> should.be_ok
  google_oauth_runtime.complete_authorization(started.data, handle.session_ref)
  |> should.equal(Error("google_identity_effect_unknown"))
  oauth.load_pending_token(paths, request.configuration_ref) |> should.be_ok
  google_oauth_runtime.reconcile_pending(
    started.data,
    request.configuration_ref,
  )
  |> should.be_ok
  oauth.load_pending_token(paths, request.configuration_ref) |> should.be_error
  oauth.load_scoped_token(paths, request.configuration_ref) |> should.be_ok
  let identity_key = "identity:" <> hash(handle.session_ref)
  let assert Ok(Some(effect)) =
    db.get_latest_google_external_effect(subject, identity_key)
  effect.attempt_number |> should.equal(2)
  effect.phase |> should.equal("succeeded")
  let _ = simplifile.delete_all([root])
}

pub fn authorization_expiry_after_exchange_discards_pending_token_test() {
  let #(root, paths, subject, request) =
    setup_for_with_expiry(
      "gmail",
      gmail_scope,
      "configuration:gmail-expiry",
      "gmail.users.getProfile",
      time.now_ms() + 2000,
    )
  let name = process.new_name("google_oauth_runtime_expiry_test")
  let assert Ok(started) =
    google_oauth_runtime.start_named_with_transport_for_test(
      name,
      subject,
      paths,
      configurations(request),
      5000,
      fn(http_request) {
        case http_request.method {
          "POST" -> {
            process.sleep(2100)
            google_oauth_runtime.Response(google_oauth_http.HttpResponse(
              200,
              "{\"access_token\":\"expiry-access\",\"refresh_token\":\"expiry-refresh\",\"scope\":\""
                <> gmail_scope
                <> "\",\"token_type\":\"Bearer\",\"expires_in\":3600}",
            ))
          }
          _ ->
            google_oauth_runtime.Response(google_oauth_http.HttpResponse(
              200,
              "{\"emailAddress\":\"expired@example.test\"}",
            ))
        }
      },
    )
  let assert Ok(handle) = google_oauth_runtime.begin(started.data, request)
  submit_code(handle, "expiry-code") |> should.be_ok
  google_oauth_runtime.complete_authorization(started.data, handle.session_ref)
  |> should.equal(Error("preparation_authorization_expired"))
  oauth.load_pending_token(paths, request.configuration_ref) |> should.be_error
  oauth.load_scoped_token(paths, request.configuration_ref) |> should.be_error
  db.list_operational_audit(
    subject,
    "connector_oauth_session",
    handle.session_ref,
  )
  |> should.be_ok
  |> list.any(fn(record) {
    record.action == "google.oauth.session.failed_before_effect"
  })
  |> should.be_true
  let _ = simplifile.delete_all([root])
}

fn setup() {
  setup_for(
    "gmail",
    gmail_scope,
    "configuration:gmail-runtime",
    "gmail.users.getProfile",
  )
}

fn setup_for(
  connector_id: String,
  scope: String,
  configuration_ref: String,
  identity_endpoint_id: String,
) {
  setup_for_with_expiry(
    connector_id,
    scope,
    configuration_ref,
    identity_endpoint_id,
    9_999_999_999_999,
  )
}

fn setup_for_with_expiry(
  connector_id: String,
  scope: String,
  configuration_ref: String,
  identity_endpoint_id: String,
  expires_at_ms: Int,
) {
  let root = "/tmp/aura-google-oauth-runtime-" <> test_helpers.random_suffix()
  let _ = simplifile.delete_all([root])
  let paths = xdg.resolve_with_home(root)
  let gmail = install(paths, root, "gmail", "gmail-runtime-client")
  let calendar = install(paths, root, "calendar", "calendar-runtime-client")
  let set =
    google_oauth_client.create_client_set(
      paths,
      gmail.client_ref,
      calendar.client_ref,
    )
    |> should.be_ok
  let assert Ok(subject) = db.start(":memory:")
  db.register_google_oauth_client_set(
    subject,
    db.GoogleOAuthClientSet(
      client_set_ref: set.client_set_ref,
      client_set_hash: set.client_set_hash,
      gmail_client_ref: set.gmail_client_ref,
      gmail_client_hash: set.gmail_client_hash,
      calendar_client_ref: set.calendar_client_ref,
      calendar_client_hash: set.calendar_client_hash,
    ),
  )
  |> should.be_ok
  let preparation =
    operating_contracts.CanaryPreparationAuthorizationV1(
      schema_version: 1,
      authorization_id: "authorization:preparation-runtime-test",
      canary_id: "canary:runtime-test",
      oauth_client_ref: set.client_set_ref,
      oauth_client_hash: set.client_set_hash,
      connectors: [
        operating_contracts.PreparationConnectorV1(
          connector_id:,
          configuration_ref:,
          oauth_scope: scope,
          identity_endpoint_id:,
        ),
      ],
      grants: ["connector.identity.read", "oauth.authorize"],
      expires_at_ms:,
      authorized_by_ref: "operator:runtime-test",
    )
  db.create_canary_preparation_authorization(subject, preparation)
  |> should.be_ok
  let request =
    google_oauth_runtime.BeginRequest(
      connector_id:,
      preparation_authorization_id: preparation.authorization_id,
      configuration_ref:,
      configuration_hash: hash(configuration_ref),
      client_set_ref: set.client_set_ref,
      client_set_hash: set.client_set_hash,
      oauth_client_ref: case connector_id {
        "gmail" -> gmail.client_ref
        _ -> calendar.client_ref
      },
      oauth_client_hash: case connector_id {
        "gmail" -> gmail.client_hash
        _ -> calendar.client_hash
      },
    )
  #(root, paths, subject, request)
}

fn install(paths, root: String, connector: String, name: String) {
  let source = root <> "/" <> connector <> ".json"
  let raw =
    "{\"installed\":{\"client_id\":\""
    <> name
    <> ".apps.googleusercontent.com\",\"client_secret\":\"synthetic-client-secret\"}}"
  secret.atomic_write(source, raw) |> should.be_ok
  let digest = google_oauth_client.sha256_file(source) |> should.be_ok
  google_oauth_client.install(paths, connector, source, digest) |> should.be_ok
}

fn configurations(
  request: google_oauth_runtime.BeginRequest,
) -> List(config.ConnectorConfiguration) {
  configurations_with_scope(request, gmail_scope)
}

fn configurations_with_scope(
  request: google_oauth_runtime.BeginRequest,
  scope: String,
) -> List(config.ConnectorConfiguration) {
  [
    config.ConnectorConfiguration(
      configuration_ref: request.configuration_ref,
      connector_id: request.connector_id,
      oauth_client_ref: request.oauth_client_ref,
      credential_ref: "credential:" <> request.connector_id <> "-runtime",
      resource_ref: "resource:" <> request.connector_id <> "-runtime",
      oauth_scope: scope,
      configuration_hash: request.configuration_hash,
    ),
  ]
}

fn successful_gmail_transport(
  calls: process.Subject(google_oauth_http.HttpRequest),
) -> google_oauth_runtime.Transport {
  fn(request) {
    process.send(calls, request)
    case request.method {
      "POST" ->
        google_oauth_runtime.Response(google_oauth_http.HttpResponse(
          200,
          "{\"access_token\":\"synthetic-access\",\"refresh_token\":\"synthetic-refresh\",\"scope\":\""
            <> gmail_scope
            <> "\",\"token_type\":\"Bearer\",\"expires_in\":3600}",
        ))
      _ ->
        google_oauth_runtime.Response(google_oauth_http.HttpResponse(
          200,
          "{\"emailAddress\":\"person@example.test\"}",
        ))
    }
  }
}

fn submit_code(
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

fn seed_pending_exchange(
  paths: xdg.Paths,
  subject: process.Subject(db.DbMessage),
  request: google_oauth_runtime.BeginRequest,
) -> oauth.PendingTokenV1 {
  let session_ref = "oauth-session:pending-recovery"
  let session =
    db.GoogleOAuthSession(
      session_ref:,
      connector_id: request.connector_id,
      preparation_authorization_id: request.preparation_authorization_id,
      configuration_ref: request.configuration_ref,
      configuration_hash: request.configuration_hash,
      oauth_client_ref: request.oauth_client_ref,
      oauth_client_hash: request.oauth_client_hash,
      client_set_ref: request.client_set_ref,
      client_set_hash: request.client_set_hash,
      state_hash: hash("pending-state"),
      pkce_challenge: string.repeat("p", 43),
      redirect_uri: "http://127.0.0.1:49999/callback",
      phase: "waiting",
      expires_at_ms: time.now_ms() + 300_000,
    )
  db.create_google_oauth_session(subject, session) |> should.be_ok
  db.claim_google_oauth_session(subject, session_ref) |> should.be_ok
  let effect_id = "effect:oauth:" <> hash(session_ref)
  let proof_ref = "proof:oauth:" <> hash(effect_id)
  let result_hash = hash("pending-token-result")
  db.begin_google_external_effect(
    subject,
    db.GoogleExternalEffect(
      effect_id:,
      preparation_authorization_id: request.preparation_authorization_id,
      authorization_id: "",
      activation_id: "",
      configuration_ref: request.configuration_ref,
      configuration_hash: request.configuration_hash,
      connector_id: request.connector_id,
      oauth_client_ref: request.oauth_client_ref,
      oauth_client_hash: request.oauth_client_hash,
      client_set_ref: request.client_set_ref,
      client_set_hash: request.client_set_hash,
      effect_kind: "oauth_exchange",
      logical_effect_key: "oauth:" <> hash(session_ref),
      attempt_number: 1,
      request_hash: hash("pending-request"),
      phase: "intent",
      proof_ref: "",
      oauth_scope: gmail_scope,
      account_fingerprint: "",
      result_hash: "",
      error_class: "",
    ),
  )
  |> should.be_ok
  let now_ms = time.now_ms()
  let pending =
    oauth.PendingTokenV1(
      session_ref:,
      effect_id:,
      preparation_authorization_id: request.preparation_authorization_id,
      connector_id: request.connector_id,
      configuration_ref: request.configuration_ref,
      configuration_hash: request.configuration_hash,
      oauth_client_ref: request.oauth_client_ref,
      oauth_client_hash: request.oauth_client_hash,
      client_set_ref: request.client_set_ref,
      client_set_hash: request.client_set_hash,
      oauth_proof_ref: proof_ref,
      oauth_result_hash: result_hash,
      token_effect_ref: effect_id,
      token_effect_result_hash: result_hash,
      granted_scope: gmail_scope,
      issued_at_ms: now_ms,
      expires_at_ms: now_ms + 3_600_000,
      access_token: "pending-access",
      refresh_token: "pending-refresh",
      identity_hmac_key: string.repeat("k", 32),
    )
  oauth.save_pending_token(paths, pending) |> should.be_ok
  pending
}

fn query_value(url: String, name: String) -> String {
  let marker = "&" <> name <> "="
  let assert [_, tail] = string.split(url, marker)
  let assert [value, ..] = string.split(tail, "&")
  value
}

fn percent_scope() -> String {
  "https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgmail.readonly"
}

fn hash(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}
