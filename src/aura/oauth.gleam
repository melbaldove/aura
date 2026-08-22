//// Private, proof-bound Google read-only token records.

import aura/secret
import aura/xdg
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

const gmail_readonly_scope = "https://www.googleapis.com/auth/gmail.readonly"

const calendar_readonly_scope = "https://www.googleapis.com/auth/calendar.readonly"

const credentials_relative_directory = "credentials/connectors"

/// Complete V2 token record for one connector and one verified account.
pub type ScopedTokenSetV2 {
  ScopedTokenSetV2(
    session_ref: String,
    oauth_effect_ref: String,
    preparation_authorization_id: String,
    connector_id: String,
    configuration_ref: String,
    configuration_hash: String,
    oauth_client_ref: String,
    oauth_client_hash: String,
    client_set_ref: String,
    client_set_hash: String,
    oauth_proof_ref: String,
    oauth_result_hash: String,
    identity_proof_ref: String,
    identity_result_hash: String,
    token_effect_ref: String,
    token_effect_result_hash: String,
    account_fingerprint: String,
    granted_scope: String,
    issued_at_ms: Int,
    expires_at_ms: Int,
    access_token: String,
    refresh_token: String,
    identity_hmac_key: String,
  )
}

/// Private token staging record written before the OAuth effect commits.
pub type PendingTokenV1 {
  PendingTokenV1(
    session_ref: String,
    effect_id: String,
    preparation_authorization_id: String,
    connector_id: String,
    configuration_ref: String,
    configuration_hash: String,
    oauth_client_ref: String,
    oauth_client_hash: String,
    client_set_ref: String,
    client_set_hash: String,
    oauth_proof_ref: String,
    oauth_result_hash: String,
    token_effect_ref: String,
    token_effect_result_hash: String,
    granted_scope: String,
    issued_at_ms: Int,
    expires_at_ms: Int,
    access_token: String,
    refresh_token: String,
    identity_hmac_key: String,
  )
}

/// Validate the only scope supported by the Gmail REST path.
pub fn validate_gmail_readonly_scope(scope: String) -> Result(Nil, String) {
  case scope == gmail_readonly_scope {
    True -> Ok(Nil)
    False -> Error("gmail_rest_scope_mismatch")
  }
}

/// Validate the only scope supported by the Calendar REST path.
pub fn validate_calendar_readonly_scope(scope: String) -> Result(Nil, String) {
  case scope == calendar_readonly_scope {
    True -> Ok(Nil)
    False -> Error("calendar_rest_scope_mismatch")
  }
}

/// Validate all secret-free and private bindings in one V2 token.
pub fn validate_scoped_token(
  token: ScopedTokenSetV2,
) -> Result(ScopedTokenSetV2, String) {
  use _ <- result.try(validate_connector_scope(
    token.connector_id,
    token.granted_scope,
  ))
  case
    valid_ref(token.session_ref)
    && valid_ref(token.oauth_effect_ref)
    && valid_ref(token.preparation_authorization_id)
    && valid_ref(token.configuration_ref)
    && string.starts_with(
      token.configuration_ref,
      "configuration:" <> token.connector_id,
    )
    && valid_hash(token.configuration_hash)
    && valid_ref(token.oauth_client_ref)
    && valid_hash(token.oauth_client_hash)
    && valid_ref(token.client_set_ref)
    && valid_hash(token.client_set_hash)
    && valid_ref(token.oauth_proof_ref)
    && valid_hash(token.oauth_result_hash)
    && valid_ref(token.identity_proof_ref)
    && valid_hash(token.identity_result_hash)
    && valid_ref(token.token_effect_ref)
    && valid_hash(token.token_effect_result_hash)
    && valid_fingerprint(token.account_fingerprint)
    && token.expires_at_ms > token.issued_at_ms
    && bounded_secret(token.access_token, 1, 8192)
    && bounded_secret(token.refresh_token, 1, 8192)
    && bounded_secret(token.identity_hmac_key, 32, 256)
  {
    True -> Ok(token)
    False -> Error("scoped_token_v2_invalid")
  }
}

