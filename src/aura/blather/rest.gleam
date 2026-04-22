//// REST client for the Blather messaging platform. Authed with an
//// `X-API-Key: blather_<hex>` header. The base URL is whatever the
//// operator configures in `[blather] url = ...` and should already
//// include any reverse-proxy prefix (e.g. `http://10.0.0.2:18100/api`
//// when Blather sits behind nginx that strips `/api`). Must not end
//// with a trailing slash — paths are appended with a leading `/`.
////
//// Each operation is split into a pure `build_*_request` that returns a
//// fully-formed `request.Request(String)` and a public function that
//// dispatches the request and parses the response. The split lets tests
//// verify URL / headers / body shape without sending over the network.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import gleam/string
import gleam/uri
import logging

// ---------------------------------------------------------------------------
// Pure request builders (testable)
// ---------------------------------------------------------------------------

pub fn build_send_request(
  base_url: String,
  api_key: String,
  channel_id: String,
  content: String,
) -> Result(request.Request(String), String) {
  let url = base_url <> "/channels/" <> channel_id <> "/messages"
  let body =
    json.object([#("content", json.string(content))])
    |> json.to_string()
  use req <- result.try(authed_request(url, http.Post, api_key))
  Ok(
    req
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body),
  )
}

pub fn build_edit_request(
  base_url: String,
  api_key: String,
  channel_id: String,
  message_id: String,
  content: String,
) -> Result(request.Request(String), String) {
  let url =
    base_url <> "/channels/" <> channel_id <> "/messages/" <> message_id
  let body =
    json.object([#("content", json.string(content))])
    |> json.to_string()
  use req <- result.try(authed_request(url, http.Patch, api_key))
  Ok(
    req
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body),
  )
}

pub fn build_typing_request(
  base_url: String,
  api_key: String,
  channel_id: String,
) -> Result(request.Request(String), String) {
  let url = base_url <> "/channels/" <> channel_id <> "/typing"
  authed_request(url, http.Post, api_key)
}

// ---------------------------------------------------------------------------
// Public send functions
// ---------------------------------------------------------------------------

/// POST /channels/:id/messages — send a text message. Returns the new
/// message id on success.
pub fn send_message(
  base_url: String,
  api_key: String,
  channel_id: String,
  content: String,
) -> Result(String, String) {
  logging.log(
    logging.Info,
    "[blather] Sending "
      <> int.to_string(string.length(content))
      <> " chars to "
      <> channel_id,
  )
  use req <- result.try(build_send_request(
    base_url,
    api_key,
    channel_id,
    content,
  ))
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 | 201 ->
      json.parse(resp.body, decode.at(["id"], decode.string))
      |> result.map_error(fn(_) { "Failed to parse message id" })
    status -> Error(unexpected_status(status, "send message"))
  }
}

/// PATCH /channels/:channelId/messages/:messageId — edit an existing
/// message in place. Body: `{ "content": "..." }`.
pub fn edit_message(
  base_url: String,
  api_key: String,
  channel_id: String,
  message_id: String,
  content: String,
) -> Result(Nil, String) {
  use req <- result.try(build_edit_request(
    base_url,
    api_key,
    channel_id,
    message_id,
    content,
  ))
  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )
  case resp.status {
    200 -> Ok(Nil)
    status -> Error(unexpected_status(status, "edit message"))
  }
}

/// POST /channels/:id/typing — fire the typing indicator. 204 on success.
pub fn trigger_typing(
  base_url: String,
  api_key: String,
  channel_id: String,
) -> Result(Nil, String) {
  use req <- result.try(build_typing_request(base_url, api_key, channel_id))
  case httpc.send(req) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("Failed to trigger typing")
  }
}

// ---------------------------------------------------------------------------
// Helpers
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
  api_key: String,
) -> Result(request.Request(String), String) {
  use req <- result.try(build_request(url))
  Ok(
    req
    |> request.set_method(method)
    |> request.set_header("x-api-key", api_key),
  )
}

pub fn unexpected_status(status: Int, context: String) -> String {
  "Blather "
  <> context
  <> " returned unexpected status "
  <> int.to_string(status)
}
