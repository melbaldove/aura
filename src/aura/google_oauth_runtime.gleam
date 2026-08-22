//// Supervised owner for one-shot Google read-only OAuth callbacks.
////
//// This module owns the local loopback listener and the durable OAuth effect
//// protocol. Provider dispatch stays behind an injected, fail-closed transport.

import aura/config
import aura/db
import aura/google_http_client
import aura/google_oauth_client
import aura/google_oauth_http
import aura/oauth
import aura/oauth_loopback
import aura/secret
import aura/time
import aura/xdg
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/uri
import logging

const gmail_scope = "https://www.googleapis.com/auth/gmail.readonly"

const calendar_scope = "https://www.googleapis.com/auth/calendar.readonly"

const authorization_endpoint = "https://accounts.google.com/o/oauth2/auth"

const session_lifetime_ms = 300_000

const callback_acceptance_ms = 5000

const callback_reply_margin_ms = 10_000

const refresh_skew_ms = 300_000

/// Complete secret-free binding for one new OAuth authorization session.
pub type BeginRequest {
  BeginRequest(
    connector_id: String,
    preparation_authorization_id: String,
    configuration_ref: String,
    configuration_hash: String,
    client_set_ref: String,
    client_set_hash: String,
    oauth_client_ref: String,
    oauth_client_hash: String,
  )
}

/// Safe handoff for a browser or an exact manual URL open operation.
pub type AuthorizationHandle {
  AuthorizationHandle(
    session_ref: String,
    authorization_url: String,
    loopback_port: Int,
    expires_at_ms: Int,
  )
}

/// Result of one injected HTTP dispatch boundary.
pub type TransportOutcome {
  BeforeDispatch
  AfterDispatch
  Response(google_oauth_http.HttpResponse)
}

/// Secret-bearing HTTP requests remain inside this narrow owner boundary.
pub type Transport =
  fn(google_oauth_http.HttpRequest) -> TransportOutcome

/// Secret-free result of a completed OAuth and identity preparation.
pub type CompletionReceipt {
  CompletionReceipt(
    connector_id: String,
    configuration_ref: String,
    account_fingerprint: String,
    oauth_proof_ref: String,
    identity_proof_ref: String,
  )
}

/// Messages accepted by the supervised OAuth owner.
pub opaque type Message {
  Begin(
    request: BeginRequest,
    reply_to: process.Subject(Result(AuthorizationHandle, String)),
  )
  Callback(
    session_ref: String,
    kind: String,
    callback_state: String,
    value: String,
    accept_before_ms: Int,
    reply_to: process.Subject(Bool),
  )
  Phase(session_ref: String, reply_to: process.Subject(Result(String, String)))
  Complete(
    session_ref: String,
    reply_to: process.Subject(Result(CompletionReceipt, String)),
  )
  CompleteAsync(session_ref: String)
  Reconcile(
    configuration_ref: String,
    reply_to: process.Subject(Result(CompletionReceipt, String)),
  )
  BlockForTest(duration_ms: Int, started: process.Subject(Nil))
}

type PrivateSession {
  PrivateSession(
    listener: oauth_loopback.Listener,
    state: String,
    code_verifier: String,
    request: BeginRequest,
    phase: String,
    callback_code: String,
  )
}

type State {
  State(
    db_subject: process.Subject(db.DbMessage),
    paths: xdg.Paths,
    configurations: List(config.ConnectorConfiguration),
    self_subject: process.Subject(Message),
    callback_acceptance_ms: Int,
    transport: Transport,
    transport_enabled: Bool,
    auto_complete: Bool,
    sessions: Dict(String, PrivateSession),
  )
}

/// Start the stable OAuth owner and expire sessions left by an old owner.
pub fn start_named(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  start_named_with_callback_acceptance(
    name,
    db_subject,
    paths,
    configurations,
    callback_acceptance_ms,
    fn(_) { BeforeDispatch },
    False,
    False,
  )
}

/// Start an OAuth owner with a shorter callback deadline for local tests.
pub fn start_named_for_test(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  acceptance_ms: Int,
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  start_named_with_callback_acceptance(
    name,
    db_subject,
    paths,
    configurations,
    acceptance_ms,
    fn(_) { BeforeDispatch },
    False,
    False,
  )
}

/// Start a local owner with one injected fake transport.
pub fn start_named_with_transport_for_test(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  acceptance_ms: Int,
  transport: Transport,
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  start_named_with_callback_acceptance(
    name,
    db_subject,
    paths,
    configurations,
    acceptance_ms,
    transport,
    True,
    False,
  )
}

/// Start a local owner that automatically completes with one fake transport.
pub fn start_named_with_auto_transport_for_test(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  acceptance_ms: Int,
  transport: Transport,
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  start_named_with_callback_acceptance(
    name,
    db_subject,
    paths,
    configurations,
    acceptance_ms,
    transport,
    True,
    True,
  )
}

/// Start the production OAuth owner with fixed Google HTTPS transport.
pub fn start_named_production(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  start_named_with_callback_acceptance(
    name,
    db_subject,
    paths,
    configurations,
    callback_acceptance_ms,
    production_transport,
    True,
    True,
  )
}

fn start_named_with_callback_acceptance(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  acceptance_ms: Int,
  transport: Transport,
  transport_enabled: Bool,
  auto_complete: Bool,
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self_subject) {
    let initial =
      State(
        db_subject:,
        paths:,
        configurations:,
        self_subject:,
        callback_acceptance_ms: acceptance_ms,
        transport:,
        transport_enabled:,
        auto_complete:,
        sessions: dict.new(),
      )
    use _ <- result.try(case transport_enabled {
      True -> reconcile_all_pending(initial)
      False -> Ok(Nil)
    })
    use _ <- result.try(db.expire_google_oauth_sessions(db_subject))
    Ok(
      actor.initialised(initial)
      |> actor.returning(self_subject),
    )
  })
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

/// Build the OAuth owner child for the Aura root supervisor.
pub fn supervised(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    start_named(name, db_subject, paths, configurations)
  })
  |> supervision.map_data(fn(_) { Nil })
}