/// Validate one staging record before it enters a private file.
pub fn validate_pending_token(
  token: PendingTokenV1,
) -> Result(PendingTokenV1, String) {
  use _ <- result.try(validate_connector_scope(
    token.connector_id,
    token.granted_scope,
  ))
  case
    valid_ref(token.session_ref)
    && valid_ref(token.effect_id)
    && valid_ref(token.preparation_authorization_id)
    && valid_ref(token.configuration_ref)
    && string.starts_with(
      token.configuration_ref,
      "configuration:" <> token.connector_id,
    )
    && valid_hash(token.configuration_hash)
    && valid_ref(token.oauth_client_ref)
    && valid_hash(token.oauth_client_hash)
    && valid_ref(token.client_set_ref)
    && valid_hash(token.client_set_hash)
    && valid_ref(token.oauth_proof_ref)
    && valid_hash(token.oauth_result_hash)
    && valid_ref(token.token_effect_ref)
    && valid_hash(token.token_effect_result_hash)
    && token.expires_at_ms > token.issued_at_ms
    && bounded_secret(token.access_token, 1, 8192)
    && bounded_secret(token.refresh_token, 1, 8192)
    && bounded_secret(token.identity_hmac_key, 32, 256)
  {
    True -> Ok(token)
    False -> Error("pending_token_v1_invalid")
  }
}

/// Create a credential-specific identity key.
pub fn new_identity_hmac_key() -> Result(String, String) {
  secret.random_urlsafe(32)
}

/// Derive an opaque account fingerprint with a credential-specific key.
pub fn account_fingerprint(
  identity_key: String,
  account_identity: String,
) -> String {
  let normalized = account_identity |> string.trim |> string.lowercase
  let canonical = "aura.google.account.v2\u{0}" <> normalized
  secret.hmac_sha256(identity_key, canonical) |> string.lowercase
}

/// Encode one final V2 token file.
pub fn scoped_token_to_json(token: ScopedTokenSetV2) -> String {
  json.object([
    #("schema_version", json.int(2)),
    #("session_ref", json.string(token.session_ref)),
    #("oauth_effect_ref", json.string(token.oauth_effect_ref)),
    #(
      "preparation_authorization_id",
      json.string(token.preparation_authorization_id),
    ),
    #("connector_id", json.string(token.connector_id)),
    #("configuration_ref", json.string(token.configuration_ref)),
    #("configuration_hash", json.string(token.configuration_hash)),
    #("oauth_client_ref", json.string(token.oauth_client_ref)),
    #("oauth_client_hash", json.string(token.oauth_client_hash)),
    #("client_set_ref", json.string(token.client_set_ref)),
    #("client_set_hash", json.string(token.client_set_hash)),
    #("oauth_proof_ref", json.string(token.oauth_proof_ref)),
    #("oauth_result_hash", json.string(token.oauth_result_hash)),
    #("identity_proof_ref", json.string(token.identity_proof_ref)),
    #("identity_result_hash", json.string(token.identity_result_hash)),
    #("token_effect_ref", json.string(token.token_effect_ref)),
    #("token_effect_result_hash", json.string(token.token_effect_result_hash)),
    #("account_fingerprint", json.string(token.account_fingerprint)),
    #("granted_scope", json.string(token.granted_scope)),
    #("issued_at_ms", json.int(token.issued_at_ms)),
    #("expires_at_ms", json.int(token.expires_at_ms)),
    #("access_token", json.string(token.access_token)),
    #("refresh_token", json.string(token.refresh_token)),
    #("identity_hmac_key", json.string(token.identity_hmac_key)),
  ])
  |> json.to_string
}

/// Decode one Gmail V2 token. V1 and broad-scope records fail closed.
pub fn scoped_token_from_json(raw: String) -> Result(ScopedTokenSetV2, String) {
  decode_scoped_token(raw, "gmail")
}

