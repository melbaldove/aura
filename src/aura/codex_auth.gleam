import aura/env
import gleam/dynamic/decode as dyn_decode
import gleam/json
import gleam/result
import gleam/string
import simplifile

pub type CodexAuth {
  CodexAuth(access_token: String, account_id: String)
}

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
  parse_auth_json(raw)
}

pub fn parse_auth_json(raw: String) -> Result(CodexAuth, String) {
  let tokens_decoder = {
    use access_token <- dyn_decode.field("access_token", dyn_decode.string)
    use account_id <- dyn_decode.optional_field(
      "account_id",
      "",
      dyn_decode.string,
    )
    dyn_decode.success(CodexAuth(
      access_token: access_token,
      account_id: account_id,
    ))
  }
  let decoder = dyn_decode.at(["tokens"], tokens_decoder)

  json.parse(raw, decoder)
  |> result.map_error(fn(err) {
    "Failed to decode Codex auth.json; expected tokens.access_token"
    <> " and optional tokens.account_id: "
    <> string.inspect(err)
  })
}