/// Build the production OAuth owner child for the Aura root supervisor.
pub fn supervised_production(
  name: process.Name(Message),
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    start_named_production(name, db_subject, paths, configurations)
  })
  |> supervision.map_data(fn(_) { Nil })
}

/// Start one connector-bound authorization session.
pub fn begin(
  owner: process.Subject(Message),
  request: BeginRequest,
) -> Result(AuthorizationHandle, String) {
  process.call(owner, 5000, fn(reply_to) { Begin(request:, reply_to:) })
}

/// Read only the bounded phase. The callback code stays in the OAuth owner.
pub fn phase(
  owner: process.Subject(Message),
  session_ref: String,
) -> Result(String, String) {
  process.call(owner, 5000, fn(reply_to) { Phase(session_ref:, reply_to:) })
}

/// Complete one claimed authorization code without returning secret material.
pub fn complete_authorization(
  owner: process.Subject(Message),
  session_ref: String,
) -> Result(CompletionReceipt, String) {
  process.call(owner, 15_000, fn(reply_to) { Complete(session_ref:, reply_to:) })
}

/// Reconcile one exact pending token without repeating its code exchange.
pub fn reconcile_pending(
  owner: process.Subject(Message),
  configuration_ref: String,
) -> Result(CompletionReceipt, String) {
  process.call(owner, 15_000, fn(reply_to) {
    Reconcile(configuration_ref:, reply_to:)
  })
}

/// Keep the owner busy for a bounded local failure-path test.
pub fn block_for_test(
  owner: process.Subject(Message),
  duration_ms: Int,
) -> Result(Nil, Nil) {
  let started = process.new_subject()
  process.send(owner, BlockForTest(duration_ms:, started:))
  process.receive(started, 1000)
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Begin(request:, reply_to:) -> {
      case begin_session(state, request) {
        Error(error) -> {
          process.send(reply_to, Error(error))
          actor.continue(state)
        }
        Ok(#(session_ref, private, handle)) -> {
          process.send(reply_to, Ok(handle))
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(state.sessions, session_ref, private),
            ),
          )
        }
      }
    }
    Callback(
      session_ref:,
      kind:,
      callback_state:,
      value:,
      accept_before_ms:,
      reply_to:,
    ) -> {
      case
        handle_callback(
          state,
          session_ref,
          kind,
          callback_state,
          value,
          accept_before_ms,
        )
      {
        Ok(#(next, accepted)) -> {
          process.send(reply_to, accepted)
          case accepted && state.auto_complete {
            True -> process.send(state.self_subject, CompleteAsync(session_ref))
            False -> Nil
          }
          actor.continue(next)
        }
        Error(_) -> {
          process.send(reply_to, False)
          close_all_listeners(state)
          actor.stop()
        }
      }
    }
    Phase(session_ref:, reply_to:) -> {
      process.send(
        reply_to,
        dict.get(state.sessions, session_ref)
          |> result.map(fn(session) { session.phase })
          |> result.map_error(fn(_) { "oauth_loopback_session_not_usable" }),
      )
      actor.continue(state)
    }
    Complete(session_ref:, reply_to:) -> {
      let #(next, outcome) = complete_claimed_session(state, session_ref)
      process.send(reply_to, outcome)
      actor.continue(next)
    }
    CompleteAsync(session_ref:) -> {
      let #(next, outcome) = complete_claimed_session(state, session_ref)
      case outcome {
        Ok(_) -> actor.continue(next)
        Error(_) -> {
          logging.log(
            logging.Error,
            "[google_oauth] Automatic completion failed",
          )
          close_all_listeners(state)
          actor.stop()
        }
      }
    }
    Reconcile(configuration_ref:, reply_to:) -> {
      process.send(reply_to, reconcile_configuration(state, configuration_ref))
      actor.continue(state)
    }
    BlockForTest(duration_ms:, started:) -> {
      process.send(started, Nil)
      process.sleep(duration_ms)
      actor.continue(state)
    }
  }
}

fn production_transport(
  request: google_oauth_http.HttpRequest,
) -> TransportOutcome {
  let outcome = case request.method, request.headers, request.body {
    "POST", _, _ -> google_http_client.post(request, 1)
    "GET", [#("authorization", authorization)], "" ->
      case string.split_once(authorization, "Bearer ") {
        Ok(#("", token)) -> {
          let guard = case
            string.starts_with(
              request.url,
              "https://gmail.googleapis.com/gmail/v1/users/me/profile",
            )
          {
            True -> google_http_client.GmailIdentity
            False -> google_http_client.CalendarIdentity
          }
          google_http_client.get(guard, request.url, token, 1)
        }
        _ -> google_http_client.BeforeDispatch("google_identity_token_invalid")
      }
    _, _, _ -> google_http_client.BeforeDispatch("google_request_invalid")
  }
  case outcome {
    google_http_client.BeforeDispatch(_) -> BeforeDispatch
    google_http_client.AfterDispatch(_) -> AfterDispatch
    google_http_client.Response(response) ->
      Response(google_oauth_http.HttpResponse(response.status, response.body))
  }
}

fn complete_claimed_session(
  state: State,
  session_ref: String,
) -> #(State, Result(CompletionReceipt, String)) {
  case dict.get(state.sessions, session_ref) {
    Error(_) -> #(state, Error("oauth_loopback_session_not_usable"))
    Ok(session) ->
      case session.phase == "callback_claimed" && session.callback_code != "" {
        False -> #(state, Error("oauth_loopback_session_not_claimed"))
        True -> {
          let next = remove_session(state, session_ref)
          case exchange_and_identify(state, session_ref, session) {
            Ok(receipt) -> #(next, Ok(receipt))
            Error("google_identity_effect_unknown" as error) -> #(
              next,
              Error(error),
            )
            Error(error) ->
              case
                db.recover_google_oauth_session(state.db_subject, session_ref)
              {
                Ok(_) -> #(next, Error(error))
                Error(recovery_error) -> #(next, Error(recovery_error))
              }
          }
        }
      }
  }
}