/// Encode one Calendar V2 token.
pub fn calendar_token_to_json(token: ScopedTokenSetV2) -> String {
  scoped_token_to_json(token)
}

/// Decode one Calendar V2 token.
pub fn calendar_token_from_json(raw: String) -> Result(ScopedTokenSetV2, String) {
  decode_scoped_token(raw, "calendar")
}

/// Encode one private staging token.
pub fn pending_token_to_json(token: PendingTokenV1) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #("session_ref", json.string(token.session_ref)),
    #("effect_id", json.string(token.effect_id)),
    #(
      "preparation_authorization_id",
      json.string(token.preparation_authorization_id),
    ),
    #("connector_id", json.string(token.connector_id)),
    #("configuration_ref", json.string(token.configuration_ref)),
    #("configuration_hash", json.string(token.configuration_hash)),
    #("oauth_client_ref", json.string(token.oauth_client_ref)),
    #("oauth_client_hash", json.string(token.oauth_client_hash)),
    #("client_set_ref", json.string(token.client_set_ref)),
    #("client_set_hash", json.string(token.client_set_hash)),
    #("oauth_proof_ref", json.string(token.oauth_proof_ref)),
    #("oauth_result_hash", json.string(token.oauth_result_hash)),
    #("token_effect_ref", json.string(token.token_effect_ref)),
    #("token_effect_result_hash", json.string(token.token_effect_result_hash)),
    #("granted_scope", json.string(token.granted_scope)),
    #("issued_at_ms", json.int(token.issued_at_ms)),
    #("expires_at_ms", json.int(token.expires_at_ms)),
    #("access_token", json.string(token.access_token)),
    #("refresh_token", json.string(token.refresh_token)),
    #("identity_hmac_key", json.string(token.identity_hmac_key)),
  ])
  |> json.to_string
}

/// Decode one private staging token.
pub fn pending_token_from_json(raw: String) -> Result(PendingTokenV1, String) {
  use token <- result.try(
    json.parse(raw, pending_token_decoder())
    |> result.map_error(fn(_) { "pending_token_v1_invalid" }),
  )
  validate_pending_token(token)
}

/// Resolve the final private token path without account data.
pub fn scoped_token_path(paths: xdg.Paths, configuration_ref: String) -> String {
  xdg.connector_credentials_dir(paths)
  <> "/"
  <> token_file_name(configuration_ref)
}

/// Resolve the staging path for one configuration.
pub fn pending_token_path(paths: xdg.Paths, configuration_ref: String) -> String {
  xdg.connector_credentials_dir(paths)
  <> "/"
  <> pending_file_name(configuration_ref)
}

/// Create one final Gmail V2 token without replacement.
pub fn save_scoped_token(
  paths: xdg.Paths,
  token: ScopedTokenSetV2,
) -> Result(Nil, String) {
  use validated <- result.try(validate_scoped_token(token))
  use _ <- result.try(case validated.connector_id {
    "gmail" -> Ok(Nil)
    _ -> Error("scoped_token_connector_mismatch")
  })
  create_or_replay(
    paths,
    token_file_name(token.configuration_ref),
    scoped_token_to_json(token),
  )
}

/// Load one final Gmail V2 token.
pub fn load_scoped_token(
  paths: xdg.Paths,
  configuration_ref: String,
) -> Result(ScopedTokenSetV2, String) {
  use raw <- result.try(secret.secure_read_beneath(
    paths.config,
    credentials_relative_directory,
    token_file_name(configuration_ref),
  ))
  use token <- result.try(scoped_token_from_json(raw))
  case token.configuration_ref == configuration_ref {
    True -> Ok(token)
    False -> Error("scoped_token_configuration_mismatch")
  }
}

/// Create one final Calendar V2 token without replacement.
pub fn save_calendar_token(
  paths: xdg.Paths,
  token: ScopedTokenSetV2,
) -> Result(Nil, String) {
  use validated <- result.try(validate_scoped_token(token))
  use _ <- result.try(case validated.connector_id {
    "calendar" -> Ok(Nil)
    _ -> Error("scoped_token_connector_mismatch")
  })
  create_or_replay(
    paths,
    token_file_name(token.configuration_ref),
    scoped_token_to_json(token),
  )
}

