import aura/env
import aura/time
import gleam/bit_array
import gleam/dynamic/decode as dyn_decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import simplifile

pub type CodexAuth {
  CodexAuth(access_token: String, account_id: String)
}

pub type CodexAuthFile {
  CodexAuthFile(
    auth_mode: String,
    openai_api_key: String,
    tokens: CodexTokens,
    last_refresh: String,
    agent_identity: String,
  )
}

pub type CodexTokens {
  CodexTokens(
    id_token: String,
    access_token: String,
    refresh_token: String,
    account_id: String,
  )
}

type RefreshResponse {
  RefreshResponse(
    id_token: Option(String),
    access_token: Option(String),
    refresh_token: Option(String),
  )
}

const refresh_token_url = "https://auth.openai.com/oauth/token"

const codex_client_id = "app_EMoamEEZ73f0CkXaXp7hrann"

const expiry_buffer_ms = 60_000

/// Encode Codex OAuth auth into Aura's existing single `api_key` slot.
/// The token itself remains the bearer value; the optional account id is used
/// only to add the ChatGPT workspace header for Codex backend requests.
pub fn encode(auth: CodexAuth) -> String {
  case auth.account_id {
    "" -> auth.access_token
    account_id -> auth.access_token <> "\n" <> account_id
  }
}

pub fn decode(encoded: String) -> CodexAuth {
  case string.split_once(encoded, "\n") {
    Ok(#(access_token, account_id)) ->
      CodexAuth(access_token: access_token, account_id: account_id)
    Error(_) -> CodexAuth(access_token: encoded, account_id: "")
  }
}

/// Load Codex OAuth credentials from an explicit Aura env override, then from
/// the Codex CLI file cache at `$CODEX_HOME/auth.json` or `~/.codex/auth.json`.
/// File-backed Codex credentials are refreshed in place when their access JWT
/// is expired so long-running Aura processes do not hold a stale bearer token.
pub fn load() -> Result(CodexAuth, String) {
  case env.get_env("AURA_OPENAI_CODEX_ACCESS_TOKEN") {
    Ok(token) ->
      Ok(CodexAuth(
        access_token: token,
        account_id: env.get_env("AURA_OPENAI_CODEX_ACCOUNT_ID") |> result.unwrap(""),
      ))
    Error(_) -> load_from_auth_json()
  }
}

pub fn auth_json_path() -> Result(String, String) {
  case env.get_env("CODEX_HOME") {
    Ok(codex_home) -> Ok(codex_home <> "/auth.json")
    Error(_) ->
      case env.get_env("HOME") {
        Ok(home) -> Ok(home <> "/.codex/auth.json")
        Error(_) -> Error("HOME is not set; cannot locate Codex auth.json")
      }
  }
}

pub fn load_from_auth_json() -> Result(CodexAuth, String) {
  use path <- result.try(auth_json_path())
  use raw <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) {
      "OpenAI Codex OAuth credentials not found at "
      <> path
      <> "; run `codex login` or set AURA_OPENAI_CODEX_ACCESS_TOKEN. Read error: "
      <> simplifile.describe_error(e)
    }),
  )
  use auth_file <- result.try(parse_auth_json_file(raw))
  case access_token_is_expired(auth_file.tokens.access_token, time.now_ms()) {
    True -> refresh_auth_file(path, auth_file)
    False -> Ok(auth_from_file(auth_file))
  }
}

pub fn parse_auth_json(raw: String) -> Result(CodexAuth, String) {
  parse_auth_json_file(raw)
  |> result.map(auth_from_file)
}