fn exchange_and_identify(
  state: State,
  session_ref: String,
  session: PrivateSession,
) -> Result(CompletionReceipt, String) {
  use _ <- result.try(recheck_callback_binding(state, session))
  use client <- result.try(google_oauth_client.load(
    state.paths,
    session.request.connector_id,
    session.request.oauth_client_ref,
  ))
  use scope <- result.try(scope_for(session.request.connector_id))
  use identity_key <- result.try(oauth.new_identity_hmac_key())
  let effect_id = "effect:oauth:" <> secret.sha256(session_ref)
  let proof_ref = "proof:oauth:" <> secret.sha256(effect_id)
  let request_hash =
    secret.sha256(canonical_effect_request(
      "oauth_exchange",
      session_ref,
      session.request,
      scope,
      secret.sha256(session.callback_code),
      secret.sha256(session.code_verifier),
    ))
  let intent =
    effect(
      effect_id,
      "oauth_exchange",
      "oauth:" <> secret.sha256(session_ref),
      1,
      request_hash,
      session.request,
      scope,
    )
  use _ <- result.try(begin_exchange_effect(state, session_ref, intent))
  use request <- result.try(google_oauth_http.code_exchange_request(
    client.client_id,
    client.client_secret,
    session.callback_code,
    session.code_verifier,
    "http://127.0.0.1:" <> int.to_string(session.listener.port) <> "/callback",
  ))
  case state.transport(request) {
    BeforeDispatch ->
      fail_exchange(
        state,
        session_ref,
        effect_id,
        "failed_before_effect",
        "before_dispatch",
        "callback_invalid",
        "google_oauth_before_dispatch",
      )
    AfterDispatch ->
      fail_exchange(
        state,
        session_ref,
        effect_id,
        "effect_unknown",
        "transport_after_dispatch",
        "callback_transport_unknown",
        "google_oauth_effect_unknown",
      )
    Response(response) ->
      case google_oauth_http.decode_initial_token_response(response, scope) {
        Error(error) ->
          fail_exchange_response(state, session_ref, effect_id, error)
        Ok(tokens) -> {
          let issued_at_ms = time.now_ms()
          let result_hash = token_result_hash(tokens, issued_at_ms)
          let pending =
            oauth.PendingTokenV1(
              session_ref:,
              effect_id:,
              preparation_authorization_id: session.request.preparation_authorization_id,
              connector_id: session.request.connector_id,
              configuration_ref: session.request.configuration_ref,
              configuration_hash: session.request.configuration_hash,
              oauth_client_ref: session.request.oauth_client_ref,
              oauth_client_hash: session.request.oauth_client_hash,
              client_set_ref: session.request.client_set_ref,
              client_set_hash: session.request.client_set_hash,
              oauth_proof_ref: proof_ref,
              oauth_result_hash: result_hash,
              token_effect_ref: effect_id,
              token_effect_result_hash: result_hash,
              granted_scope: scope,
              issued_at_ms:,
              expires_at_ms: issued_at_ms + tokens.expires_in_seconds * 1000,
              access_token: tokens.access_token,
              refresh_token: tokens.refresh_token,
              identity_hmac_key: identity_key,
            )
          use _ <- result.try(oauth.save_pending_token(state.paths, pending))
          use _ <- result.try(db.finish_google_external_effect(
            state.db_subject,
            effect_id,
            "succeeded",
            proof_ref,
            "",
            result_hash,
            "",
          ))
          identify_pending(state, session_ref, session.request, pending)
        }
      }
  }
}

fn identify_pending(
  state: State,
  session_ref: String,
  request_binding: BeginRequest,
  pending: oauth.PendingTokenV1,
) -> Result(CompletionReceipt, String) {
  use _ <- result.try(recheck_request_binding(state, request_binding))
  let logical_key = "identity:" <> secret.sha256(session_ref)
  use latest <- result.try(db.get_latest_google_external_effect(
    state.db_subject,
    logical_key,
  ))
  case latest {
    Some(stored) if stored.phase == "succeeded" ->
      promote_pending(
        state,
        pending,
        stored.proof_ref,
        stored.result_hash,
        stored.account_fingerprint,
      )
    Some(stored) if stored.phase == "intent" -> {
      use _ <- result.try(db.finish_google_external_effect(
        state.db_subject,
        stored.effect_id,
        "effect_unknown",
        "",
        "",
        "",
        "transport_after_dispatch",
      ))
      run_identity_attempt(
        state,
        session_ref,
        request_binding,
        pending,
        logical_key,
      )
    }
    _ ->
      run_identity_attempt(
        state,
        session_ref,
        request_binding,
        pending,
        logical_key,
      )
  }
}

fn run_identity_attempt(
  state: State,
  session_ref: String,
  request_binding: BeginRequest,
  pending: oauth.PendingTokenV1,
  logical_key: String,
) -> Result(CompletionReceipt, String) {
  use attempt_number <- result.try(db.next_google_external_effect_attempt(
    state.db_subject,
    logical_key,
    "identity_read",
  ))
  let effect_id =
    "effect:identity:"
    <> secret.sha256(session_ref <> ":" <> int.to_string(attempt_number))
  let proof_ref = "proof:identity:" <> secret.sha256(effect_id)
  let request_hash =
    secret.sha256(canonical_effect_request(
      "identity_read",
      session_ref,
      request_binding,
      pending.granted_scope,
      secret.sha256(pending.access_token),
      "",
    ))
  let intent =
    effect(
      effect_id,
      "identity_read",
      logical_key,
      attempt_number,
      request_hash,
      request_binding,
      pending.granted_scope,
    )
  use _ <- result.try(begin_identity_effect(state, session_ref, pending, intent))
  use request <- result.try(google_oauth_http.identity_request(
    pending.connector_id,
    pending.access_token,
  ))
  case state.transport(request) {
    BeforeDispatch ->
      fail_identity(state, session_ref, pending, effect_id, "before_dispatch")
    AfterDispatch ->
      fail_identity(
        state,
        session_ref,
        pending,
        effect_id,
        "transport_after_dispatch",
      )
    Response(response) -> {
      case
        google_oauth_http.decode_identity_response(
          pending.connector_id,
          response,
        )
      {
        Error(_) ->
          fail_identity_response(state, session_ref, pending, effect_id)
        Ok(identity) -> {
          let fingerprint =
            oauth.account_fingerprint(pending.identity_hmac_key, identity)
          let result_hash =
            secret.sha256(
              "aura.google.identity-result.v1\u{0}"
              <> pending.connector_id
              <> "\u{0}"
              <> fingerprint,
            )
          use _ <- result.try(db.finish_google_external_effect(
            state.db_subject,
            effect_id,
            "succeeded",
            proof_ref,
            fingerprint,
            result_hash,
            "",
          ))
          promote_pending(state, pending, proof_ref, result_hash, fingerprint)
        }
      }
    }
  }
}