/// Load one final Calendar V2 token.
pub fn load_calendar_token(
  paths: xdg.Paths,
  configuration_ref: String,
) -> Result(ScopedTokenSetV2, String) {
  use raw <- result.try(secret.secure_read_beneath(
    paths.config,
    credentials_relative_directory,
    token_file_name(configuration_ref),
  ))
  use token <- result.try(calendar_token_from_json(raw))
  case token.configuration_ref == configuration_ref {
    True -> Ok(token)
    False -> Error("scoped_token_configuration_mismatch")
  }
}

/// Atomically replace one final token after an exact refresh.
///
/// Refresh can change only token values and their issue and expiry times. All
/// authorization, client, proof, account, scope, and identity-key bindings stay
/// unchanged.
pub fn replace_scoped_token(
  paths: xdg.Paths,
  current: ScopedTokenSetV2,
  replacement: ScopedTokenSetV2,
) -> Result(Nil, String) {
  use current <- result.try(validate_scoped_token(current))
  use replacement <- result.try(validate_scoped_token(replacement))
  use _ <- result.try(validate_refresh_bindings(current, replacement))
  let current_raw = scoped_token_to_json(current)
  secret.replace_exact_beneath(
    paths.config,
    credentials_relative_directory,
    token_file_name(current.configuration_ref),
    secret.sha256(current_raw),
    scoped_token_to_json(replacement),
  )
}

/// Create or replay one exact private staging token.
pub fn save_pending_token(
  paths: xdg.Paths,
  token: PendingTokenV1,
) -> Result(Nil, String) {
  use _ <- result.try(validate_pending_token(token))
  create_or_replay(
    paths,
    pending_file_name(token.configuration_ref),
    pending_token_to_json(token),
  )
}

/// Load one private staging token.
pub fn load_pending_token(
  paths: xdg.Paths,
  configuration_ref: String,
) -> Result(PendingTokenV1, String) {
  use raw <- result.try(secret.secure_read_beneath(
    paths.config,
    credentials_relative_directory,
    pending_file_name(configuration_ref),
  ))
  use token <- result.try(pending_token_from_json(raw))
  case token.configuration_ref == configuration_ref {
    True -> Ok(token)
    False -> Error("pending_token_configuration_mismatch")
  }
}

/// Remove one exact staging token after hash verification.
pub fn remove_pending_token(
  paths: xdg.Paths,
  token: PendingTokenV1,
) -> Result(Nil, String) {
  let raw = pending_token_to_json(token)
  secret.remove_exact_beneath(
    paths.config,
    credentials_relative_directory,
    pending_file_name(token.configuration_ref),
    secret.sha256(raw),
  )
}

fn create_or_replay(
  paths: xdg.Paths,
  file_name: String,
  raw: String,
) -> Result(Nil, String) {
  case
    secret.create_exclusive_beneath(
      paths.config,
      credentials_relative_directory,
      file_name,
      raw,
    )
  {
    Ok(value) -> Ok(value)
    Error("secret_already_exists") -> {
      use existing <- result.try(secret.secure_read_beneath(
        paths.config,
        credentials_relative_directory,
        file_name,
      ))
      case
        secret.constant_time_equal(secret.sha256(existing), secret.sha256(raw))
      {
        True -> Ok(Nil)
        False -> Error("secret_already_exists")
      }
    }
    Error(error) -> Error(error)
  }
}

