import aura/blather/rest
import gleam/http
import gleam/http/request
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should

pub fn build_send_request_shape_test() {
  let req =
    rest.build_send_request(
      "http://10.0.0.2:18100/api",
      "blather_abc",
      "ch-42",
      "hello world",
    )
    |> should.be_ok

  req.method |> should.equal(http.Post)
  req.path
  |> should.equal("/api/channels/ch-42/messages")
  header_value(req, "x-api-key")
  |> should.equal("blather_abc")
  header_value(req, "content-type")
  |> should.equal("application/json")
  string.contains(req.body, "\"content\"") |> should.be_true
  string.contains(req.body, "hello world") |> should.be_true
}

pub fn build_send_request_escapes_content_json_test() {
  let req =
    rest.build_send_request("http://host", "k", "c", "quote \" and \\ slash")
    |> should.be_ok

  // JSON encoder must escape — raw characters would break the envelope.
  string.contains(req.body, "\\\"") |> should.be_true
  string.contains(req.body, "\\\\") |> should.be_true
}

pub fn build_edit_request_shape_test() {
  let req =
    rest.build_edit_request("http://host", "k", "ch-1", "msg-7", "new text")
    |> should.be_ok

  req.method |> should.equal(http.Patch)
  req.path |> should.equal("/channels/ch-1/messages/msg-7")
  header_value(req, "x-api-key") |> should.equal("k")
  string.contains(req.body, "new text") |> should.be_true
}

pub fn build_typing_request_shape_test() {
  let req =
    rest.build_typing_request("http://host", "k", "ch-42")
    |> should.be_ok

  req.method |> should.equal(http.Post)
  req.path |> should.equal("/channels/ch-42/typing")
  header_value(req, "x-api-key") |> should.equal("k")
  req.body |> should.equal("")
}

pub fn build_send_request_malformed_url_returns_error_test() {
  rest.build_send_request("not a url", "k", "ch", "hi")
  |> should.be_error
}

pub fn unexpected_status_formats_status_code_test() {
  rest.unexpected_status(500, "send message")
  |> should.equal("Blather send message returned unexpected status 500")
}

fn header_value(req: request.Request(String), key: String) -> String {
  list.find(req.headers, fn(h) { h.0 == key })
  |> result.map(fn(h) { h.1 })
  |> result.unwrap("")
}