fn begin_exchange_effect(
  state: State,
  session_ref: String,
  intent: db.GoogleExternalEffect,
) -> Result(Nil, String) {
  case db.begin_google_external_effect(state.db_subject, intent) {
    Error("preparation_authorization_expired") -> {
      use _ <- result.try(db.finish_google_oauth_session(
        state.db_subject,
        session_ref,
        "failed_before_effect",
        "callback_invalid",
      ))
      Error("preparation_authorization_expired")
    }
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

fn begin_identity_effect(
  state: State,
  session_ref: String,
  pending: oauth.PendingTokenV1,
  intent: db.GoogleExternalEffect,
) -> Result(Nil, String) {
  case db.begin_google_external_effect(state.db_subject, intent) {
    Error("preparation_authorization_expired") -> {
      use _ <- result.try(db.finish_google_oauth_session(
        state.db_subject,
        session_ref,
        "failed_before_effect",
        "callback_invalid",
      ))
      use _ <- result.try(oauth.remove_pending_token(state.paths, pending))
      Error("preparation_authorization_expired")
    }
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

fn promote_pending(
  state: State,
  pending: oauth.PendingTokenV1,
  identity_proof_ref: String,
  identity_result_hash: String,
  fingerprint: String,
) -> Result(CompletionReceipt, String) {
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
      account_fingerprint: fingerprint,
      granted_scope: pending.granted_scope,
      issued_at_ms: pending.issued_at_ms,
      expires_at_ms: pending.expires_at_ms,
      access_token: pending.access_token,
      refresh_token: pending.refresh_token,
      identity_hmac_key: pending.identity_hmac_key,
    )
  use _ <- result.try(save_final_token(state.paths, final))
  use _ <- result.try(oauth.remove_pending_token(state.paths, pending))
  use _ <- result.try(db.finish_google_oauth_session(
    state.db_subject,
    pending.session_ref,
    "succeeded",
    "",
  ))
  Ok(CompletionReceipt(
    connector_id: pending.connector_id,
    configuration_ref: pending.configuration_ref,
    account_fingerprint: fingerprint,
    oauth_proof_ref: pending.oauth_proof_ref,
    identity_proof_ref:,
  ))
}

fn begin_session(
  state: State,
  request: BeginRequest,
) -> Result(#(String, PrivateSession, AuthorizationHandle), String) {
  use scope <- result.try(scope_for(request.connector_id))
  use _ <- result.try(validate_configuration(
    state.configurations,
    request,
    scope,
  ))
  use client_set <- result.try(google_oauth_client.load_client_set(
    state.paths,
    request.client_set_ref,
  ))
  use _ <- result.try(validate_client_set(request, client_set))
  use client <- result.try(google_oauth_client.load(
    state.paths,
    request.connector_id,
    request.oauth_client_ref,
  ))
  use _ <- result.try(case client.client_hash == request.oauth_client_hash {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_binding_mismatch")
  })
  use session_ref_random <- result.try(secret.random_urlsafe(24))
  use callback_state <- result.try(secret.random_urlsafe(32))
  use verifier <- result.try(secret.random_urlsafe(48))
  let session_ref = "oauth-session:" <> session_ref_random
  let now_ms = time.now_ms()
  let expires_at_ms = now_ms + session_lifetime_ms
  let challenge = pkce_challenge(verifier)
  let self_subject = state.self_subject
  let callback_timeout_ms =
    state.callback_acceptance_ms + callback_reply_margin_ms
  use listener <- result.try(
    oauth_loopback.listen_once(fn(kind, state_value, value) {
      let accept_before_ms = time.now_ms() + state.callback_acceptance_ms
      process.call(self_subject, callback_timeout_ms, fn(reply_to) {
        Callback(
          session_ref:,
          kind:,
          callback_state: state_value,
          value:,
          accept_before_ms:,
          reply_to:,
        )
      })
    }),
  )
  let redirect_uri =
    "http://127.0.0.1:" <> int.to_string(listener.port) <> "/callback"
  let durable =
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
      state_hash: secret.sha256(callback_state),
      pkce_challenge: challenge,
      redirect_uri:,
      phase: "waiting",
      expires_at_ms:,
    )
  case db.create_google_oauth_session(state.db_subject, durable) {
    Error(error) -> {
      oauth_loopback.close_listener(listener)
      Error(error)
    }
    Ok(_) -> {
      let url =
        authorization_url(
          client.client_id,
          redirect_uri,
          scope,
          callback_state,
          challenge,
        )
      Ok(#(
        session_ref,
        PrivateSession(
          listener:,
          state: callback_state,
          code_verifier: verifier,
          request:,
          phase: "waiting",
          callback_code: "",
        ),
        AuthorizationHandle(
          session_ref:,
          authorization_url: url,
          loopback_port: listener.port,
          expires_at_ms:,
        ),
      ))
    }
  }
}

fn handle_callback(
  state: State,
  session_ref: String,
  kind: String,
  callback_state: String,
  value: String,
  accept_before_ms: Int,
) -> Result(#(State, Bool), String) {
  case dict.get(state.sessions, session_ref) {
    Error(_) -> Ok(#(state, False))
    Ok(session) ->
      case accept_before_ms >= time.now_ms() {
        False ->
          finish_terminal(
            state,
            session_ref,
            "failed_before_effect",
            "callback_transport_unknown",
          )
        True ->
          handle_callback_before_deadline(
            state,
            session_ref,
            session,
            kind,
            callback_state,
            value,
            accept_before_ms,
          )
      }
  }
}

fn handle_callback_before_deadline(
  state: State,
  session_ref: String,
  session: PrivateSession,
  kind: String,
  callback_state: String,
  value: String,
  accept_before_ms: Int,
) -> Result(#(State, Bool), String) {
  let state_matches = secret.constant_time_equal(session.state, callback_state)
  case kind, state_matches {
    "code", True ->
      case recheck_callback_binding(state, session) {
        Error(_) ->
          finish_terminal(
            state,
            session_ref,
            "failed_before_effect",
            "callback_invalid",
          )
        Ok(_) ->
          case
            db.claim_google_oauth_session_before(
              state.db_subject,
              session_ref,
              accept_before_ms,
            )
          {
            Ok(_) ->
              Ok(#(
                State(
                  ..state,
                  sessions: dict.insert(
                    state.sessions,
                    session_ref,
                    PrivateSession(
                      ..session,
                      phase: "callback_claimed",
                      callback_code: value,
                    ),
                  ),
                ),
                True,
              ))
            Error(error) -> Error(error)
          }
      }
    "error", True -> {
      let error_class = case value {
        "access_denied" -> "authorization_denied"
        _ -> "callback_invalid"
      }
      finish_terminal(state, session_ref, "failed_before_effect", error_class)
    }
    "expired", _ ->
      finish_terminal(state, session_ref, "expired", "session_expired")
    _, False ->
      finish_terminal(
        state,
        session_ref,
        "failed_before_effect",
        "state_mismatch",
      )
    _, True ->
      finish_terminal(
        state,
        session_ref,
        "failed_before_effect",
        "callback_invalid",
      )
  }
}

fn recheck_callback_binding(
  state: State,
  session: PrivateSession,
) -> Result(Nil, String) {
  recheck_request_binding(state, session.request)
}

fn recheck_request_binding(
  state: State,
  request: BeginRequest,
) -> Result(Nil, String) {
  use scope <- result.try(scope_for(request.connector_id))
  use _ <- result.try(validate_configuration(
    state.configurations,
    request,
    scope,
  ))
  use client_set <- result.try(google_oauth_client.load_client_set(
    state.paths,
    request.client_set_ref,
  ))
  use _ <- result.try(validate_client_set(request, client_set))
  use client <- result.try(google_oauth_client.load(
    state.paths,
    request.connector_id,
    request.oauth_client_ref,
  ))
  case client.client_hash == request.oauth_client_hash {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_binding_mismatch")
  }
}

fn reconcile_all_pending(state: State) -> Result(Nil, String) {
  state.configurations
  |> list.try_each(fn(configuration) {
    case
      oauth.load_pending_token(state.paths, configuration.configuration_ref)
    {
      Ok(_) ->
        reconcile_configuration(state, configuration.configuration_ref)
        |> result.map(fn(_) { Nil })
      Error("secret_file_unavailable") ->
        reconcile_final_if_present(state, configuration)
      Error("secret_parent_unavailable") ->
        reconcile_final_if_present(state, configuration)
      Error(error) -> Error(error)
    }
  })
}

fn reconcile_final_if_present(
  state: State,
  configuration: config.ConnectorConfiguration,
) -> Result(Nil, String) {
  case load_final_token(state.paths, configuration) {
    Ok(token) -> reconcile_final_token(state, configuration, token)
    Error("secret_file_unavailable") -> Ok(Nil)
    Error("secret_parent_unavailable") -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

fn reconcile_final_token(
  state: State,
  configuration: config.ConnectorConfiguration,
  token: oauth.ScopedTokenSetV2,
) -> Result(Nil, String) {
  use _ <- result.try(validate_token_configuration(token, configuration))
  let request =
    BeginRequest(
      connector_id: token.connector_id,
      preparation_authorization_id: token.preparation_authorization_id,
      configuration_ref: token.configuration_ref,
      configuration_hash: token.configuration_hash,
      client_set_ref: token.client_set_ref,
      client_set_hash: token.client_set_hash,
      oauth_client_ref: token.oauth_client_ref,
      oauth_client_hash: token.oauth_client_hash,
    )
  use _ <- result.try(recheck_request_binding(state, request))
  use oauth_effect <- result.try(db.get_google_external_effect(
    state.db_subject,
    token.oauth_effect_ref,
  ))
  use oauth_effect <- result.try(case oauth_effect {
    Some(effect)
      if effect.effect_kind == "oauth_exchange"
      && effect.phase == "succeeded"
      && effect.proof_ref == token.oauth_proof_ref
      && effect.result_hash == token.oauth_result_hash
      && effect.connector_id == token.connector_id
      && effect.configuration_ref == token.configuration_ref
    -> Ok(effect)
    _ -> Error("google_oauth_final_effect_mismatch")
  })
  use identity_effect <- result.try(db.get_latest_google_external_effect(
    state.db_subject,
    "identity:" <> secret.sha256(token.session_ref),
  ))
  use _ <- result.try(case identity_effect {
    Some(effect)
      if effect.effect_kind == "identity_read"
      && effect.phase == "succeeded"
      && effect.proof_ref == token.identity_proof_ref
      && effect.result_hash == token.identity_result_hash
      && effect.account_fingerprint == token.account_fingerprint
      && effect.preparation_authorization_id
      == oauth_effect.preparation_authorization_id
    -> Ok(Nil)
    _ -> Error("google_oauth_final_identity_mismatch")
  })
  db.finish_google_oauth_session(
    state.db_subject,
    token.session_ref,
    "succeeded",
    "",
  )
  |> result.map(fn(_) { Nil })
}

fn load_final_token(
  paths: xdg.Paths,
  configuration: config.ConnectorConfiguration,
) -> Result(oauth.ScopedTokenSetV2, String) {
  case configuration.connector_id {
    "gmail" -> oauth.load_scoped_token(paths, configuration.configuration_ref)
    "calendar" ->
      oauth.load_calendar_token(paths, configuration.configuration_ref)
    _ -> Error("google_oauth_connector_invalid")
  }
}

fn reconcile_configuration(
  state: State,
  configuration_ref: String,
) -> Result(CompletionReceipt, String) {
  use pending <- result.try(oauth.load_pending_token(
    state.paths,
    configuration_ref,
  ))
  let request =
    BeginRequest(
      connector_id: pending.connector_id,
      preparation_authorization_id: pending.preparation_authorization_id,
      configuration_ref: pending.configuration_ref,
      configuration_hash: pending.configuration_hash,
      client_set_ref: pending.client_set_ref,
      client_set_hash: pending.client_set_hash,
      oauth_client_ref: pending.oauth_client_ref,
      oauth_client_hash: pending.oauth_client_hash,
    )
  use _ <- result.try(recheck_request_binding(state, request))
  use stored <- result.try(db.get_google_external_effect(
    state.db_subject,
    pending.effect_id,
  ))
  use effect <- result.try(case stored {
    Some(value) -> Ok(value)
    None -> Error("google_oauth_pending_effect_missing")
  })
  use _ <- result.try(case effect.phase {
    "succeeded" ->
      case
        effect.proof_ref == pending.oauth_proof_ref
        && effect.result_hash == pending.oauth_result_hash
      {
        True -> Ok(Nil)
        False -> Error("google_oauth_pending_effect_mismatch")
      }
    "intent" ->
      db.finish_google_external_effect(
        state.db_subject,
        effect.effect_id,
        "succeeded",
        pending.oauth_proof_ref,
        "",
        pending.oauth_result_hash,
        "",
      )
      |> result.map(fn(_) { Nil })
    _ -> Error("google_oauth_pending_effect_terminal")
  })
  identify_pending(state, pending.session_ref, request, pending)
}

fn finish_terminal(
  state: State,
  session_ref: String,
  phase: String,
  error_class: String,
) -> Result(#(State, Bool), String) {
  use _ <- result.try(db.finish_google_oauth_session(
    state.db_subject,
    session_ref,
    phase,
    error_class,
  ))
  Ok(#(remove_session(state, session_ref), False))
}

fn remove_session(state: State, session_ref: String) -> State {
  State(..state, sessions: dict.delete(state.sessions, session_ref))
}

fn close_all_listeners(state: State) -> Nil {
  state.sessions
  |> dict.values
  |> list.each(fn(session) { oauth_loopback.close_listener(session.listener) })
}

fn effect(
  effect_id: String,
  effect_kind: String,
  logical_effect_key: String,
  attempt_number: Int,
  request_hash: String,
  request: BeginRequest,
  scope: String,
) -> db.GoogleExternalEffect {
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
    effect_kind:,
    logical_effect_key:,
    attempt_number:,
    request_hash:,
    phase: "intent",
    proof_ref: "",
    oauth_scope: scope,
    account_fingerprint: "",
    result_hash: "",
    error_class: "",
  )
}

fn canonical_effect_request(
  kind: String,
  session_ref: String,
  request: BeginRequest,
  scope: String,
  first_secret_hash: String,
  second_secret_hash: String,
) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #("kind", json.string(kind)),
    #("session_ref", json.string(session_ref)),
    #("connector_id", json.string(request.connector_id)),
    #(
      "preparation_authorization_id",
      json.string(request.preparation_authorization_id),
    ),
    #("configuration_ref", json.string(request.configuration_ref)),
    #("configuration_hash", json.string(request.configuration_hash)),
    #("oauth_client_ref", json.string(request.oauth_client_ref)),
    #("oauth_client_hash", json.string(request.oauth_client_hash)),
    #("client_set_ref", json.string(request.client_set_ref)),
    #("client_set_hash", json.string(request.client_set_hash)),
    #("scope", json.string(scope)),
    #("first_secret_hash", json.string(first_secret_hash)),
    #("second_secret_hash", json.string(second_secret_hash)),
  ])
  |> json.to_string
}

