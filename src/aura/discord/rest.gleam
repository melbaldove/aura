import aura/discord/types.{type Embed}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import gleam/uri

const base_url = "https://discord.com/api/v10"

/// Prepend the Discord API base URL to a path.
pub fn api_url(path: String) -> String {
  base_url <> path
}

/// Build the Authorization header tuple for a bot token.
pub fn auth_header(token: String) -> #(String, String) {
  #("authorization", "Bot " <> token)
}

/// GET /gateway/bot — returns the WebSocket gateway URL.
pub fn get_gateway_url(token: String) -> Result(String, String) {
  let url = api_url("/gateway/bot")
  use req <- result.try(authed_request(url, http.Get, token))
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 ->
      json.parse(resp.body, decode.at(["url"], decode.string))
      |> result.map_error(fn(_) { "Failed to parse gateway URL from response" })
    status -> Error(unexpected_status(status, "gateway/bot"))
  }
}

/// POST /channels/{channel_id}/messages — send a message.
pub fn send_message(
  token: String,
  channel_id: String,
  content: String,
  embeds: List(Embed),
) -> Result(Nil, String) {
  let url = api_url("/channels/" <> channel_id <> "/messages")
  let body = types.create_message_payload(content, embeds) |> json.to_string()
  use req <- result.try(authed_request(url, http.Post, token))
  let req =
    req
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 | 201 -> Ok(Nil)
    status -> Error(unexpected_status(status, "send message"))
  }
}

/// POST /channels/{channel_id}/messages/{message_id}/threads — create a thread.
/// Returns the new thread channel ID.
pub fn create_thread(
  token: String,
  channel_id: String,
  message_id: String,
  name: String,
) -> Result(String, String) {
  let url =
    api_url(
      "/channels/" <> channel_id <> "/messages/" <> message_id <> "/threads",
    )
  let body = json.to_string(json.object([#("name", json.string(name))]))
  use req <- result.try(authed_request(url, http.Post, token))
  let req =
    req
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 | 201 ->
      json.parse(resp.body, decode.at(["id"], decode.string))
      |> result.map_error(fn(_) { "Failed to parse thread ID from response" })
    status -> Error(unexpected_status(status, "create thread"))
  }
}

/// Validate a Discord bot token by calling GET /users/@me
/// Returns the bot's username on success.
pub fn validate_token(token: String) -> Result(String, String) {
  let url = api_url("/users/@me")
  use req <- result.try(authed_request(url, http.Get, token))
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 ->
      json.parse(resp.body, decode.at(["username"], decode.string))
      |> result.map_error(fn(_) { "Failed to parse username from response" })
    status -> Error(unexpected_status(status, "users/@me"))
  }
}

/// List guilds the bot is in.
/// Returns list of (id, name) tuples.
pub fn list_guilds(token: String) -> Result(List(#(String, String)), String) {
  let url = api_url("/users/@me/guilds")
  use req <- result.try(authed_request(url, http.Get, token))
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 -> {
      let guild_decoder =
        decode.list({
          use id <- decode.field("id", decode.string)
          use name <- decode.field("name", decode.string)
          decode.success(#(id, name))
        })
      json.parse(resp.body, guild_decoder)
      |> result.map_error(fn(_) { "Failed to parse guilds from response" })
    }
    status -> Error(unexpected_status(status, "users/@me/guilds"))
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn build_request(url: String) -> Result(request.Request(String), String) {
  use parsed <- result.try(
    uri.parse(url)
    |> result.map_error(fn(_) { "Failed to parse URL: " <> url }),
  )
  request.from_uri(parsed)
  |> result.map_error(fn(_) { "Failed to build request from URL: " <> url })
}

fn authed_request(
  url: String,
  method: http.Method,
  token: String,
) -> Result(request.Request(String), String) {
  use req <- result.try(build_request(url))
  let #(auth_key, auth_val) = auth_header(token)
  Ok(
    req
    |> request.set_method(method)
    |> request.set_header(auth_key, auth_val),
  )
}

/// POST /channels/{id}/typing — trigger typing indicator (lasts 10s or until message sent)
pub fn trigger_typing(token: String, channel_id: String) -> Result(Nil, String) {
  let url = api_url("/channels/" <> channel_id <> "/typing")
  use req <- result.try(authed_request(url, http.Post, token))
  case httpc.send(req) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("Failed to trigger typing")
  }
}

fn unexpected_status(status: Int, context: String) -> String {
  "Unexpected status " <> int.to_string(status) <> " from " <> context
}
