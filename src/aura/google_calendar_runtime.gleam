//// Production Google Calendar read-only poll composition.
////
//// This module owns the immutable time window, bounded pagination, exact
//// metadata projection, and atomic evidence/checkpoint handoff. It cannot
//// infer a domain or concern and it cannot deliver a user message.

import aura/config
import aura/connector_activation
import aura/connector_adapter
import aura/connector_registry
import aura/db
import aura/event_ingest
import aura/google_http_client
import aura/google_oauth_http
import aura/google_oauth_runtime
import aura/integrations/calendar_api
import aura/oauth
import aura/operating_contracts
import aura/time
import aura/xdg
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri

const calendar_scope = "https://www.googleapis.com/auth/calendar.readonly"

const calendar_fields = "nextPageToken,items(id,etag,status,summary,start(date,dateTime),end(date,dateTime),updated,recurringEventId,eventType,transparency,visibility)"

const read_lease_ms = 300_000

/// One test provider transport. It receives no credential.
pub type ProviderTransport =
  fn(google_http_client.ReadGuard, String, Int) -> google_http_client.Outcome

type SecretProviderTransport =
  fn(google_http_client.ReadGuard, String, String, Int) ->
    google_http_client.Outcome

/// One complete Calendar runtime result.
pub type RunReceipt {
  RunReceipt(
    attempt_id: String,
    evidence_count: Int,
    page_count: Int,
    next_due_at_ms: Int,
  )
}

type CalendarAuthority {
  CalendarAuthority(
    connector: operating_contracts.AuthorizedConnectorV1,
    authorization: operating_contracts.CanaryAuthorizationV1,
    time_min: String,
    time_max: String,
    max_results: Int,
  )
}

type PageBatch {
  PageBatch(
    events: List(calendar_api.CalendarEvent),
    page_count: Int,
    response_bytes: Int,
  )
}

fn production_transport(
  guard: google_http_client.ReadGuard,
  url: String,
  access_token: String,
  attempt_number: Int,
) -> google_http_client.Outcome {
  google_http_client.get(guard, url, access_token, attempt_number)
}

/// Execute one OAuth token request through the production HTTPS boundary.
pub fn production_oauth_transport(
  request: google_oauth_http.HttpRequest,
) -> google_oauth_runtime.TransportOutcome {
  case google_http_client.post(request, 1) {
    google_http_client.BeforeDispatch(_) -> google_oauth_runtime.BeforeDispatch
    google_http_client.AfterDispatch(_) -> google_oauth_runtime.AfterDispatch
    google_http_client.Response(response) ->
      google_oauth_runtime.Response(google_oauth_http.HttpResponse(
        status: response.status,
        body: response.body,
      ))
  }
}