fn token_result_hash(
  tokens: google_oauth_http.TokenResponse,
  issued_at_ms: Int,
) -> String {
  secret.sha256(
    json.object([
      #("schema_version", json.int(1)),
      #("scope", json.string(tokens.granted_scope)),
      #("issued_at_ms", json.int(issued_at_ms)),
      #("expires_in_seconds", json.int(tokens.expires_in_seconds)),
      #("access_token_hash", json.string(secret.sha256(tokens.access_token))),
      #("refresh_token_hash", json.string(secret.sha256(tokens.refresh_token))),
    ])
    |> json.to_string,
  )
}

fn fail_exchange(
  state: State,
  session_ref: String,
  effect_id: String,
  phase: String,
  effect_error: String,
  session_error: String,
  public_error: String,
) -> Result(CompletionReceipt, String) {
  use _ <- result.try(db.finish_google_external_effect(
    state.db_subject,
    effect_id,
    phase,
    "",
    "",
    "",
    effect_error,
  ))
  use _ <- result.try(db.finish_google_oauth_session(
    state.db_subject,
    session_ref,
    case phase {
      "effect_unknown" -> "effect_unknown"
      _ -> "failed_before_effect"
    },
    session_error,
  ))
  Error(public_error)
}

fn fail_exchange_response(
  state: State,
  session_ref: String,
  effect_id: String,
  error: String,
) -> Result(CompletionReceipt, String) {
  let #(effect_error, session_error) = case error {
    "google_oauth_invalid_grant" -> #("invalid_grant", "callback_invalid")
    "google_oauth_scope_mismatch" -> #("scope_mismatch", "scope_mismatch")
    "google_oauth_response_too_large" -> #(
      "response_too_large",
      "callback_invalid",
    )
    _ -> #("provider_invalid_response", "callback_invalid")
  }
  fail_exchange(
    state,
    session_ref,
    effect_id,
    "failed_before_effect",
    effect_error,
    session_error,
    error,
  )
}