fn validate_refresh_bindings(
  current: ScopedTokenSetV2,
  replacement: ScopedTokenSetV2,
) -> Result(Nil, String) {
  case
    current.session_ref == replacement.session_ref
    && current.oauth_effect_ref == replacement.oauth_effect_ref
    && current.preparation_authorization_id
    == replacement.preparation_authorization_id
    && current.connector_id == replacement.connector_id
    && current.configuration_ref == replacement.configuration_ref
    && current.configuration_hash == replacement.configuration_hash
    && current.oauth_client_ref == replacement.oauth_client_ref
    && current.oauth_client_hash == replacement.oauth_client_hash
    && current.client_set_ref == replacement.client_set_ref
    && current.client_set_hash == replacement.client_set_hash
    && current.oauth_proof_ref == replacement.oauth_proof_ref
    && current.oauth_result_hash == replacement.oauth_result_hash
    && current.identity_proof_ref == replacement.identity_proof_ref
    && current.identity_result_hash == replacement.identity_result_hash
    && current.account_fingerprint == replacement.account_fingerprint
    && current.granted_scope == replacement.granted_scope
    && current.identity_hmac_key == replacement.identity_hmac_key
    && replacement.issued_at_ms >= current.issued_at_ms
  {
    True -> Ok(Nil)
    False -> Error("scoped_token_refresh_binding_mismatch")
  }
}

fn decode_scoped_token(
  raw: String,
  connector_id: String,
) -> Result(ScopedTokenSetV2, String) {
  use token <- result.try(
    json.parse(raw, scoped_token_decoder())
    |> result.map_error(fn(_) { "scoped_token_v2_invalid" }),
  )
  use validated <- result.try(validate_scoped_token(token))
  case validated.connector_id == connector_id {
    True -> Ok(validated)
    False -> Error("scoped_token_connector_mismatch")
  }
}

fn scoped_token_decoder() -> decode.Decoder(ScopedTokenSetV2) {
  use _ <- decode.field("schema_version", exact_version(2))
  use session_ref <- decode.field("session_ref", decode.string)
  use oauth_effect_ref <- decode.field("oauth_effect_ref", decode.string)
  use preparation_authorization_id <- decode.field(
    "preparation_authorization_id",
    decode.string,
  )
  use connector_id <- decode.field("connector_id", decode.string)
  use configuration_ref <- decode.field("configuration_ref", decode.string)
  use configuration_hash <- decode.field("configuration_hash", decode.string)
  use oauth_client_ref <- decode.field("oauth_client_ref", decode.string)
  use oauth_client_hash <- decode.field("oauth_client_hash", decode.string)
  use client_set_ref <- decode.field("client_set_ref", decode.string)
  use client_set_hash <- decode.field("client_set_hash", decode.string)
  use oauth_proof_ref <- decode.field("oauth_proof_ref", decode.string)
  use oauth_result_hash <- decode.field("oauth_result_hash", decode.string)
  use identity_proof_ref <- decode.field("identity_proof_ref", decode.string)
  use identity_result_hash <- decode.field(
    "identity_result_hash",
    decode.string,
  )
  use token_effect_ref <- decode.field("token_effect_ref", decode.string)
  use token_effect_result_hash <- decode.field(
    "token_effect_result_hash",
    decode.string,
  )
  use account_fingerprint <- decode.field("account_fingerprint", decode.string)
  use granted_scope <- decode.field("granted_scope", decode.string)
  use issued_at_ms <- decode.field("issued_at_ms", decode.int)
  use expires_at_ms <- decode.field("expires_at_ms", decode.int)
  use access_token <- decode.field("access_token", decode.string)
  use refresh_token <- decode.field("refresh_token", decode.string)
  use identity_hmac_key <- decode.field("identity_hmac_key", decode.string)
  decode.success(ScopedTokenSetV2(
    session_ref:,
    oauth_effect_ref:,
    preparation_authorization_id:,
    connector_id:,
    configuration_ref:,
    configuration_hash:,
    oauth_client_ref:,
    oauth_client_hash:,
    client_set_ref:,
    client_set_hash:,
    oauth_proof_ref:,
    oauth_result_hash:,
    identity_proof_ref:,
    identity_result_hash:,
    token_effect_ref:,
    token_effect_result_hash:,
    account_fingerprint:,
    granted_scope:,
    issued_at_ms:,
    expires_at_ms:,
    access_token:,
    refresh_token:,
    identity_hmac_key:,
  ))
}

