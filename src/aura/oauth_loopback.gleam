//// Local OAuth loopback session validation. This module does not listen on a
//// socket, open a browser, exchange a code, or retain a token.

import aura/secret
import aura/time
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string

const gmail_readonly = "https://www.googleapis.com/auth/gmail.readonly"

const calendar_readonly = "https://www.googleapis.com/auth/calendar.readonly"

const session_lifetime_ms = 300_000

/// One active IPv4 loopback listener. The process accepts one request only.
pub type Listener {
  Listener(port: Int, pid: process.Pid)
}

/// Bind one IPv4 loopback listener on an operating-system selected port.
pub fn listen_once(
  handler: fn(String, String, String) -> Bool,
) -> Result(Listener, String) {
  ffi_listen_once(handler)
  |> result.map(fn(value) { Listener(port: value.1, pid: value.0) })
}

/// Bind a listener with a shorter deadline for local contract tests only.
pub fn listen_once_with_timeout_for_test(
  handler: fn(String, String, String) -> Bool,
  timeout_ms: Int,
) -> Result(Listener, String) {
  ffi_listen_once_with_timeout(handler, timeout_ms)
  |> result.map(fn(value) { Listener(port: value.1, pid: value.0) })
}

/// Close one loopback listener without accepting a callback.
pub fn close_listener(listener: Listener) -> Nil {
  ffi_close_listener(listener.pid)
}

/// Send one local request. This function supports local contract tests only.
pub fn request_once(port: Int, request: String) -> Result(String, String) {
  ffi_request_once(port, request)
}

pub opaque type Session {
  Session(
    preparation_authorization_id: String,
    connector_id: String,
    configuration_ref: String,
    oauth_client_ref: String,
    redirect_uri: String,
    state: String,
    code_verifier: String,
    verifier_hash: String,
    code_challenge: String,
    scope: String,
    expires_at_ms: Int,
    consumed: Bool,
  )
}

/// Server-held input for a later token exchange.
pub opaque type CodeGrant {
  CodeGrant(
    preparation_authorization_id: String,
    connector_id: String,
    code: String,
    code_verifier: String,
    redirect_uri: String,
    oauth_client_ref: String,
    configuration_ref: String,
    scope: String,
  )
}

/// Pure description of the only permitted token exchange request.
///
/// This value does not execute a request. Its secret fields must remain in the
/// local OAuth owner and must not enter logs, audit data, or command output.
pub type TokenExchangeRequest {
  TokenExchangeRequest(
    endpoint: String,
    preparation_authorization_id: String,
    connector_id: String,
    grant_type: String,
    code: String,
    code_verifier: String,
    redirect_uri: String,
    oauth_client_ref: String,
    configuration_ref: String,
    scope: String,
  )
}

/// Public, non-secret description of one server-held OAuth session.
pub type SessionHandle {
  SessionHandle(
    session_ref: String,
    redirect_uri: String,
    state: String,
    code_challenge: String,
    scope: String,
    expires_at_ms: Int,
  )
}

/// Messages for the local, one-use OAuth session owner.
pub type Message {
  Begin(
    connector_id: String,
    preparation_authorization_id: String,
    configuration_ref: String,
    oauth_client_ref: String,
    port: Int,
    reply_to: process.Subject(Result(SessionHandle, String)),
  )
  Consume(
    session_ref: String,
    redirect_uri: String,
    state: String,
    code: String,
    reply_to: process.Subject(Result(CodeGrant, String)),
  )
}

type OwnerState {
  OwnerState(sessions: Dict(String, Session))
}