fn fail_identity(
  state: State,
  session_ref: String,
  pending: oauth.PendingTokenV1,
  effect_id: String,
  error_class: String,
) -> Result(CompletionReceipt, String) {
  let phase = case error_class {
    "before_dispatch" -> "failed_before_effect"
    _ -> "effect_unknown"
  }
  use _ <- result.try(db.finish_google_external_effect(
    state.db_subject,
    effect_id,
    phase,
    "",
    "",
    "",
    error_class,
  ))
  case phase {
    "effect_unknown" -> Error("google_identity_effect_unknown")
    _ -> {
      use _ <- result.try(db.finish_google_oauth_session(
        state.db_subject,
        session_ref,
        "failed_before_effect",
        "callback_invalid",
      ))
      use _ <- result.try(oauth.remove_pending_token(state.paths, pending))
      Error("google_identity_before_dispatch")
    }
  }
}

fn fail_identity_response(
  state: State,
  session_ref: String,
  pending: oauth.PendingTokenV1,
  effect_id: String,
) -> Result(CompletionReceipt, String) {
  use _ <- result.try(db.finish_google_external_effect(
    state.db_subject,
    effect_id,
    "failed_before_effect",
    "",
    "",
    "",
    "identity_mismatch",
  ))
  use _ <- result.try(db.finish_google_oauth_session(
    state.db_subject,
    session_ref,
    "failed_before_effect",
    "callback_invalid",
  ))
  use _ <- result.try(oauth.remove_pending_token(state.paths, pending))
  Error("google_oauth_safe_disable_required")
}