fn pending_token_decoder() -> decode.Decoder(PendingTokenV1) {
  use _ <- decode.field("schema_version", exact_version(1))
  use session_ref <- decode.field("session_ref", decode.string)
  use effect_id <- decode.field("effect_id", decode.string)
  use preparation_authorization_id <- decode.field(
    "preparation_authorization_id",
    decode.string,
  )
  use connector_id <- decode.field("connector_id", decode.string)
  use configuration_ref <- decode.field("configuration_ref", decode.string)
  use configuration_hash <- decode.field("configuration_hash", decode.string)
  use oauth_client_ref <- decode.field("oauth_client_ref", decode.string)
  use oauth_client_hash <- decode.field("oauth_client_hash", decode.string)
  use client_set_ref <- decode.field("client_set_ref", decode.string)
  use client_set_hash <- decode.field("client_set_hash", decode.string)
  use oauth_proof_ref <- decode.field("oauth_proof_ref", decode.string)
  use oauth_result_hash <- decode.field("oauth_result_hash", decode.string)
  use token_effect_ref <- decode.field("token_effect_ref", decode.string)
  use token_effect_result_hash <- decode.field(
    "token_effect_result_hash",
    decode.string,
  )
  use granted_scope <- decode.field("granted_scope", decode.string)
  use issued_at_ms <- decode.field("issued_at_ms", decode.int)
  use expires_at_ms <- decode.field("expires_at_ms", decode.int)
  use access_token <- decode.field("access_token", decode.string)
  use refresh_token <- decode.field("refresh_token", decode.string)
  use identity_hmac_key <- decode.field("identity_hmac_key", decode.string)
  decode.success(PendingTokenV1(
    session_ref:,
    effect_id:,
    preparation_authorization_id:,
    connector_id:,
    configuration_ref:,
    configuration_hash:,
    oauth_client_ref:,
    oauth_client_hash:,
    client_set_ref:,
    client_set_hash:,
    oauth_proof_ref:,
    oauth_result_hash:,
    token_effect_ref:,
    token_effect_result_hash:,
    granted_scope:,
    issued_at_ms:,
    expires_at_ms:,
    access_token:,
    refresh_token:,
    identity_hmac_key:,
  ))
}

fn exact_version(expected: Int) -> decode.Decoder(Int) {
  use value <- decode.then(decode.int)
  case value == expected {
    True -> decode.success(value)
    False -> decode.failure(0, expected: "exact schema version")
  }
}

fn token_file_name(configuration_ref: String) -> String {
  hash(configuration_ref) <> ".json"
}

fn pending_file_name(configuration_ref: String) -> String {
  hash(configuration_ref) <> ".pending.json"
}

fn hash(value: String) -> String {
  crypto.hash(crypto.Sha256, <<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}

fn validate_connector_scope(
  connector_id: String,
  scope: String,
) -> Result(Nil, String) {
  case connector_id {
    "gmail" -> validate_gmail_readonly_scope(scope)
    "calendar" -> validate_calendar_readonly_scope(scope)
    _ -> Error("scoped_token_connector_invalid")
  }
}

fn valid_ref(value: String) -> Bool {
  let size = string.length(value)
  size > 0
  && size <= 256
  && value
  |> string.to_utf_codepoints
  |> list.all(fn(codepoint) {
    let value = string.utf_codepoint_to_int(codepoint)
    value > 32 && value < 127
  })
}

fn valid_hash(value: String) -> Bool {
  string.length(value) == 64
  && value
  |> string.to_graphemes
  |> list.all(fn(char) { string.contains("0123456789abcdef", char) })
}

fn valid_fingerprint(value: String) -> Bool {
  valid_hash(value)
}

fn bounded_secret(value: String, minimum: Int, maximum: Int) -> Bool {
  let size = string.length(value)
  size >= minimum && size <= maximum && !string.contains(value, "\u{0}")
}
