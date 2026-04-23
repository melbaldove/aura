//// One-time OAuth setup CLI flow for Gmail (and future providers).
////
//// Google deprecated the out-of-band (OOB) redirect flow for new
//// clients, so we use a loopback redirect URI (`http://localhost/`)
//// and ask the user to paste the redirected URL back to AURA. No
//// HTTP server required — the user's browser will show a "can't
//// connect" error on redirect, but the code lives in the address
//// bar. User copies the URL, we parse the `code` query parameter.
////
//// Env vars required:
////   GMAIL_OAUTH_CLIENT_ID      — from Google Cloud Console OAuth client
////   GMAIL_OAUTH_CLIENT_SECRET  — ditto
////
//// Output: writes TokenSet to ~/.config/aura/tokens/gmail-<email>.json.

import aura/env
import aura/oauth
import aura/time
import aura/xdg
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/uri

const gmail_scope = "https://mail.google.com/"

const redirect_uri = "http://localhost/"

const auth_endpoint = "https://accounts.google.com/o/oauth2/v2/auth"

const token_endpoint = "https://oauth2.googleapis.com/token"

/// Run the Gmail OAuth setup flow.
pub fn run_gmail(email: String) -> Result(String, String) {
  use client_id <- result.try(require_env("GMAIL_OAUTH_CLIENT_ID"))
  use client_secret <- result.try(require_env("GMAIL_OAUTH_CLIENT_SECRET"))

  let url = build_auth_url(client_id)
  io.println("")
  io.println(
    "Open this URL in your browser, approve access, then copy the",
  )
  io.println(
    "URL your browser is redirected to (it will likely show a",
  )
  io.println("\"can't connect\" error — that's fine):")
  io.println("")
  io.println(url)
  io.println("")
  io.println("Paste the redirected URL here and press Enter:")

  use pasted <- result.try(read_line())
  use code <- result.try(extract_code(string.trim(pasted)))

  let oauth_config =
    oauth.OAuthConfig(
      client_id: client_id,
      client_secret: client_secret,
      token_endpoint: token_endpoint,
    )

  let now = time.now_ms()
  use tokens <- result.try(oauth.exchange_authorization_code(
    oauth_config,
    code,
    redirect_uri,
    now_ms: now,
  ))

  let paths = xdg.resolve()
  let token_path = token_path_for(paths, email)
  use _ <- result.try(oauth.save_token_set(token_path, tokens))

  Ok(token_path)
}

/// Build the OAuth 2.0 authorization URL for Gmail scope. Pure.
/// Exposed so the CLI flow and tests share one definition.
pub fn build_auth_url(client_id: String) -> String {
  let params =
    [
      #("client_id", client_id),
      #("redirect_uri", redirect_uri),
      #("response_type", "code"),
      #("scope", gmail_scope),
      #("access_type", "offline"),
      #("prompt", "consent"),
    ]
    |> list.map(fn(pair) {
      let #(k, v) = pair
      uri.percent_encode(k) <> "=" <> uri.percent_encode(v)
    })
    |> string.join("&")
  auth_endpoint <> "?" <> params
}

/// Parse the `code` query parameter from a pasted redirect URL. Pure.
/// Accepts either the full `http://localhost/?code=XXX&...` or just
/// the query string. Returns `Error("no code param in ...")` on miss.
pub fn extract_code(pasted: String) -> Result(String, String) {
  // Split on '?' to isolate query; if no '?', treat whole string as query.
  let query = case string.split_once(pasted, on: "?") {
    Ok(#(_, q)) -> q
    Error(_) -> pasted
  }
  let pairs = string.split(query, on: "&")
  let code =
    list.find_map(pairs, fn(pair) {
      case string.split_once(pair, on: "=") {
        Ok(#("code", value)) -> {
          case uri.percent_decode(value) {
            Ok(decoded) -> Ok(decoded)
            Error(_) -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
    })
  case code {
    Ok(c) if c != "" -> Ok(c)
    _ -> Error("no code= parameter found in pasted URL")
  }
}

/// Build the token file path from an email: XDG_CONFIG/aura/tokens/gmail-<local>.json.
/// Uses the full email if no @ present.
pub fn token_path_for(paths: xdg.Paths, email: String) -> String {
  let local = case string.split_once(email, on: "@") {
    Ok(#(l, _)) -> l
    Error(_) -> email
  }
  paths.config <> "/tokens/gmail-" <> local <> ".json"
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn require_env(name: String) -> Result(String, String) {
  case env.get_env(name) {
    Ok(v) if v != "" -> Ok(v)
    _ -> Error("env var " <> name <> " not set")
  }
}

@external(erlang, "io", "get_line")
fn io_get_line(prompt: String) -> String

fn read_line() -> Result(String, String) {
  // `io:get_line/1` returns the line including trailing newline, or eof atom
  // on empty input. If we ever get an atom back, the string will be "eof" —
  // treat that as an error. Happy path returns a user-pasted URL.
  let line = io_get_line("")
  case string.trim(line) {
    "" -> Error("no input provided")
    "eof" -> Error("stdin closed before input received")
    s -> Ok(s)
  }
}