fn save_final_token(
  paths: xdg.Paths,
  token: oauth.ScopedTokenSetV2,
) -> Result(Nil, String) {
  case token.connector_id {
    "gmail" -> oauth.save_scoped_token(paths, token)
    "calendar" -> oauth.save_calendar_token(paths, token)
    _ -> Error("google_oauth_connector_invalid")
  }
}

/// Load one valid V2 token and refresh it only within the fixed expiry skew.
pub fn load_or_refresh(
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  configuration_ref: String,
  transport: Transport,
) -> Result(oauth.ScopedTokenSetV2, String) {
  use configuration <- result.try(
    list.find(configurations, fn(value) {
      value.configuration_ref == configuration_ref
    })
    |> result.map_error(fn(_) { "oauth_configuration_not_found" }),
  )
  use current <- result.try(case configuration.connector_id {
    "gmail" -> oauth.load_scoped_token(paths, configuration_ref)
    "calendar" -> oauth.load_calendar_token(paths, configuration_ref)
    _ -> Error("google_oauth_connector_invalid")
  })
  use _ <- result.try(validate_token_configuration(current, configuration))
  use stored_effect <- result.try(db.get_google_external_effect(
    db_subject,
    current.token_effect_ref,
  ))
  case stored_effect {
    Some(stored)
      if stored.effect_kind == "oauth_refresh" && stored.phase == "intent"
    -> {
      let proof_ref = "proof:refresh:" <> secret.sha256(stored.effect_id)
      use _ <- result.try(db.finish_google_external_effect(
        db_subject,
        stored.effect_id,
        "succeeded",
        proof_ref,
        "",
        current.token_effect_result_hash,
        "",
      ))
      refresh_if_needed(db_subject, paths, current, transport)
    }
    _ -> refresh_if_needed(db_subject, paths, current, transport)
  }
}

/// Force one durable refresh after a provider rejects the access token.
///
/// The caller must already own an effective connector read attempt. This
/// function loads the private token and client itself. It does not expose the
/// refresh token or client secret to the caller.
pub fn refresh_after_unauthorized(
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  configurations: List(config.ConnectorConfiguration),
  configuration_ref: String,
  attempt_id: String,
  worker_id: String,
  expected_attempt_version: Int,
  transport: Transport,
) -> Result(oauth.ScopedTokenSetV2, String) {
  use _ <- result.try(db.renew_connector_read(
    db_subject,
    attempt_id,
    worker_id,
    expected_attempt_version,
    300_000,
  ))
  use configuration <- result.try(
    list.find(configurations, fn(value) {
      value.configuration_ref == configuration_ref
    })
    |> result.map_error(fn(_) { "oauth_configuration_not_found" }),
  )
  use current <- result.try(case configuration.connector_id {
    "gmail" -> oauth.load_scoped_token(paths, configuration_ref)
    "calendar" -> oauth.load_calendar_token(paths, configuration_ref)
    _ -> Error("google_oauth_connector_invalid")
  })
  use _ <- result.try(validate_token_configuration(current, configuration))
  run_refresh(db_subject, paths, current, transport)
}

fn refresh_if_needed(
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  current: oauth.ScopedTokenSetV2,
  transport: Transport,
) -> Result(oauth.ScopedTokenSetV2, String) {
  let now_ms = time.now_ms()
  case current.expires_at_ms <= now_ms {
    True -> Error("google_oauth_token_expired")
    False ->
      case current.expires_at_ms - now_ms <= refresh_skew_ms {
        True -> run_refresh(db_subject, paths, current, transport)
        False -> Ok(current)
      }
  }
}

