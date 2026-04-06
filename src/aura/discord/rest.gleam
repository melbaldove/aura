import aura/discord/types.{type Embed}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/uri

const base_url = "https://discord.com/api/v10"

/// Prepend the Discord API base URL to a path.
fn api_url(path: String) -> String {
  base_url <> path
}

/// Build the Authorization header tuple for a bot token.
fn auth_header(token: String) -> #(String, String) {
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
/// Returns the message ID on success.
pub fn send_message(
  token: String,
  channel_id: String,
  content: String,
  embeds: List(Embed),
) -> Result(String, String) {
  io.println("[discord] Sending " <> int.to_string(string.length(content)) <> " chars to " <> channel_id)
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
    200 | 201 -> {
      // Parse message ID from response
      case json.parse(resp.body, decode.at(["id"], decode.string)) {
        Ok(id) -> Ok(id)
        Error(_) -> {
          io.println("[discord] Failed to parse message ID from send response")
          Ok("")
        }
      }
    }
    status -> {
      io.println("[discord] Error sending to " <> channel_id <> ": status " <> int.to_string(status))
      Error(unexpected_status(status, "send message"))
    }
  }
}

/// PATCH /channels/{channel_id}/messages/{message_id} — edit a message.
pub fn edit_message(
  token: String,
  channel_id: String,
  message_id: String,
  content: String,
) -> Result(Nil, String) {
  io.println(
    "[discord] Editing message " <> message_id <> " in " <> channel_id,
  )
  let url =
    api_url("/channels/" <> channel_id <> "/messages/" <> message_id)
  let body =
    json.object([#("content", json.string(content))]) |> json.to_string()
  use req <- result.try(authed_request(url, http.Patch, token))
  let req =
    req
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(10_000)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) {
      "HTTP request failed: " <> string.inspect(e)
    }),
  )
  case resp.status {
    200 -> Ok(Nil)
    status -> {
      io.println(
        "[discord] Error editing message: status "
        <> int.to_string(status),
      )
      Error(unexpected_status(status, "edit message"))
    }
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

/// GET /guilds/{guild_id}/channels — list text channels.
/// Returns list of (name, id) tuples for text channels (type 0).
pub fn list_channels(
  token: String,
  guild_id: String,
) -> Result(List(#(String, String)), String) {
  let url = api_url("/guilds/" <> guild_id <> "/channels")
  use req <- result.try(authed_request(url, http.Get, token))
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 -> {
      let channel_decoder =
        decode.list({
          use id <- decode.field("id", decode.string)
          use name <- decode.field("name", decode.string)
          use channel_type <- decode.field("type", decode.int)
          decode.success(#(name, id, channel_type))
        })
      case json.parse(resp.body, channel_decoder) {
        Ok(channels) -> {
          // Filter to text channels (type 0) and return (name, id)
          Ok(list.filter_map(channels, fn(c) {
            let #(name, id, t) = c
            case t {
              0 -> Ok(#(name, id))
              _ -> Error(Nil)
            }
          }))
        }
        Error(_) -> Error("Failed to parse channels from response")
      }
    }
    status -> Error(unexpected_status(status, "guild channels"))
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

/// GET /guilds/{guild_id}/threads/active — list active threads.
/// Returns list of (id, name, parent_id) tuples.
pub fn get_active_threads(
  token: String,
  guild_id: String,
) -> Result(List(#(String, String, String)), String) {
  let url = api_url("/guilds/" <> guild_id <> "/threads/active")
  use req <- result.try(authed_request(url, http.Get, token))
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 -> {
      let thread_decoder =
        decode.at(["threads"], decode.list({
          use id <- decode.field("id", decode.string)
          use name <- decode.field("name", decode.string)
          use parent_id <- decode.optional_field("parent_id", "", decode.string)
          decode.success(#(id, name, parent_id))
        }))
      json.parse(resp.body, thread_decoder)
      |> result.map_error(fn(_) { "Failed to parse threads from response" })
    }
    status -> Error(unexpected_status(status, "guild threads"))
  }
}

/// GET /channels/{channel_id}/messages — fetch recent messages.
/// Returns list of (author_name, content) tuples, most recent first.
pub fn get_channel_messages(
  token: String,
  channel_id: String,
  limit: Int,
) -> Result(List(#(String, String)), String) {
  let url = api_url("/channels/" <> channel_id <> "/messages?limit=" <> int.to_string(limit))
  use req <- result.try(authed_request(url, http.Get, token))
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 -> {
      let msg_decoder =
        decode.list({
          use author_name <- decode.subfield(["author", "username"], decode.string)
          use content <- decode.optional_field("content", "", decode.string)
          decode.success(#(author_name, content))
        })
      json.parse(resp.body, msg_decoder)
      |> result.map_error(fn(_) { "Failed to parse messages from response" })
    }
    status -> Error(unexpected_status(status, "channel messages"))
  }
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

/// POST /channels/{channel_id}/messages/{message_id}/threads — create a thread from a message.
/// Returns the thread channel ID on success.
pub fn create_thread_from_message(
  token: String,
  channel_id: String,
  message_id: String,
  name: String,
) -> Result(String, String) {
  let url =
    api_url(
      "/channels/" <> channel_id <> "/messages/" <> message_id <> "/threads",
    )
  let body =
    json.object([
      #("name", json.string(string.slice(name, 0, 100))),
      #("auto_archive_duration", json.int(1440)),
    ])
    |> json.to_string()
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
    200 | 201 -> {
      case json.parse(resp.body, decode.at(["id"], decode.string)) {
        Ok(id) -> Ok(id)
        Error(_) -> Error("Failed to parse thread ID from response")
      }
    }
    status -> Error(unexpected_status(status, "create thread from message"))
  }
}

fn unexpected_status(status: Int, context: String) -> String {
  "Unexpected status " <> int.to_string(status) <> " from " <> context
}
