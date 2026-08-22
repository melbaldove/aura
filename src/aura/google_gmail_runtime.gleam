//// Production Gmail read-only poll composition.
////
//// This module owns the profile cursor seed, bounded history pagination,
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
import aura/integrations/gmail_api
import aura/oauth
import aura/operating_contracts
import aura/secret
import aura/time
import aura/xdg
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

const gmail_scope = "https://www.googleapis.com/auth/gmail.readonly"

const profile_url = "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress%2ChistoryId"

const history_fields = "history(messagesAdded(message(id,threadId,labelIds,historyId))),nextPageToken,historyId"

const metadata_fields = "id,threadId,labelIds,historyId,internalDate,sizeEstimate,payload(headers)"

const read_lease_ms = 300_000

/// One test provider transport. It receives no credential.
pub type ProviderTransport =
  fn(google_http_client.ReadGuard, String, Int) -> google_http_client.Outcome

type SecretProviderTransport =
  fn(google_http_client.ReadGuard, String, String, Int) ->
    google_http_client.Outcome

/// One complete Gmail runtime result.
pub type RunReceipt {
  RunReceipt(
    attempt_id: String,
    checkpoint_history_id: String,
    evidence_count: Int,
    missing_count: Int,
    initialized: Bool,
  )
}

type GmailAuthority {
  GmailAuthority(
    connector: operating_contracts.AuthorizedConnectorV1,
    authorization: operating_contracts.CanaryAuthorizationV1,
  )
}

type PollBatch {
  PollBatch(
    messages: List(gmail_api.MetadataMessage),
    history_id: String,
    response_bytes: Int,
    missing_count: Int,
  )
}

/// Execute one Gmail read through the production HTTPS boundary.
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

/// Reserve and run one production Gmail read for one exact activation.
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

/// Run one Gmail read with credential-free local test transports.
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
    None -> Error("gmail_authorization_not_found")
  })
  use authority <- result.try(gmail_authority(authorization, activation_id))
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
      gmail_registry(),
      authority,
      context,
      token,
      provider_transport,
    )
  let final_result = case first_result {
    Error(error) ->
      case string.ends_with(error, "_unauthorized") {
        True ->
          case
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
          {
            Ok(receipt) -> Ok(receipt)
            Error(_) -> Error(error)
          }
        False -> first_result
      }
    Ok(_) -> first_result
  }
  case final_result {
    Ok(receipt) -> Ok(receipt)
    Error(error) -> {
      case failure_already_recorded(error) {
        True -> Error(error)
        False ->
          case record_runtime_failure(db_subject, authority, context, error) {
            Ok(_) -> Error(error)
            Error(_) -> Error("gmail_failure_record_failed")
          }
      }
    }
  }
}

fn retry_after_unauthorized(
  db_subject: Subject(db.DbMessage),
  ingest_subject: Subject(event_ingest.IngestMessage),
  paths: xdg.Paths,
  authority: GmailAuthority,
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
  use refreshed <- result.try(oauth.load_scoped_token(
    paths,
    authority.connector.configuration_ref,
  ))
  use _ <- result.try(validate_token(refreshed, authority))
  run_started(
    db_subject,
    ingest_subject,
    gmail_registry(),
    authority,
    context,
    refreshed,
    provider_transport,
  )
}

fn failure_already_recorded(error: String) -> Bool {
  error == "idempotency_conflict" || error == "gmail_activation_not_effective"
}