fn run_refresh(
  db_subject: process.Subject(db.DbMessage),
  paths: xdg.Paths,
  current: oauth.ScopedTokenSetV2,
  transport: Transport,
) -> Result(oauth.ScopedTokenSetV2, String) {
  use client <- result.try(google_oauth_client.load(
    paths,
    current.connector_id,
    current.oauth_client_ref,
  ))
  let request_binding =
    BeginRequest(
      connector_id: current.connector_id,
      preparation_authorization_id: current.preparation_authorization_id,
      configuration_ref: current.configuration_ref,
      configuration_hash: current.configuration_hash,
      client_set_ref: current.client_set_ref,
      client_set_hash: current.client_set_hash,
      oauth_client_ref: current.oauth_client_ref,
      oauth_client_hash: current.oauth_client_hash,
    )
  let logical_key =
    "refresh:"
    <> secret.sha256(
      current.configuration_ref <> ":" <> current.token_effect_ref,
    )
  use attempt_number <- result.try(db.next_google_external_effect_attempt(
    db_subject,
    logical_key,
    "oauth_refresh",
  ))
  let effect_id =
    "effect:refresh:"
    <> secret.sha256(logical_key <> ":" <> int.to_string(attempt_number))
  let proof_ref = "proof:refresh:" <> secret.sha256(effect_id)
  let request_hash =
    secret.sha256(
      "aura.google.refresh.v1\u{0}"
      <> current.configuration_ref
      <> "\u{0}"
      <> current.configuration_hash
      <> "\u{0}"
      <> current.oauth_client_ref
      <> "\u{0}"
      <> current.granted_scope
      <> "\u{0}"
      <> int.to_string(attempt_number)
      <> "\u{0}"
      <> secret.sha256(current.refresh_token),
    )
  use _ <- result.try(db.begin_google_external_effect(
    db_subject,
    effect(
      effect_id,
      "oauth_refresh",
      logical_key,
      attempt_number,
      request_hash,
      request_binding,
      current.granted_scope,
    ),
  ))
  use request <- result.try(google_oauth_http.refresh_request(
    client.client_id,
    client.client_secret,
    current.refresh_token,
  ))
  case transport(request) {
    BeforeDispatch -> {
      let _ =
        db.finish_google_external_effect(
          db_subject,
          effect_id,
          "failed_before_effect",
          "",
          "",
          "",
          "before_dispatch",
        )
      Error("google_refresh_before_dispatch")
    }
    AfterDispatch -> {
      let _ =
        db.finish_google_external_effect(
          db_subject,
          effect_id,
          "effect_unknown",
          "",
          "",
          "",
          "transport_after_dispatch",
        )
      Error("google_refresh_effect_unknown")
    }
    Response(response) -> {
      case
        google_oauth_http.decode_refresh_token_response(
          response,
          current.granted_scope,
          current.refresh_token,
        )
      {
        Error(error) -> {
          let error_class = case error {
            "google_oauth_invalid_grant" -> "invalid_grant"
            "google_oauth_scope_mismatch" -> "scope_mismatch"
            "google_oauth_response_too_large" -> "response_too_large"
            _ -> "provider_invalid_response"
          }
          use _ <- result.try(db.finish_google_external_effect(
            db_subject,
            effect_id,
            "failed_before_effect",
            "",
            "",
            "",
            error_class,
          ))
          Error(case error_class {
            "invalid_grant" | "scope_mismatch" ->
              "google_oauth_safe_disable_required"
            _ -> error
          })
        }
        Ok(tokens) -> {
          let issued_at_ms = time.now_ms()
          let result_hash = token_result_hash(tokens, issued_at_ms)
          let replacement =
            oauth.ScopedTokenSetV2(
              ..current,
              token_effect_ref: effect_id,
              token_effect_result_hash: result_hash,
              issued_at_ms:,
              expires_at_ms: issued_at_ms + tokens.expires_in_seconds * 1000,
              access_token: tokens.access_token,
              refresh_token: tokens.refresh_token,
            )
          use _ <- result.try(oauth.replace_scoped_token(
            paths,
            current,
            replacement,
          ))
          use _ <- result.try(db.finish_google_external_effect(
            db_subject,
            effect_id,
            "succeeded",
            proof_ref,
            "",
            result_hash,
            "",
          ))
          Ok(replacement)
        }
      }
    }
  }
}

fn validate_token_configuration(
  token: oauth.ScopedTokenSetV2,
  configuration: config.ConnectorConfiguration,
) -> Result(Nil, String) {
  case
    token.connector_id == configuration.connector_id
    && token.configuration_ref == configuration.configuration_ref
    && token.configuration_hash == configuration.configuration_hash
    && token.oauth_client_ref == configuration.oauth_client_ref
    && token.granted_scope == configuration.oauth_scope
  {
    True -> Ok(Nil)
    False -> Error("oauth_configuration_binding_mismatch")
  }
}

fn validate_client_set(
  request: BeginRequest,
  client_set: google_oauth_client.ClientSetReceipt,
) -> Result(Nil, String) {
  let connector_binding = case request.connector_id {
    "gmail" -> #(client_set.gmail_client_ref, client_set.gmail_client_hash)
    "calendar" -> #(
      client_set.calendar_client_ref,
      client_set.calendar_client_hash,
    )
    _ -> #("", "")
  }
  case
    client_set.client_set_hash == request.client_set_hash
    && connector_binding.0 == request.oauth_client_ref
    && connector_binding.1 == request.oauth_client_hash
  {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_set_binding_mismatch")
  }
}

fn scope_for(connector_id: String) -> Result(String, String) {
  case connector_id {
    "gmail" -> Ok(gmail_scope)
    "calendar" -> Ok(calendar_scope)
    _ -> Error("google_oauth_connector_invalid")
  }
}

fn validate_configuration(
  configurations: List(config.ConnectorConfiguration),
  request: BeginRequest,
  scope: String,
) -> Result(Nil, String) {
  use configuration <- result.try(
    list.find(configurations, fn(value) {
      value.configuration_ref == request.configuration_ref
    })
    |> result.map_error(fn(_) { "oauth_configuration_not_found" }),
  )
  case
    configuration.connector_id == request.connector_id
    && configuration.configuration_hash == request.configuration_hash
    && configuration.oauth_client_ref == request.oauth_client_ref
    && configuration.oauth_scope == scope
  {
    True -> Ok(Nil)
    False -> Error("oauth_configuration_binding_mismatch")
  }
}

fn authorization_url(
  client_id: String,
  redirect_uri: String,
  scope: String,
  state: String,
  challenge: String,
) -> String {
  authorization_endpoint
  <> "?response_type=code"
  <> "&client_id="
  <> uri.percent_encode(client_id)
  <> "&redirect_uri="
  <> uri.percent_encode(redirect_uri)
  <> "&scope="
  <> uri.percent_encode(scope)
  <> "&state="
  <> uri.percent_encode(state)
  <> "&code_challenge="
  <> uri.percent_encode(challenge)
  <> "&code_challenge_method=S256&access_type=offline&prompt=consent"
}

fn pkce_challenge(verifier: String) -> String {
  crypto.hash(crypto.Sha256, <<verifier:utf8>>)
  |> bit_array.base64_url_encode(False)
}