pub fn parse_auth_json_file(raw: String) -> Result(CodexAuthFile, String) {
  let tokens_decoder = {
    use id_token <- optional_string("id_token")
    use access_token <- dyn_decode.field("access_token", dyn_decode.string)
    use refresh_token <- optional_string("refresh_token")
    use account_id <- optional_string("account_id")
    dyn_decode.success(CodexTokens(
      id_token: id_token,
      access_token: access_token,
      refresh_token: refresh_token,
      account_id: account_id,
    ))
  }
  let decoder = {
    use auth_mode <- optional_string("auth_mode")
    use openai_api_key <- optional_string("OPENAI_API_KEY")
    use tokens <- dyn_decode.field("tokens", tokens_decoder)
    use last_refresh <- optional_string("last_refresh")
    use agent_identity <- optional_string("agent_identity")
    dyn_decode.success(CodexAuthFile(
      auth_mode: auth_mode,
      openai_api_key: openai_api_key,
      tokens: tokens,
      last_refresh: last_refresh,
      agent_identity: agent_identity,
    ))
  }

  json.parse(raw, decoder)
  |> result.map_error(fn(err) {
    "Failed to decode Codex auth.json; expected tokens.access_token"
    <> " and optional tokens.account_id: "
    <> string.inspect(err)
  })
}

/// Force-refresh file-backed Codex OAuth credentials and persist any rotated
/// access/refresh tokens back to the Codex CLI auth file.
pub fn refresh_from_auth_json() -> Result(CodexAuth, String) {
  use path <- result.try(auth_json_path())
  use raw <- result.try(read_auth_json(path))
  use auth_file <- result.try(parse_auth_json_file(raw))
  refresh_auth_file(path, auth_file)
}

pub fn access_token_is_expired(access_token: String, now_ms: Int) -> Bool {
  case jwt_expires_at_ms(access_token) {
    Ok(expires_at_ms) -> expires_at_ms <= now_ms + expiry_buffer_ms
    Error(_) -> False
  }
}

pub fn jwt_expires_at_ms(jwt: String) -> Result(Int, String) {
  let parts = string.split(jwt, ".")
  use payload <- result.try(case parts {
    [_header, payload, _signature] -> Ok(payload)
    _ -> Error("invalid JWT format")
  })
  use decoded <- result.try(
    bit_array.base64_url_decode(payload)
    |> result.map_error(fn(_) { "invalid JWT payload base64" }),
  )
  use payload_json <- result.try(
    bit_array.to_string(decoded)
    |> result.map_error(fn(_) { "invalid JWT payload UTF-8" }),
  )
  json.parse(payload_json, dyn_decode.at(["exp"], dyn_decode.int))
  |> result.map(fn(exp_s) { exp_s * 1000 })
  |> result.map_error(fn(err) {
    "failed to decode JWT exp: " <> string.inspect(err)
  })
}

pub fn apply_refresh_response(
  auth_file: CodexAuthFile,
  body: String,
  now_ms: Int,
) -> Result(CodexAuthFile, String) {
  use refresh <- result.try(parse_refresh_response(body))
  let old = auth_file.tokens
  let updated = CodexTokens(
    id_token: option_string(refresh.id_token, old.id_token),
    access_token: option_string(refresh.access_token, old.access_token),
    refresh_token: option_string(refresh.refresh_token, old.refresh_token),
    account_id: old.account_id,
  )
  Ok(CodexAuthFile(
    ..auth_file,
    tokens: updated,
    last_refresh: time.format_ms_rfc3339_utc(now_ms),
  ))
}

fn refresh_auth_file(
  path: String,
  auth_file: CodexAuthFile,
) -> Result(CodexAuth, String) {
  case auth_file.tokens.refresh_token {
    "" ->
      Error(
        "Codex auth.json has no refresh token; run `codex login` again or set AURA_OPENAI_CODEX_ACCESS_TOKEN",
      )
    refresh_token -> {
      use body <- result.try(request_token_refresh(refresh_token))
      use updated <- result.try(
        apply_refresh_response(auth_file, body, time.now_ms()),
      )
      use _ <- result.try(write_auth_json(path, updated))
      Ok(auth_from_file(updated))
    }
  }
}