/// Start the local OAuth session owner. It does not start a listener.
pub fn start() -> Result(
  actor.Started(process.Subject(Message)),
  actor.StartError,
) {
  actor.new(OwnerState(sessions: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Create one server-held, short-lived OAuth session.
pub fn begin(
  owner: process.Subject(Message),
  preparation_authorization_id: String,
  configuration_ref: String,
  oauth_client_ref: String,
  port: Int,
) -> Result(SessionHandle, String) {
  begin_for(
    owner,
    "gmail",
    preparation_authorization_id,
    configuration_ref,
    oauth_client_ref,
    port,
  )
}

/// Create one server-held, short-lived Calendar OAuth session.
///
/// This function does not start a listener, browser, or token exchange.
pub fn begin_calendar(
  owner: process.Subject(Message),
  preparation_authorization_id: String,
  configuration_ref: String,
  oauth_client_ref: String,
  port: Int,
) -> Result(SessionHandle, String) {
  begin_for(
    owner,
    "calendar",
    preparation_authorization_id,
    configuration_ref,
    oauth_client_ref,
    port,
  )
}

fn begin_for(
  owner: process.Subject(Message),
  connector_id: String,
  preparation_authorization_id: String,
  configuration_ref: String,
  oauth_client_ref: String,
  port: Int,
) -> Result(SessionHandle, String) {
  process.call(owner, 5000, fn(reply_to) {
    Begin(
      connector_id:,
      preparation_authorization_id:,
      configuration_ref:,
      oauth_client_ref:,
      port:,
      reply_to:,
    )
  })
}

/// Consume one callback by opaque session reference. The actor removes the
/// session before it returns any result, so no caller can replay the code.
pub fn consume(
  owner: process.Subject(Message),
  session_ref: String,
  redirect_uri: String,
  state: String,
  code: String,
) -> Result(CodeGrant, String) {
  process.call(owner, 5000, fn(reply_to) {
    Consume(session_ref:, redirect_uri:, state:, code:, reply_to:)
  })
}

fn new_random_session(
  connector_id: String,
  preparation_authorization_id: String,
  configuration_ref: String,
  oauth_client_ref: String,
  port: Int,
  now_ms: Int,
) -> Result(Session, String) {
  use state <- result.try(secret.random_urlsafe(32))
  use verifier <- result.try(secret.random_urlsafe(48))
  new_session(
    connector_id,
    preparation_authorization_id,
    configuration_ref,
    oauth_client_ref,
    state,
    verifier,
    port,
    now_ms,
  )
}

/// Create a bounded, local-only Google read-only OAuth session description.
fn new_session(
  connector_id: String,
  preparation_authorization_id: String,
  configuration_ref: String,
  oauth_client_ref: String,
  state: String,
  verifier: String,
  port: Int,
  now_ms: Int,
) -> Result(Session, String) {
  let scope = case connector_id {
    "gmail" -> gmail_readonly
    "calendar" -> calendar_readonly
    _ -> ""
  }
  case
    port > 1023
    && port < 65_536
    && valid_reference(preparation_authorization_id)
    && valid_reference(configuration_ref)
    && valid_reference(oauth_client_ref)
    && scope != ""
    && string.starts_with(configuration_ref, "configuration:" <> connector_id)
    && valid_opaque_value(state, 32, 128)
    && valid_pkce_verifier(verifier)
  {
    True ->
      Ok(Session(
        preparation_authorization_id:,
        connector_id:,
        configuration_ref:,
        oauth_client_ref:,
        redirect_uri: "http://127.0.0.1:" <> int.to_string(port) <> "/callback",
        state:,
        code_verifier: verifier,
        verifier_hash: sha256(verifier),
        code_challenge: pkce_challenge(verifier),
        scope:,
        expires_at_ms: now_ms + session_lifetime_ms,
        consumed: False,
      ))
    False -> Error("oauth_loopback_invalid_session")
  }
}

/// Validate and consume one callback. A consumed session cannot be reused.
fn consume_callback(
  session: Session,
  redirect_uri: String,
  state: String,
  code: String,
  now_ms: Int,
) -> Result(#(Session, CodeGrant), String) {
  case
    session.consumed
    || !valid_opaque_value(code, 1, 1024)
    || now_ms >= session.expires_at_ms
  {
    True -> Error("oauth_loopback_session_not_usable")
    False ->
      case redirect_uri == session.redirect_uri {
        False -> Error("oauth_loopback_redirect_mismatch")
        True ->
          case state == session.state {
            True ->
              Ok(#(
                Session(..session, consumed: True),
                CodeGrant(
                  preparation_authorization_id: session.preparation_authorization_id,
                  connector_id: session.connector_id,
                  code:,
                  code_verifier: session.code_verifier,
                  redirect_uri: session.redirect_uri,
                  oauth_client_ref: session.oauth_client_ref,
                  configuration_ref: session.configuration_ref,
                  scope: session.scope,
                ),
              ))
            False -> Error("oauth_loopback_state_mismatch")
          }
      }
  }
}

/// Build the fixed Google token exchange contract from a consumed code grant.
pub fn token_exchange_request(
  grant: CodeGrant,
) -> Result(TokenExchangeRequest, String) {
  case
    valid_connector_scope(grant.connector_id, grant.scope)
    && valid_opaque_value(grant.code, 1, 1024)
    && valid_pkce_verifier(grant.code_verifier)
    && string.starts_with(grant.redirect_uri, "http://127.0.0.1:")
    && string.ends_with(grant.redirect_uri, "/callback")
    && grant.oauth_client_ref != ""
    && grant.configuration_ref != ""
  {
    False -> Error("oauth_token_exchange_contract_invalid")
    True ->
      Ok(TokenExchangeRequest(
        endpoint: "https://oauth2.googleapis.com/token",
        preparation_authorization_id: grant.preparation_authorization_id,
        connector_id: grant.connector_id,
        grant_type: "authorization_code",
        code: grant.code,
        code_verifier: grant.code_verifier,
        redirect_uri: grant.redirect_uri,
        oauth_client_ref: grant.oauth_client_ref,
        configuration_ref: grant.configuration_ref,
        scope: grant.scope,
      ))
  }
}

fn handle_message(
  state: OwnerState,
  message: Message,
) -> actor.Next(OwnerState, Message) {
  case message {
    Begin(
      connector_id:,
      preparation_authorization_id:,
      configuration_ref:,
      oauth_client_ref:,
      port:,
      reply_to:,
    ) -> {
      let outcome = case secret.random_urlsafe(24) {
        Error(error) -> Error(error)
        Ok(session_ref) ->
          case
            new_random_session(
              connector_id,
              preparation_authorization_id,
              configuration_ref,
              oauth_client_ref,
              port,
              time.now_ms(),
            )
          {
            Error(error) -> Error(error)
            Ok(session) ->
              Ok(#(
                session_ref,
                session,
                SessionHandle(
                  session_ref:,
                  redirect_uri: session.redirect_uri,
                  state: session.state,
                  code_challenge: session.code_challenge,
                  scope: session.scope,
                  expires_at_ms: session.expires_at_ms,
                ),
              ))
          }
      }
      case outcome {
        Error(error) -> {
          process.send(reply_to, Error(error))
          actor.continue(state)
        }
        Ok(#(session_ref, session, handle)) -> {
          process.send(reply_to, Ok(handle))
          actor.continue(
            OwnerState(sessions: dict.insert(
              state.sessions,
              session_ref,
              session,
            )),
          )
        }
      }
    }
    Consume(
      session_ref:,
      redirect_uri:,
      state: callback_state,
      code:,
      reply_to:,
    ) -> {
      case dict.get(state.sessions, session_ref) {
        Error(_) -> {
          process.send(reply_to, Error("oauth_loopback_session_not_usable"))
          actor.continue(state)
        }
        Ok(session) -> {
          // Remove first. Success and failure are both terminal callback
          // outcomes for this opaque session reference.
          let next =
            OwnerState(sessions: dict.delete(state.sessions, session_ref))
          let outcome =
            consume_callback(
              session,
              redirect_uri,
              callback_state,
              code,
              time.now_ms(),
            )
            |> result.map(fn(value) { value.1 })
          process.send(reply_to, outcome)
          actor.continue(next)
        }
      }
    }
  }
}

fn valid_connector_scope(connector_id: String, scope: String) -> Bool {
  case connector_id, scope {
    "gmail", value -> value == gmail_readonly
    "calendar", value -> value == calendar_readonly
    _, _ -> False
  }
}

fn valid_reference(value: String) -> Bool {
  let size = string.length(value)
  size > 0
  && size <= 256
  && !string.contains(value, " ")
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn valid_pkce_verifier(value: String) -> Bool {
  let size = string.length(value)
  size >= 43
  && size <= 128
  && {
    value
    |> string.to_graphemes
    |> list.all(fn(character) {
      string.contains(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~",
        character,
      )
    })
  }
}

fn valid_opaque_value(value: String, minimum: Int, maximum: Int) -> Bool {
  let size = string.length(value)
  size >= minimum
  && size <= maximum
  && {
    value
    |> string.to_graphemes
    |> list.all(fn(character) {
      string.contains(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/+=",
        character,
      )
    })
  }
}

fn sha256(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>) |> bit_array.base16_encode
}

fn pkce_challenge(verifier: String) -> String {
  crypto.hash(crypto.Sha256, <<verifier:utf8>>)
  |> bit_array.base64_url_encode(False)
}

@external(erlang, "aura_oauth_loopback_ffi", "listen_once")
fn ffi_listen_once(
  handler: fn(String, String, String) -> Bool,
) -> Result(#(process.Pid, Int), String)

@external(erlang, "aura_oauth_loopback_ffi", "listen_once_with_timeout")
fn ffi_listen_once_with_timeout(
  handler: fn(String, String, String) -> Bool,
  timeout_ms: Int,
) -> Result(#(process.Pid, Int), String)

@external(erlang, "aura_oauth_loopback_ffi", "close")
fn ffi_close_listener(pid: process.Pid) -> Nil

@external(erlang, "aura_oauth_loopback_ffi", "request_once")
fn ffi_request_once(port: Int, request: String) -> Result(String, String)