/// Reserve and run one production Calendar read for one exact activation.
pub fn run_once(
  db_subject: Subject(db.DbMessage),
  ingest_subject: Subject(event_ingest.IngestMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  authorization_id: String,
  activation_id: String,
  attempt_id: String,
  worker_id: String,
) -> Result(RunReceipt, String) {
  run_once_internal(
    db_subject,
    ingest_subject,
    paths,
    configurations,
    authorization_id,
    activation_id,
    attempt_id,
    worker_id,
    production_oauth_transport,
    fn(configuration_ref, attempt_id, worker_id, attempt_version) {
      google_oauth_runtime.refresh_after_unauthorized(
        db_subject,
        paths,
        configurations,
        configuration_ref,
        attempt_id,
        worker_id,
        attempt_version,
        production_oauth_transport,
      )
      |> result.map(fn(_) { Nil })
    },
    production_transport,
  )
}

/// Run one Calendar read with credential-free local test transports.
pub fn run_once_with_transports_for_test(
  db_subject: Subject(db.DbMessage),
  ingest_subject: Subject(event_ingest.IngestMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  authorization_id: String,
  activation_id: String,
  attempt_id: String,
  worker_id: String,
  refresh_transport: fn() -> google_oauth_runtime.TransportOutcome,
  force_refresh: fn(String, String, String, Int) -> Result(Nil, String),
  provider_transport: ProviderTransport,
) -> Result(RunReceipt, String) {
  run_once_internal(
    db_subject,
    ingest_subject,
    paths,
    configurations,
    authorization_id,
    activation_id,
    attempt_id,
    worker_id,
    fn(_) { refresh_transport() },
    force_refresh,
    fn(guard, url, _, attempt) { provider_transport(guard, url, attempt) },
  )
}

fn run_once_internal(
  db_subject: Subject(db.DbMessage),
  ingest_subject: Subject(event_ingest.IngestMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  authorization_id: String,
  activation_id: String,
  attempt_id: String,
  worker_id: String,
  oauth_transport: google_oauth_runtime.Transport,
  force_refresh: fn(String, String, String, Int) -> Result(Nil, String),
  provider_transport: SecretProviderTransport,
) -> Result(RunReceipt, String) {
  use stored <- result.try(db.get_canary_authorization(
    db_subject,
    authorization_id,
  ))
  use authorization <- result.try(case stored {
    Some(value) -> Ok(value.authorization)
    None -> Error("calendar_authorization_not_found")
  })
  use authority <- result.try(calendar_authority(authorization, activation_id))
  use attempt <- result.try(db.reserve_connector_read(
    db_subject,
    attempt_id,
    activation_id,
    authorization_id,
    worker_id,
    read_lease_ms,
  ))
  use _ <- result.try(db.begin_connector_read(
    db_subject,
    attempt.attempt_id,
    worker_id,
  ))
  let token_result =
    load_bound_token(
      db_subject,
      paths,
      configurations,
      authority,
      oauth_transport,
    )
  use token <- result.try(case token_result {
    Ok(value) -> Ok(value)
    Error(error) -> {
      let _ =
        db.finish_connector_read(
          db_subject,
          attempt.attempt_id,
          worker_id,
          "failed",
          safe_error(error),
        )
      Error(error)
    }
  })
  let context = submission_context(authority, attempt, worker_id)
  let first_result =
    run_started(
      db_subject,
      ingest_subject,
      calendar_registry(authority.connector.configuration_ref),
      authority,
      context,
      token,
      provider_transport,
    )
  let final_result = case first_result {
    Error(error) ->
      case string.ends_with(error, "_unauthorized") {
        True ->
          retry_after_unauthorized(
            db_subject,
            ingest_subject,
            paths,
            authority,
            context,
            attempt.attempt_version + 1,
            force_refresh,
            provider_transport,
          )
        False -> first_result
      }
    Ok(_) -> first_result
  }
  case final_result {
    Ok(receipt) -> Ok(receipt)
    Error(error) ->
      case failure_already_recorded(error) {
        True -> Error(error)
        False ->
          case record_runtime_failure(db_subject, authority, context, error) {
            Ok(_) -> Error(error)
            Error(_) -> Error("calendar_failure_record_failed")
          }
      }
  }
}

fn retry_after_unauthorized(
  db_subject: Subject(db.DbMessage),
  ingest_subject: Subject(event_ingest.IngestMessage),
  paths: xdg.Paths,
  authority: CalendarAuthority,
  context: operating_contracts.ConnectorSubmissionContext,
  expected_attempt_version: Int,
  force_refresh: fn(String, String, String, Int) -> Result(Nil, String),
  provider_transport: SecretProviderTransport,
) -> Result(RunReceipt, String) {
  use _ <- result.try(force_refresh(
    authority.connector.configuration_ref,
    context.attempt_id,
    context.worker_id,
    expected_attempt_version,
  ))
  use refreshed <- result.try(oauth.load_calendar_token(
    paths,
    authority.connector.configuration_ref,
  ))
  use _ <- result.try(validate_token(refreshed, authority))
  run_started(
    db_subject,
    ingest_subject,
    calendar_registry(authority.connector.configuration_ref),
    authority,
    context,
    refreshed,
    provider_transport,
  )
}

fn load_bound_token(
  db_subject: Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  authority: CalendarAuthority,
  oauth_transport: google_oauth_runtime.Transport,
) -> Result(oauth.ScopedTokenSetV2, String) {
  use current <- result.try(oauth.load_calendar_token(
    paths,
    authority.connector.configuration_ref,
  ))
  use _ <- result.try(validate_token(current, authority))
  use refreshed <- result.try(google_oauth_runtime.load_or_refresh(
    db_subject,
    paths,
    configurations,
    authority.connector.configuration_ref,
    oauth_transport,
  ))
  use _ <- result.try(validate_token(refreshed, authority))
  Ok(refreshed)
}

fn run_started(
  db_subject: Subject(db.DbMessage),
  ingest_subject: Subject(event_ingest.IngestMessage),
  registry: connector_registry.Registry,
  authority: CalendarAuthority,
  context: operating_contracts.ConnectorSubmissionContext,
  token: oauth.ScopedTokenSetV2,
  transport: SecretProviderTransport,
) -> Result(RunReceipt, String) {
  use checkpoint <- result.try(db.get_connector_checkpoint(
    db_subject,
    authority.connector.configuration_ref,
    authority.connector.activation_id,
  ))
  use batch <- result.try(fetch_pages(
    db_subject,
    authority,
    context,
    token,
    "",
    transport,
    [],
    [],
    0,
    0,
  ))
  use values <- result.try(list.try_map(
    batch.events,
    calendar_api.event_to_result,
  ))
  let next_due_at_ms = time.now_ms() + authority.connector.poll_interval_ms
  use submitted <- result.try(connector_adapter.submit_batch_with_checkpoint(
    registry,
    ingest_subject,
    context,
    values,
    db.CalendarPollCheckpoint(
      configuration_ref: authority.connector.configuration_ref,
      activation_id: authority.connector.activation_id,
      expected_version: case checkpoint {
        None -> 0
        Some(value) -> value.version
      },
      next_due_at_ms:,
    ),
  ))
  use _ <- result.try(case submitted {
    Some(_) -> Ok(Nil)
    None -> Error("calendar_activation_not_effective")
  })
  Ok(RunReceipt(
    attempt_id: context.attempt_id,
    evidence_count: list.length(values),
    page_count: batch.page_count,
    next_due_at_ms:,
  ))
}

fn fetch_pages(
  db_subject: Subject(db.DbMessage),
  authority: CalendarAuthority,
  context: operating_contracts.ConnectorSubmissionContext,
  token: oauth.ScopedTokenSetV2,
  page_token: String,
  transport: SecretProviderTransport,
  seen_tokens: List(String),
  events: List(calendar_api.CalendarEvent),
  page_count: Int,
  response_bytes: Int,
) -> Result(PageBatch, String) {
  use effective <- result.try(connector_activation.load_effective(
    db_subject,
    context.activation_id,
    context.authorization_id,
  ))
  use _ <- result.try(case effective {
    Some(value) if value.version == context.activation_version -> Ok(Nil)
    _ -> Error("calendar_activation_not_effective")
  })
  use _ <- result.try(
    case page_token == "" || !list.contains(seen_tokens, page_token) {
      True -> Ok(Nil)
      False -> Error("calendar_page_token_cycle")
    },
  )
  use _ <- result.try(case page_count < authority.connector.max_pages_per_poll {
    True -> Ok(Nil)
    False -> Error("calendar_page_limit_exceeded")
  })
  let url = events_url(authority, page_token)
  use response <- result.try(expect_response(
    dispatch_get(
      transport,
      google_http_client.CalendarEvents(
        authority.time_min,
        authority.time_max,
        authority.max_results,
      ),
      url,
      token.access_token,
      page_count + 1,
    ),
    "calendar_events",
  ))
  let next_bytes = response_bytes + string.byte_size(response.body)
  use _ <- result.try(
    case next_bytes <= authority.connector.max_response_bytes {
      True -> Ok(Nil)
      False -> Error("calendar_response_limit_exceeded")
    },
  )
  use page <- result.try(calendar_api.decode_events_page_response(response.body))
  let next_events = list.append(events, page.events)
  use _ <- result.try(
    case list.length(next_events) <= authority.connector.max_items_per_poll {
      True -> Ok(Nil)
      False -> Error("calendar_item_limit_exceeded")
    },
  )
  case page.next_page_token {
    "" ->
      Ok(PageBatch(
        events: next_events,
        page_count: page_count + 1,
        response_bytes: next_bytes,
      ))
    next ->
      fetch_pages(
        db_subject,
        authority,
        context,
        token,
        next,
        transport,
        case page_token {
          "" -> seen_tokens
          current -> [current, ..seen_tokens]
        },
        next_events,
        page_count + 1,
        next_bytes,
      )
  }
}

fn dispatch_get(
  transport: SecretProviderTransport,
  guard: google_http_client.ReadGuard,
  url: String,
  access_token: String,
  attempt_number: Int,
) -> google_http_client.Outcome {
  case google_http_client.validate_get_request(guard, url, attempt_number) {
    Ok(_) -> transport(guard, url, access_token, attempt_number)
    Error(error) -> google_http_client.BeforeDispatch(error)
  }
}

fn expect_response(
  outcome: google_http_client.Outcome,
  operation: String,
) -> Result(google_http_client.HttpResponse, String) {
  case outcome {
    google_http_client.BeforeDispatch(_) ->
      Error(operation <> "_before_dispatch")
    google_http_client.AfterDispatch(_) ->
      Error(operation <> "_external_read_unknown")
    google_http_client.Response(response)
      if response.status >= 200 && response.status < 300
    -> Ok(response)
    google_http_client.Response(response) ->
      Error(provider_response_error(response, operation))
  }
}

fn provider_response_error(
  response: google_http_client.HttpResponse,
  operation: String,
) -> String {
  case response.status {
    403 ->
      case
        string.contains(response.body, "ACCESS_TOKEN_SCOPE_INSUFFICIENT")
        || string.contains(response.body, "insufficientPermissions")
      {
        True -> operation <> "_scope_insufficient"
        False ->
          case
            string.contains(response.body, "rateLimitExceeded")
            || string.contains(response.body, "userRateLimitExceeded")
            || string.contains(response.body, "quotaExceeded")
          {
            True ->
              with_retry(operation <> "_rate_limited", response.retry_after_ms)
            False -> operation <> "_forbidden"
          }
      }
    401 -> operation <> "_unauthorized"
    429 -> with_retry(operation <> "_rate_limited", response.retry_after_ms)
    value if value >= 500 ->
      with_retry(operation <> "_provider_unavailable", response.retry_after_ms)
    _ -> operation <> "_provider_rejected"
  }
}

fn record_runtime_failure(
  db_subject: Subject(db.DbMessage),
  authority: CalendarAuthority,
  context: operating_contracts.ConnectorSubmissionContext,
  error: String,
) -> Result(Nil, String) {
  let base_error = provider_error_code(error)
  use _ <- result.try(case string.ends_with(base_error, "_scope_insufficient") {
    True ->
      connector_activation.begin_disable_set(
        db_subject,
        authority.authorization.authorization_id,
        "connector-scope-disable:" <> context.attempt_id,
        authority.authorization.rollback_owner_ref,
        ["connector.disable"],
      )
      |> result.map(fn(_) { Nil })
    False -> Ok(Nil)
  })
  let error_class = runtime_error_class(base_error)
  let retry_at_ms = time.now_ms() + provider_retry_delay_ms(error)
  case error_class {
    "external_read_unknown" ->
      db.record_connector_read_failure(
        db_subject,
        context,
        retry_at_ms,
        error_class,
        True,
      )
      |> result.map(fn(_) { Nil })
    "before_dispatch"
    | "provider_unauthorized"
    | "provider_rate_limited"
    | "provider_unavailable" ->
      db.record_connector_read_failure(
        db_subject,
        context,
        retry_at_ms,
        error_class,
        False,
      )
      |> result.map(fn(_) { Nil })
    _ ->
      db.finish_connector_read(
        db_subject,
        context.attempt_id,
        context.worker_id,
        "failed",
        error_class,
      )
  }
}

fn with_retry(error: String, retry_after_ms: Int) -> String {
  error <> "@" <> int.to_string(bounded_retry_delay_ms(retry_after_ms))
}

fn provider_error_code(error: String) -> String {
  case string.split_once(error, "@") {
    Ok(#(code, _)) -> code
    Error(_) -> error
  }
}

fn provider_retry_delay_ms(error: String) -> Int {
  case string.split_once(error, "@") {
    Ok(#(_, encoded)) ->
      encoded
      |> int.parse
      |> result.unwrap(60_000)
      |> bounded_retry_delay_ms
    Error(_) -> 60_000
  }
}

fn bounded_retry_delay_ms(value: Int) -> Int {
  case value {
    value if value < 1000 -> 1000
    value if value > 3_600_000 -> 3_600_000
    value -> value
  }
}

fn runtime_error_class(error: String) -> String {
  case string.ends_with(error, "_external_read_unknown") {
    True -> "external_read_unknown"
    False ->
      case string.ends_with(error, "_before_dispatch") {
        True -> "before_dispatch"
        False ->
          case string.ends_with(error, "_unauthorized") {
            True -> "provider_unauthorized"
            False ->
              case string.ends_with(error, "_scope_insufficient") {
                True -> "provider_forbidden"
                False ->
                  case string.ends_with(error, "_forbidden") {
                    True -> "provider_forbidden"
                    False ->
                      case string.ends_with(error, "_rate_limited") {
                        True -> "provider_rate_limited"
                        False ->
                          case
                            string.ends_with(error, "_provider_unavailable")
                          {
                            True -> "provider_unavailable"
                            False -> "provider_invalid_response"
                          }
                      }
                  }
              }
          }
      }
  }
}

fn failure_already_recorded(error: String) -> Bool {
  error == "idempotency_conflict"
  || error == "calendar_activation_not_effective"
}

fn calendar_authority(
  authorization: operating_contracts.CanaryAuthorizationV1,
  activation_id: String,
) -> Result(CalendarAuthority, String) {
  use connector <- result.try(
    authorization.connectors
    |> list.find(fn(value) {
      value.connector_id == "calendar" && value.activation_id == activation_id
    })
    |> result.map_error(fn(_) { "calendar_authority_not_found" }),
  )
  case
    connector.oauth_scope == calendar_scope
    && connector.capability == "calendar.read"
    && connector.max_pages_per_poll > 0
    && connector.max_pages_per_poll <= 16
    && connector.max_items_per_poll > 0
    && connector.max_items_per_poll <= 100
    && connector.max_response_bytes > 0
    && connector.max_response_bytes <= 1_048_576
    && authorization.ends_at_ms > authorization.starts_at_ms
  {
    True ->
      Ok(CalendarAuthority(
        connector:,
        authorization:,
        time_min: time.format_ms_rfc3339_utc(authorization.starts_at_ms),
        time_max: time.format_ms_rfc3339_utc(authorization.ends_at_ms),
        max_results: connector.max_items_per_poll,
      ))
    False -> Error("calendar_authority_invalid")
  }
}

fn calendar_registry(configuration_ref: String) -> connector_registry.Registry {
  let assert Ok(registry) =
    connector_registry.build(
      [
        connector_registry.ConnectorDescriptor(
          schema_version: 1,
          connector_id: "calendar",
          display_name: "Calendar",
          source_kind: "connector",
          capabilities: ["calendar.read"],
          scopes: [calendar_scope],
          descriptor_provenance_ref: "descriptor://aura/calendar-readonly/v1",
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
          connector_id: "calendar",
          state: "enabled",
          configuration_ref:,
        ),
      ],
    )
  registry
}

fn validate_token(
  token: oauth.ScopedTokenSetV2,
  authority: CalendarAuthority,
) -> Result(Nil, String) {
  case
    token.connector_id == "calendar"
    && token.configuration_ref == authority.connector.configuration_ref
    && token.configuration_hash == authority.connector.configuration_hash
    && token.account_fingerprint == authority.connector.account_fingerprint
    && token.granted_scope == calendar_scope
    && token.oauth_proof_ref == authority.connector.oauth_proof_ref
    && token.identity_proof_ref == authority.connector.identity_proof_ref
  {
    True -> Ok(Nil)
    False -> Error("calendar_token_authority_mismatch")
  }
}

fn submission_context(
  authority: CalendarAuthority,
  attempt: db.ConnectorReadAttempt,
  worker_id: String,
) -> operating_contracts.ConnectorSubmissionContext {
  operating_contracts.ConnectorSubmissionContext(
    activation_id: authority.connector.activation_id,
    activation_version: attempt.activation_version,
    authorization_id: authority.authorization.authorization_id,
    attempt_id: attempt.attempt_id,
    worker_id:,
    connector_id: "calendar",
    capability: "calendar.read",
    oauth_scope: calendar_scope,
    configuration_hash: authority.connector.configuration_hash,
    account_fingerprint: authority.connector.account_fingerprint,
    domain_id: authority.authorization.domain_id,
    concern_id: authority.authorization.concern_id,
  )
}

fn events_url(authority: CalendarAuthority, page_token: String) -> String {
  let base =
    "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&showDeleted=true&timeMin="
    <> uri.percent_encode(authority.time_min)
    <> "&timeMax="
    <> uri.percent_encode(authority.time_max)
    <> "&maxResults="
    <> int.to_string(authority.max_results)
    <> "&fields="
    <> uri.percent_encode(calendar_fields)
  case page_token {
    "" -> base
    value -> base <> "&pageToken=" <> uri.percent_encode(value)
  }
}

fn safe_error(value: String) -> String {
  case
    value != ""
    && string.byte_size(value) <= 128
    && !string.contains(value, " ")
    && !string.contains(value, "\n")
    && !string.contains(value, "\r")
  {
    True -> value
    False -> "calendar_runtime_failed"
  }
}
