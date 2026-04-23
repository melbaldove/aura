import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import simplifile

pub type OAuthConfig {
  OAuthConfig(
    client_id: String,
    client_secret: String,
    token_endpoint: String,
  )
}

pub type TokenSet {
  TokenSet(access_token: String, refresh_token: String, expires_at_ms: Int)
}

const expiry_buffer_ms = 60_000

/// Load a `TokenSet` from a JSON file on disk.
pub fn load_token_set(path: String) -> Result(TokenSet, String) {
  use raw <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) {
      "Failed to read token file "
      <> path
      <> ": "
      <> simplifile.describe_error(e)
    }),
  )
  token_set_from_json(raw)
}

/// Save a `TokenSet` to a JSON file, overwriting any existing content.
pub fn save_token_set(path: String, tokens: TokenSet) -> Result(Nil, String) {
  use _ <- result.try(ensure_parent_dir(path))
  simplifile.write(path, token_set_to_json(tokens))
  |> result.map_error(fn(e) {
    "Failed to write token file "
    <> path
    <> ": "
    <> simplifile.describe_error(e)
  })
}

pub fn ensure_parent_dir(path: String) -> Result(Nil, String) {
  case string.split_once(string.reverse(path), on: "/") {
    Ok(#(_, rest)) -> {
      let parent = string.reverse(rest)
      simplifile.create_directory_all(parent)
      |> result.map_error(fn(e) {
        "Failed to create "
        <> parent
        <> ": "
        <> simplifile.describe_error(e)
      })
    }
    Error(_) -> Ok(Nil)
  }
}

/// `True` when `access_token` is already expired or will expire within the
/// 60-second buffer. Callers should treat `True` as "refresh before use".
pub fn is_expired(tokens: TokenSet, now_ms now_ms: Int) -> Bool {
  tokens.expires_at_ms <= now_ms + expiry_buffer_ms
}

/// Exchange a refresh token for a new access token via
/// `grant_type=refresh_token`. Returns a fresh `TokenSet`; if the provider
/// response omits a new refresh token, the existing one is preserved.
pub fn refresh(
  config: OAuthConfig,
  tokens: TokenSet,
  now_ms now_ms: Int,
) -> Result(TokenSet, String) {
  let body =
    form_encode([
      #("grant_type", "refresh_token"),
      #("refresh_token", tokens.refresh_token),
      #("client_id", config.client_id),
      #("client_secret", config.client_secret),
    ])
  use parsed_uri <- result.try(
    uri.parse(config.token_endpoint)
    |> result.map_error(fn(_) {
      "Failed to parse token endpoint: " <> config.token_endpoint
    }),
  )
  use req <- result.try(
    request.from_uri(parsed_uri)
    |> result.map_error(fn(_) {
      "Failed to build request for token endpoint: " <> config.token_endpoint
    }),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(e) {
      "oauth refresh failed: HTTP request failed: " <> string.inspect(e)
    }),
  )
  case resp.status {
    200 -> parse_refresh_response(resp.body, tokens, now_ms)
    status ->
      Error(
        "oauth refresh failed: status "
        <> int.to_string(status)
        <> " body "
        <> resp.body,
      )
  }
}

/// Exchange an authorization code for a new TokenSet (access + refresh).
/// Used by the one-time setup flow (CLI command); production runtime
/// uses `refresh` / `ensure_fresh` against the stored TokenSet.
pub fn exchange_authorization_code(
  config: OAuthConfig,
  code: String,
  redirect_uri: String,
  now_ms now_ms: Int,
) -> Result(TokenSet, String) {
  let body =
    form_encode([
      #("grant_type", "authorization_code"),
      #("code", code),
      #("client_id", config.client_id),
      #("client_secret", config.client_secret),
      #("redirect_uri", redirect_uri),
    ])
  use parsed_uri <- result.try(
    uri.parse(config.token_endpoint)
    |> result.map_error(fn(_) {
      "Failed to parse token endpoint: " <> config.token_endpoint
    }),
  )
  use req <- result.try(
    request.from_uri(parsed_uri)
    |> result.map_error(fn(_) {
      "Failed to build request for token endpoint: " <> config.token_endpoint
    }),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(e) {
      "oauth exchange failed: HTTP request failed: " <> string.inspect(e)
    }),
  )
  case resp.status {
    200 -> parse_exchange_response(resp.body, now_ms)
    status ->
      Error(
        "oauth exchange failed: status "
        <> int.to_string(status)
        <> " body "
        <> resp.body,
      )
  }
}

/// Return `tokens` unchanged when still fresh; otherwise exchange the
/// refresh token for a new access token.
pub fn ensure_fresh(
  config: OAuthConfig,
  tokens: TokenSet,
  now_ms now_ms: Int,
) -> Result(TokenSet, String) {
  case is_expired(tokens, now_ms: now_ms) {
    False -> Ok(tokens)
    True -> refresh(config, tokens, now_ms: now_ms)
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn token_set_to_json(tokens: TokenSet) -> String {
  json.object([
    #("access_token", json.string(tokens.access_token)),
    #("refresh_token", json.string(tokens.refresh_token)),
    #("expires_at_ms", json.int(tokens.expires_at_ms)),
  ])
  |> json.to_string
}

fn token_set_from_json(raw: String) -> Result(TokenSet, String) {
  let decoder = {
    use access_token <- decode.field("access_token", decode.string)
    use refresh_token <- decode.field("refresh_token", decode.string)
    use expires_at_ms <- decode.field("expires_at_ms", decode.int)
    decode.success(TokenSet(
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at_ms: expires_at_ms,
    ))
  }
  json.parse(raw, decoder)
  |> result.map_error(fn(err) {
    "Failed to decode token JSON: " <> string.inspect(err)
  })
}

fn parse_refresh_response(
  body: String,
  old: TokenSet,
  now_ms: Int,
) -> Result(TokenSet, String) {
  let decoder = {
    use access_token <- decode.field("access_token", decode.string)
    use expires_in <- decode.field("expires_in", decode.int)
    use new_refresh <- decode.optional_field(
      "refresh_token",
      old.refresh_token,
      decode.string,
    )
    decode.success(TokenSet(
      access_token: access_token,
      refresh_token: new_refresh,
      expires_at_ms: now_ms + expires_in * 1000,
    ))
  }
  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    "oauth refresh failed: malformed response: " <> string.inspect(err)
  })
}

fn parse_exchange_response(
  body: String,
  now_ms: Int,
) -> Result(TokenSet, String) {
  let decoder = {
    use access_token <- decode.field("access_token", decode.string)
    use expires_in <- decode.field("expires_in", decode.int)
    use refresh_token <- decode.field("refresh_token", decode.string)
    decode.success(TokenSet(
      access_token: access_token,
      refresh_token: refresh_token,
      expires_at_ms: now_ms + expires_in * 1000,
    ))
  }
  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    "oauth exchange failed: malformed response: " <> string.inspect(err)
  })
}

fn form_encode(pairs: List(#(String, String))) -> String {
  pairs
  |> list.map(fn(pair) {
    let #(k, v) = pair
    uri.percent_encode(k) <> "=" <> uri.percent_encode(v)
  })
  |> string.join("&")
}
