//// Bounded Google OAuth and identity HTTP contracts.
////
//// This module builds requests and validates injected responses. It does not
//// execute network effects or log secret request fields.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/uri

const token_endpoint = "https://oauth2.googleapis.com/token"

const max_response_bytes = 65_536

/// One bounded request for the later production HTTPS transport.
pub type HttpRequest {
  HttpRequest(
    method: String,
    url: String,
    headers: List(#(String, String)),
    body: String,
  )
}

/// One response supplied by an injected or production transport.
pub type HttpResponse {
  HttpResponse(status: Int, body: String)
}

/// One validated token response. All fields are private credential data.
pub type TokenResponse {
  TokenResponse(
    access_token: String,
    refresh_token: String,
    granted_scope: String,
    expires_in_seconds: Int,
  )
}

type RawTokenResponse {
  RawTokenResponse(
    access_token: String,
    refresh_token: String,
    scope: String,
    token_type: String,
    expires_in: Int,
  )
}

/// Build the fixed authorization-code exchange request.
pub fn code_exchange_request(
  client_id: String,
  client_secret: String,
  code: String,
  code_verifier: String,
  redirect_uri: String,
) -> Result(HttpRequest, String) {
  use _ <- result.try(validate_client_id(client_id))
  use _ <- result.try(validate_optional_secret(client_secret, 8192))
  use _ <- result.try(validate_secret(code, 1024))
  use _ <- result.try(validate_pkce(code_verifier))
  use _ <- result.try(validate_redirect(redirect_uri))
  let fields = [
    #("client_id", client_id),
    #("code", code),
    #("code_verifier", code_verifier),
    #("grant_type", "authorization_code"),
    #("redirect_uri", redirect_uri),
  ]
  let fields = case client_secret {
    "" -> fields
    value -> list.append(fields, [#("client_secret", value)])
  }
  Ok(form_request(fields))
}

/// Build one fixed refresh-token request.
pub fn refresh_request(
  client_id: String,
  client_secret: String,
  refresh_token: String,
) -> Result(HttpRequest, String) {
  use _ <- result.try(validate_client_id(client_id))
  use _ <- result.try(validate_optional_secret(client_secret, 8192))
  use _ <- result.try(validate_secret(refresh_token, 8192))
  let fields = [
    #("client_id", client_id),
    #("grant_type", "refresh_token"),
    #("refresh_token", refresh_token),
  ]
  let fields = case client_secret {
    "" -> fields
    value -> list.append(fields, [#("client_secret", value)])
  }
  Ok(form_request(fields))
}

/// Validate one initial token response with one exact scope.
pub fn decode_initial_token_response(
  response: HttpResponse,
  expected_scope: String,
) -> Result(TokenResponse, String) {
  use raw <- result.try(decode_token_response(response))
  use _ <- result.try(validate_exact_scope(raw.scope, expected_scope))
  use _ <- result.try(validate_common_token(raw))
  use _ <- result.try(validate_secret(raw.refresh_token, 8192))
  Ok(TokenResponse(
    access_token: raw.access_token,
    refresh_token: raw.refresh_token,
    granted_scope: expected_scope,
    expires_in_seconds: raw.expires_in,
  ))
}

/// Validate a refresh response and retain only explicitly permitted old data.
pub fn decode_refresh_token_response(
  response: HttpResponse,
  expected_scope: String,
  prior_refresh_token: String,
) -> Result(TokenResponse, String) {
  use raw <- result.try(decode_token_response(response))
  use _ <- result.try(validate_common_token(raw))
  use _ <- result.try(case raw.scope {
    "" -> validate_exact_scope(expected_scope, expected_scope)
    value -> validate_exact_scope(value, expected_scope)
  })
  let refresh_token = case raw.refresh_token {
    "" -> prior_refresh_token
    value -> value
  }
  use _ <- result.try(validate_secret(refresh_token, 8192))
  Ok(TokenResponse(
    access_token: raw.access_token,
    refresh_token:,
    granted_scope: expected_scope,
    expires_in_seconds: raw.expires_in,
  ))
}

/// Build one fixed account-identity request.
pub fn identity_request(
  connector_id: String,
  access_token: String,
) -> Result(HttpRequest, String) {
  use _ <- result.try(validate_secret(access_token, 8192))
  use url <- result.try(case connector_id {
    "gmail" ->
      Ok(
        "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress",
      )
    "calendar" ->
      Ok("https://www.googleapis.com/calendar/v3/calendars/primary?fields=id")
    _ -> Error("google_identity_connector_invalid")
  })
  Ok(HttpRequest(
    method: "GET",
    url:,
    headers: [#("authorization", "Bearer " <> access_token)],
    body: "",
  ))
}

/// Validate a request before the production token transport receives it.
pub fn validate_transport_request(request: HttpRequest) -> Result(Nil, String) {
  case request.method, request.url, request.headers, request.body {
    "POST",
      "https://oauth2.googleapis.com/token",
      [#("content-type", "application/x-www-form-urlencoded")],
      body
    -> validate_token_form(body)
    _, _, _, _ -> Error("google_oauth_transport_request_invalid")
  }
}

/// Validate one fixed preparation identity request without its bearer value.
pub fn validate_identity_transport_request(
  connector_id: String,
  url: String,
) -> Result(Nil, String) {
  case connector_id, url {
    "gmail",
      "https://gmail.googleapis.com/gmail/v1/users/me/profile?fields=emailAddress"
    -> Ok(Nil)
    "calendar",
      "https://www.googleapis.com/calendar/v3/calendars/primary?fields=id"
    -> Ok(Nil)
    _, _ -> Error("google_identity_request_invalid")
  }
}

/// Decode only the connector account identity seed.
pub fn decode_identity_response(
  connector_id: String,
  response: HttpResponse,
) -> Result(String, String) {
  use _ <- result.try(validate_response_size(response.body))
  use _ <- result.try(case response.status >= 200 && response.status < 300 {
    True -> Ok(Nil)
    False -> Error("google_identity_provider_error")
  })
  use identity <- result.try(case connector_id {
    "gmail" ->
      json.parse(response.body, {
        use value <- decode.field("emailAddress", decode.string)
        decode.success(value)
      })
      |> result.map_error(fn(_) { "google_identity_response_invalid" })
    "calendar" ->
      json.parse(response.body, {
        use value <- decode.field("id", decode.string)
        decode.success(value)
      })
      |> result.map_error(fn(_) { "google_identity_response_invalid" })
    _ -> Error("google_identity_connector_invalid")
  })
  case valid_identity(identity) {
    True -> Ok(identity)
    False -> Error("google_identity_response_invalid")
  }
}

fn form_request(fields: List(#(String, String))) -> HttpRequest {
  HttpRequest(
    method: "POST",
    url: token_endpoint,
    headers: [#("content-type", "application/x-www-form-urlencoded")],
    body: fields
      |> list.map(fn(field) {
        uri.percent_encode(field.0) <> "=" <> uri.percent_encode(field.1)
      })
      |> string.join("&"),
  )
}

fn validate_token_form(body: String) -> Result(Nil, String) {
  case string.byte_size(body) <= 32_768, uri.parse_query(body) {
    False, _ -> Error("google_oauth_transport_request_invalid")
    _, Error(_) -> Error("google_oauth_transport_request_invalid")
    True, Ok(fields) -> {
      let keys = list.map(fields, fn(field) { field.0 })
      let allowed =
        list.all(keys, fn(key) {
          list.contains(
            [
              "client_id",
              "client_secret",
              "code",
              "code_verifier",
              "grant_type",
              "redirect_uri",
              "refresh_token",
            ],
            key,
          )
        })
      let unique = list.unique(keys) == keys
      let grant = values_for(fields, "grant_type")
      let shape = case grant {
        ["authorization_code"] ->
          has_one(fields, "client_id")
          && optional_one(fields, "client_secret")
          && has_one(fields, "code")
          && has_one(fields, "code_verifier")
          && has_one(fields, "redirect_uri")
          && values_for(fields, "refresh_token") == []
        ["refresh_token"] ->
          has_one(fields, "client_id")
          && optional_one(fields, "client_secret")
          && has_one(fields, "refresh_token")
          && values_for(fields, "code") == []
          && values_for(fields, "code_verifier") == []
          && values_for(fields, "redirect_uri") == []
        _ -> False
      }
      case allowed && unique && shape {
        True -> Ok(Nil)
        False -> Error("google_oauth_transport_request_invalid")
      }
    }
  }
}

fn values_for(fields: List(#(String, String)), key: String) -> List(String) {
  fields
  |> list.filter_map(fn(field) {
    case field.0 == key {
      True -> Ok(field.1)
      False -> Error(Nil)
    }
  })
}

fn has_one(fields: List(#(String, String)), key: String) -> Bool {
  case values_for(fields, key) {
    [value] -> value != ""
    _ -> False
  }
}

fn optional_one(fields: List(#(String, String)), key: String) -> Bool {
  case values_for(fields, key) {
    [] -> True
    [value] -> value != ""
    _ -> False
  }
}

fn decode_token_response(
  response: HttpResponse,
) -> Result(RawTokenResponse, String) {
  use _ <- result.try(validate_response_size(response.body))
  case response.status >= 200 && response.status < 300 {
    False -> classify_provider_error(response.body)
    True ->
      json.parse(response.body, raw_token_decoder())
      |> result.map_error(fn(_) { "google_oauth_response_invalid" })
  }
}

fn raw_token_decoder() -> decode.Decoder(RawTokenResponse) {
  use access_token <- decode.field("access_token", decode.string)
  use refresh_token <- decode.optional_field("refresh_token", "", decode.string)
  use scope <- decode.optional_field("scope", "", decode.string)
  use token_type <- decode.field("token_type", decode.string)
  use expires_in <- decode.field("expires_in", decode.int)
  decode.success(RawTokenResponse(
    access_token:,
    refresh_token:,
    scope:,
    token_type:,
    expires_in:,
  ))
}

fn classify_provider_error(body: String) -> Result(RawTokenResponse, String) {
  let provider_code =
    json.parse(body, {
      use value <- decode.field("error", decode.string)
      decode.success(value)
    })
  case provider_code {
    Ok("invalid_grant") -> Error("google_oauth_invalid_grant")
    _ -> Error("google_oauth_provider_error")
  }
}

fn validate_common_token(raw: RawTokenResponse) -> Result(Nil, String) {
  case
    raw.token_type == "Bearer"
    && raw.expires_in > 0
    && raw.expires_in <= 86_400
    && validate_secret(raw.access_token, 8192) == Ok(Nil)
  {
    True -> Ok(Nil)
    False -> Error("google_oauth_response_invalid")
  }
}

fn validate_exact_scope(value: String, expected: String) -> Result(Nil, String) {
  let scopes = string.split(value, " ")
  case scopes == [expected] {
    True -> Ok(Nil)
    False -> Error("google_oauth_scope_mismatch")
  }
}

fn validate_response_size(value: String) -> Result(Nil, String) {
  case string.byte_size(value) <= max_response_bytes {
    True -> Ok(Nil)
    False -> Error("google_oauth_response_too_large")
  }
}

fn validate_client_id(value: String) -> Result(Nil, String) {
  case
    string.length(value) > 0
    && string.length(value) <= 512
    && string.ends_with(value, ".apps.googleusercontent.com")
    && !has_control(value)
  {
    True -> Ok(Nil)
    False -> Error("google_oauth_client_invalid")
  }
}

fn validate_optional_secret(value: String, maximum: Int) -> Result(Nil, String) {
  case value {
    "" -> Ok(Nil)
    _ -> validate_secret(value, maximum)
  }
}

fn validate_secret(value: String, maximum: Int) -> Result(Nil, String) {
  case
    string.length(value) > 0
    && string.length(value) <= maximum
    && !has_control(value)
  {
    True -> Ok(Nil)
    False -> Error("google_oauth_secret_invalid")
  }
}

fn validate_pkce(value: String) -> Result(Nil, String) {
  case
    string.length(value) >= 43
    && string.length(value) <= 128
    && value
    |> string.to_graphemes
    |> list.all(fn(char) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~",
        char,
      )
    })
  {
    True -> Ok(Nil)
    False -> Error("google_oauth_pkce_invalid")
  }
}

fn validate_redirect(value: String) -> Result(Nil, String) {
  case
    string.starts_with(value, "http://127.0.0.1:")
    && string.ends_with(value, "/callback")
    && string.length(value) <= 128
    && !has_control(value)
  {
    True -> Ok(Nil)
    False -> Error("google_oauth_redirect_invalid")
  }
}

fn valid_identity(value: String) -> Bool {
  let length = string.length(value)
  length > 0 && length <= 320 && !has_control(value)
}

fn has_control(value: String) -> Bool {
  value
  |> string.to_utf_codepoints
  |> list.any(fn(codepoint) {
    let value = string.utf_codepoint_to_int(codepoint)
    value < 32 || value == 127
  })
}