fn request_token_refresh(refresh_token: String) -> Result(String, String) {
  let endpoint =
    env.get_env("CODEX_REFRESH_TOKEN_URL_OVERRIDE")
    |> result.unwrap(refresh_token_url)
  use parsed_uri <- result.try(
    uri.parse(endpoint)
    |> result.map_error(fn(_) {
      "Failed to parse Codex refresh endpoint: " <> endpoint
    }),
  )
  use req <- result.try(
    request.from_uri(parsed_uri)
    |> result.map_error(fn(_) {
      "Failed to build Codex refresh request for: " <> endpoint
    }),
  )
  let body =
    json.object([
      #("client_id", json.string(codex_client_id)),
      #("grant_type", json.string("refresh_token")),
      #("refresh_token", json.string(refresh_token)),
    ])
    |> json.to_string
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(120_000)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) {
      "Codex OAuth refresh failed: HTTP request failed: " <> string.inspect(e)
    }),
  )
  case resp.status {
    200 -> Ok(resp.body)
    status ->
      Error(
        "Codex OAuth refresh failed: status "
        <> int.to_string(status)
        <> " body "
        <> string.slice(resp.body, 0, 400),
      )
  }
}

fn parse_refresh_response(body: String) -> Result(RefreshResponse, String) {
  let decoder = {
    use id_token <- optional_string_option("id_token")
    use access_token <- optional_string_option("access_token")
    use refresh_token <- optional_string_option("refresh_token")
    dyn_decode.success(RefreshResponse(
      id_token: id_token,
      access_token: access_token,
      refresh_token: refresh_token,
    ))
  }
  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    "Codex OAuth refresh failed: malformed response: " <> string.inspect(err)
  })
}

fn auth_from_file(auth_file: CodexAuthFile) -> CodexAuth {
  CodexAuth(
    access_token: auth_file.tokens.access_token,
    account_id: auth_file.tokens.account_id,
  )
}

fn read_auth_json(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(e) {
    "Failed to read Codex auth.json at "
    <> path
    <> ": "
    <> simplifile.describe_error(e)
  })
}

fn write_auth_json(path: String, auth_file: CodexAuthFile) -> Result(Nil, String) {
  simplifile.write(path, auth_file_to_json(auth_file))
  |> result.map_error(fn(e) {
    "Failed to write refreshed Codex auth.json at "
    <> path
    <> ": "
    <> simplifile.describe_error(e)
  })
}

fn auth_file_to_json(auth_file: CodexAuthFile) -> String {
  let tokens = auth_file.tokens
  let fields = [
    #("auth_mode", json.string(coalesce(auth_file.auth_mode, "chatgpt"))),
    #("OPENAI_API_KEY", nullable_string(auth_file.openai_api_key)),
    #(
      "tokens",
      json.object([
        #("id_token", json.string(tokens.id_token)),
        #("access_token", json.string(tokens.access_token)),
        #("refresh_token", json.string(tokens.refresh_token)),
        #("account_id", nullable_string(tokens.account_id)),
      ]),
    ),
    #(
      "last_refresh",
      json.string(coalesce(
        auth_file.last_refresh,
        time.format_ms_rfc3339_utc(time.now_ms()),
      )),
    ),
  ]
  let fields = case auth_file.agent_identity {
    "" -> fields
    agent_identity ->
      list.append(fields, [#("agent_identity", json.string(agent_identity))])
  }
  json.object(fields) |> json.to_string
}

fn nullable_string(value: String) -> json.Json {
  case value {
    "" -> json.null()
    _ -> json.string(value)
  }
}

fn optional_string(
  field_name: String,
  next: fn(String) -> dyn_decode.Decoder(a),
) -> dyn_decode.Decoder(a) {
  use value <- dyn_decode.optional_field(
    field_name,
    None,
    dyn_decode.optional(dyn_decode.string),
  )
  next(option_string(value, ""))
}

fn optional_string_option(
  field_name: String,
  next: fn(Option(String)) -> dyn_decode.Decoder(a),
) -> dyn_decode.Decoder(a) {
  use value <- dyn_decode.optional_field(
    field_name,
    None,
    dyn_decode.optional(dyn_decode.string),
  )
  next(value)
}

fn option_string(value: Option(String), default: String) -> String {
  case value {
    Some(v) -> v
    None -> default
  }
}

fn coalesce(value: String, default: String) -> String {
  case value {
    "" -> default
    _ -> value
  }
}