fn load_bound_token(
  db_subject: Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  authority: GmailAuthority,
  oauth_transport: google_oauth_runtime.Transport,
) -> Result(oauth.ScopedTokenSetV2, String) {
  use current <- result.try(oauth.load_scoped_token(
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
  authority: GmailAuthority,
  context: operating_contracts.ConnectorSubmissionContext,
  token: oauth.ScopedTokenSetV2,
  transport: SecretProviderTransport,
) -> Result(RunReceipt, String) {
  use checkpoint <- result.try(db.get_connector_checkpoint(
    db_subject,
    token.configuration_ref,
    context.activation_id,
  ))
  case checkpoint {
    None ->
      initialize_checkpoint(
        ingest_subject,
        registry,
        context,
        authority,
        token,
        transport,
      )
    Some(value) if value.gap_code != "" -> Error("gmail_checkpoint_gap_active")
    Some(value) ->
      poll_checkpoint(
        ingest_subject,
        registry,
        context,
        authority,
        token,
        value,
        transport,
      )
  }
}

fn initialize_checkpoint(
  ingest_subject: Subject(event_ingest.IngestMessage),
  registry: connector_registry.Registry,
  context: operating_contracts.ConnectorSubmissionContext,
  authority: GmailAuthority,
  token: oauth.ScopedTokenSetV2,
  transport: SecretProviderTransport,
) -> Result(RunReceipt, String) {
  use response <- result.try(expect_response(
    dispatch_get(
      transport,
      google_http_client.Gmail,
      profile_url,
      token.access_token,
      1,
    ),
    "gmail_profile",
  ))
  use profile <- result.try(gmail_api.decode_profile_response(response.body))
  use seed <- result.try(gmail_api.profile_seed(
    profile,
    token.identity_hmac_key,
  ))
  use _ <- result.try(
    case seed.account_fingerprint == context.account_fingerprint {
      True -> Ok(Nil)
      False -> Error("gmail_account_fingerprint_mismatch")
    },
  )
  use submitted <- result.try(connector_adapter.submit_batch_with_checkpoint(
    registry,
    ingest_subject,
    context,
    [],
    db.GmailHistoryCheckpoint(
      configuration_ref: authority.connector.configuration_ref,
      activation_id: authority.connector.activation_id,
      expected_version: 0,
      history_id: seed.history_id,
    ),
  ))
  use _ <- result.try(require_submission(submitted))
  Ok(RunReceipt(
    attempt_id: context.attempt_id,
    checkpoint_history_id: seed.history_id,
    evidence_count: 0,
    missing_count: 0,
    initialized: True,
  ))
}

fn poll_checkpoint(
  ingest_subject: Subject(event_ingest.IngestMessage),
  registry: connector_registry.Registry,
  context: operating_contracts.ConnectorSubmissionContext,
  authority: GmailAuthority,
  token: oauth.ScopedTokenSetV2,
  checkpoint: db.ConnectorCheckpoint,
  transport: SecretProviderTransport,
) -> Result(RunReceipt, String) {
  let batch_result =
    fetch_history_pages(
      authority,
      token,
      checkpoint.cursor_value,
      "",
      transport,
      [],
      [],
      0,
      0,
      0,
    )
  case batch_result {
    Error("gmail_history_checkpoint_unavailable") -> {
      use submitted <- result.try(
        connector_adapter.submit_batch_with_checkpoint(
          registry,
          ingest_subject,
          context,
          [],
          db.GmailHistoryGap(
            configuration_ref: authority.connector.configuration_ref,
            activation_id: authority.connector.activation_id,
            expected_version: checkpoint.version,
            reason_code: "history_unavailable",
            prior_history_hash: secret.sha256(checkpoint.cursor_value),
          ),
        ),
      )
      use _ <- result.try(require_submission(submitted))
      Ok(RunReceipt(
        attempt_id: context.attempt_id,
        checkpoint_history_id: "",
        evidence_count: 0,
        missing_count: 0,
        initialized: False,
      ))
    }
    Error(error) -> Error(error)
    Ok(batch) ->
      submit_poll_batch(
        ingest_subject,
        registry,
        context,
        authority,
        checkpoint,
        batch,
      )
  }
}

fn submit_poll_batch(
  ingest_subject: Subject(event_ingest.IngestMessage),
  registry: connector_registry.Registry,
  context: operating_contracts.ConnectorSubmissionContext,
  authority: GmailAuthority,
  checkpoint: db.ConnectorCheckpoint,
  batch: PollBatch,
) -> Result(RunReceipt, String) {
  use values <- result.try(list.try_map(
    batch.messages,
    gmail_api.metadata_to_result,
  ))
  let update = case batch.missing_count {
    0 ->
      db.GmailHistoryCheckpoint(
        configuration_ref: authority.connector.configuration_ref,
        activation_id: authority.connector.activation_id,
        expected_version: checkpoint.version,
        history_id: batch.history_id,
      )
    count ->
      db.GmailHistoryCheckpointWithMissing(
        configuration_ref: authority.connector.configuration_ref,
        activation_id: authority.connector.activation_id,
        expected_version: checkpoint.version,
        history_id: batch.history_id,
        missing_count: count,
      )
  }
  use submitted <- result.try(connector_adapter.submit_batch_with_checkpoint(
    registry,
    ingest_subject,
    context,
    values,
    update,
  ))
  use _ <- result.try(require_submission(submitted))
  Ok(RunReceipt(
    attempt_id: context.attempt_id,
    checkpoint_history_id: batch.history_id,
    evidence_count: list.length(values),
    missing_count: batch.missing_count,
    initialized: False,
  ))
}

fn fetch_history_pages(
  authority: GmailAuthority,
  token: oauth.ScopedTokenSetV2,
  start_history_id: String,
  page_token: String,
  transport: SecretProviderTransport,
  seen_ids: List(String),
  messages: List(gmail_api.MetadataMessage),
  page_count: Int,
  response_bytes: Int,
  missing_count: Int,
) -> Result(PollBatch, String) {
  use _ <- result.try(case page_count < authority.connector.max_pages_per_poll {
    True -> Ok(Nil)
    False -> Error("gmail_history_page_limit_exceeded")
  })
  let url =
    history_url(
      start_history_id,
      page_token,
      authority.connector.max_items_per_poll,
    )
  let outcome =
    dispatch_get(
      transport,
      google_http_client.Gmail,
      url,
      token.access_token,
      page_count + 1,
    )
  use response <- result.try(case outcome {
    google_http_client.Response(response) if response.status == 404 ->
      Error("gmail_history_checkpoint_unavailable")
    _ -> expect_response(outcome, "gmail_history")
  })
  let next_bytes = response_bytes + string.byte_size(response.body)
  use _ <- result.try(
    case next_bytes <= authority.connector.max_response_bytes {
      True -> Ok(Nil)
      False -> Error("gmail_poll_response_limit_exceeded")
    },
  )
  use page <- result.try(gmail_api.decode_history_page_response(response.body))
  use selected <- result.try(select_unseen(
    page.message_added_ids,
    seen_ids,
    authority.connector.max_items_per_poll,
  ))
  use metadata <- result.try(fetch_metadata(
    authority,
    token,
    selected.0,
    transport,
    messages,
    next_bytes,
    missing_count,
    page_count + 1,
  ))
  case page.next_page_token {
    "" ->
      Ok(PollBatch(
        messages: metadata.0,
        history_id: page.history_id,
        response_bytes: metadata.1,
        missing_count: metadata.2,
      ))
    next ->
      fetch_history_pages(
        authority,
        token,
        start_history_id,
        next,
        transport,
        selected.1,
        metadata.0,
        page_count + 1,
        metadata.1,
        metadata.2,
      )
  }
}

fn fetch_metadata(
  authority: GmailAuthority,
  token: oauth.ScopedTokenSetV2,
  identifiers: List(String),
  transport: SecretProviderTransport,
  messages: List(gmail_api.MetadataMessage),
  response_bytes: Int,
  missing_count: Int,
  attempt_number: Int,
) -> Result(#(List(gmail_api.MetadataMessage), Int, Int), String) {
  case identifiers {
    [] -> Ok(#(messages, response_bytes, missing_count))
    [identifier, ..rest] -> {
      case
        list.any(messages, fn(message) { message.message_id == identifier })
      {
        True ->
          fetch_metadata(
            authority,
            token,
            rest,
            transport,
            messages,
            response_bytes,
            missing_count,
            attempt_number,
          )
        False ->
          fetch_one_metadata(
            authority,
            token,
            identifier,
            rest,
            transport,
            messages,
            response_bytes,
            missing_count,
            attempt_number,
          )
      }
    }
  }
}

fn select_unseen(
  identifiers: List(String),
  seen: List(String),
  maximum: Int,
) -> Result(#(List(String), List(String)), String) {
  use selected <- result.try(
    identifiers
    |> list.try_fold(#([], seen), fn(acc, identifier) {
      case list.contains(acc.1, identifier) {
        True -> Ok(acc)
        False ->
          case list.length(acc.1) < maximum {
            True -> Ok(#([identifier, ..acc.0], [identifier, ..acc.1]))
            False -> Error("gmail_history_item_limit_exceeded")
          }
      }
    }),
  )
  Ok(#(list.reverse(selected.0), selected.1))
}

fn fetch_one_metadata(
  authority: GmailAuthority,
  token: oauth.ScopedTokenSetV2,
  identifier: String,
  rest: List(String),
  transport: SecretProviderTransport,
  messages: List(gmail_api.MetadataMessage),
  response_bytes: Int,
  missing_count: Int,
  attempt_number: Int,
) -> Result(#(List(gmail_api.MetadataMessage), Int, Int), String) {
  let outcome =
    dispatch_get(
      transport,
      google_http_client.Gmail,
      metadata_url(identifier),
      token.access_token,
      attempt_number,
    )
  case outcome {
    google_http_client.Response(response) if response.status == 404 -> {
      let next_bytes = response_bytes + string.byte_size(response.body)
      use _ <- result.try(
        case next_bytes <= authority.connector.max_response_bytes {
          True -> Ok(Nil)
          False -> Error("gmail_poll_response_limit_exceeded")
        },
      )
      fetch_metadata(
        authority,
        token,
        rest,
        transport,
        messages,
        next_bytes,
        missing_count + 1,
        attempt_number,
      )
    }
    _ -> {
      use response <- result.try(expect_response(outcome, "gmail_metadata"))
      let next_bytes = response_bytes + string.byte_size(response.body)
      use _ <- result.try(
        case
          next_bytes <= authority.connector.max_response_bytes
          && list.length(messages) < authority.connector.max_items_per_poll
        {
          True -> Ok(Nil)
          False -> Error("gmail_poll_response_limit_exceeded")
        },
      )
      use message <- result.try(gmail_api.decode_metadata_response(
        response.body,
      ))
      fetch_metadata(
        authority,
        token,
        rest,
        transport,
        [message, ..messages],
        next_bytes,
        missing_count,
        attempt_number,
      )
    }
  }
}

fn record_runtime_failure(
  db_subject: Subject(db.DbMessage),
  authority: GmailAuthority,
  context: operating_contracts.ConnectorSubmissionContext,
  error: String,
) -> Result(Nil, String) {
  use _ <- result.try(case string.ends_with(error, "_scope_insufficient") {
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
  let error_class = runtime_error_class(error)
  case error_class {
    "external_read_unknown" ->
      db.record_connector_read_failure(
        db_subject,
        context,
        time.now_ms() + 60_000,
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
        time.now_ms() + 60_000,
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
              case string.ends_with(error, "_forbidden") {
                True -> "provider_forbidden"
                False ->
                  case string.ends_with(error, "_scope_insufficient") {
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

fn require_submission(
  value: Option(List(db.EvidenceInsert)),
) -> Result(Nil, String) {
  case value {
    Some(_) -> Ok(Nil)
    None -> Error("gmail_activation_not_effective")
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
            True -> operation <> "_rate_limited"
            False -> operation <> "_forbidden"
          }
      }
    status -> provider_status_error(status, operation)
  }
}

/// Classify one provider status into a closed runtime error code.
pub fn provider_status_error(status: Int, operation: String) -> String {
  case status {
    401 -> operation <> "_unauthorized"
    403 -> operation <> "_forbidden"
    404 -> operation <> "_not_found"
    429 -> operation <> "_rate_limited"
    value if value >= 500 -> operation <> "_provider_unavailable"
    _ -> operation <> "_provider_rejected"
  }
}

fn gmail_authority(
  authorization: operating_contracts.CanaryAuthorizationV1,
  activation_id: String,
) -> Result(GmailAuthority, String) {
  use connector <- result.try(
    authorization.connectors
    |> list.find(fn(value) {
      value.connector_id == "gmail" && value.activation_id == activation_id
    })
    |> result.map_error(fn(_) { "gmail_authority_not_found" }),
  )
  case
    connector.oauth_scope == gmail_scope
    && connector.capability == "mail.read"
    && connector.max_pages_per_poll > 0
    && connector.max_pages_per_poll <= 16
    && connector.max_items_per_poll > 0
    && connector.max_items_per_poll <= 100
    && connector.max_response_bytes > 0
    && connector.max_response_bytes <= 1_048_576
  {
    True -> Ok(GmailAuthority(connector:, authorization:))
    False -> Error("gmail_authority_invalid")
  }
}

fn gmail_registry() -> connector_registry.Registry {
  let assert Ok(registry) =
    connector_registry.build(
      [
        connector_registry.ConnectorDescriptor(
          schema_version: 1,
          connector_id: "gmail",
          display_name: "Gmail",
          source_kind: "connector",
          capabilities: ["mail.read"],
          scopes: [gmail_scope],
          descriptor_provenance_ref: "descriptor://aura/gmail-readonly/v1",
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
          connector_id: "gmail",
          state: "enabled",
          configuration_ref: "config://aura/google-readonly/gmail",
        ),
      ],
    )
  registry
}

fn validate_token(
  token: oauth.ScopedTokenSetV2,
  authority: GmailAuthority,
) -> Result(Nil, String) {
  case
    token.connector_id == "gmail"
    && token.configuration_ref == authority.connector.configuration_ref
    && token.configuration_hash == authority.connector.configuration_hash
    && token.account_fingerprint == authority.connector.account_fingerprint
    && token.granted_scope == gmail_scope
    && token.oauth_proof_ref == authority.connector.oauth_proof_ref
    && token.identity_proof_ref == authority.connector.identity_proof_ref
  {
    True -> Ok(Nil)
    False -> Error("gmail_token_authority_mismatch")
  }
}

fn submission_context(
  authority: GmailAuthority,
  attempt: db.ConnectorReadAttempt,
  worker_id: String,
) -> operating_contracts.ConnectorSubmissionContext {
  operating_contracts.ConnectorSubmissionContext(
    activation_id: authority.connector.activation_id,
    activation_version: attempt.activation_version,
    authorization_id: authority.authorization.authorization_id,
    attempt_id: attempt.attempt_id,
    worker_id:,
    connector_id: "gmail",
    capability: "mail.read",
    oauth_scope: gmail_scope,
    configuration_hash: authority.connector.configuration_hash,
    account_fingerprint: authority.connector.account_fingerprint,
    domain_id: authority.authorization.domain_id,
    concern_id: authority.authorization.concern_id,
  )
}

fn history_url(
  start_history_id: String,
  page_token: String,
  maximum: Int,
) -> String {
  let base =
    "https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId="
    <> uri.percent_encode(start_history_id)
    <> "&historyTypes=messageAdded&maxResults="
    <> int.to_string(maximum)
    <> "&fields="
    <> uri.percent_encode(history_fields)
  case page_token {
    "" -> base
    value -> base <> "&pageToken=" <> uri.percent_encode(value)
  }
}

fn metadata_url(identifier: String) -> String {
  "https://gmail.googleapis.com/gmail/v1/users/me/messages/"
  <> uri.percent_encode(identifier)
  <> "?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date&fields="
  <> uri.percent_encode(metadata_fields)
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
    False -> "gmail_runtime_failed"
  }
}
