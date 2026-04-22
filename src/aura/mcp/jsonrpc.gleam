import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A JSON-RPC 2.0 request/response id. Per spec, id may be an int, a string,
/// or null — this codec supports int and string, which covers the MCP surface.
pub type Id {
  IntId(Int)
  StringId(String)
}

/// The body of a response. `Success` carries a `result` value; `Failure`
/// carries an error object (code + message + optional data).
///
/// Naming note: the JSON-RPC spec calls these "result" and "error". We use
/// `Success` / `Failure` here because `Ok` / `Error` collide with Gleam's
/// prelude Result constructors inside this module.
pub type ResponseBody {
  Success(result: json.Json)
  Failure(code: Int, message: String, data: Option(json.Json))
}

/// A JSON-RPC 2.0 message. Requests and responses are correlated by `id`;
/// notifications have no id and receive no response.
pub type Message {
  Request(id: Id, method: String, params: Option(json.Json))
  Response(id: Id, body: ResponseBody)
  Notification(method: String, params: Option(json.Json))
}

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// Build a request with an integer id and params object.
pub fn request(id: Int, method: String, params: json.Json) -> Message {
  Request(id: IntId(id), method: method, params: Some(params))
}

/// Build a request with an integer id and no params.
pub fn request_no_params(id: Int, method: String) -> Message {
  Request(id: IntId(id), method: method, params: None)
}

/// Build a notification (no id) with params.
pub fn notification(method: String, params: json.Json) -> Message {
  Notification(method: method, params: Some(params))
}

/// Build a notification (no id) with no params.
pub fn notification_no_params(method: String) -> Message {
  Notification(method: method, params: None)
}

/// Build a success response for the given integer id.
pub fn success_response(id: Int, result: json.Json) -> Message {
  Response(id: IntId(id), body: Success(result: result))
}

/// Build an error response for the given integer id.
pub fn error_response(id: Int, code: Int, message: String) -> Message {
  Response(
    id: IntId(id),
    body: Failure(code: code, message: message, data: None),
  )
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Encode a Message into a JSON-RPC 2.0 wire string.
///
/// Notifications and requests with no params omit the "params" key (lighter
/// wire than an explicit null; MCP servers accept both shapes).
pub fn encode(msg: Message) -> String {
  msg
  |> to_json
  |> json.to_string
}

fn to_json(msg: Message) -> json.Json {
  case msg {
    Request(id, method, params) ->
      json.object(
        [
          #("jsonrpc", json.string("2.0")),
          #("id", id_to_json(id)),
          #("method", json.string(method)),
        ]
        |> append_params(params),
      )
    Notification(method, params) ->
      json.object(
        [
          #("jsonrpc", json.string("2.0")),
          #("method", json.string(method)),
        ]
        |> append_params(params),
      )
    Response(id, Success(result)) ->
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("id", id_to_json(id)),
        #("result", result),
      ])
    Response(id, Failure(code, message, data)) -> {
      let error_body =
        [#("code", json.int(code)), #("message", json.string(message))]
        |> append_data(data)
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("id", id_to_json(id)),
        #("error", json.object(error_body)),
      ])
    }
  }
}

fn id_to_json(id: Id) -> json.Json {
  case id {
    IntId(n) -> json.int(n)
    StringId(s) -> json.string(s)
  }
}

fn append_params(
  fields: List(#(String, json.Json)),
  params: Option(json.Json),
) -> List(#(String, json.Json)) {
  case params {
    Some(p) -> list.append(fields, [#("params", p)])
    None -> fields
  }
}

fn append_data(
  fields: List(#(String, json.Json)),
  data: Option(json.Json),
) -> List(#(String, json.Json)) {
  case data {
    Some(d) -> list.append(fields, [#("data", d)])
    None -> fields
  }
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Decode a JSON-RPC 2.0 wire string into a Message.
///
/// Shape rules:
/// - Missing or non-"2.0" `jsonrpc` → Error.
/// - `method` + `id`, no `result`/`error` → Request.
/// - `id` + `result` xor `error` → Response.
/// - `method`, no `id` → Notification.
/// - Both `result` and `error`, or neither method/result/error → Error.
pub fn decode(raw: String) -> Result(Message, String) {
  case json.parse(raw, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) -> decode_fields(fields)
    Error(_) -> Error("invalid JSON")
  }
}

fn decode_fields(fields: Dict(String, Dynamic)) -> Result(Message, String) {
  use _ <- result.try(check_version(fields))
  let method = optional_string(fields, "method")
  let id = optional_id(fields, "id")
  let has_result = dict.has_key(fields, "result")
  let has_error = dict.has_key(fields, "error")
  case method, id, has_result, has_error {
    // Both result and error is invalid per spec.
    _, _, True, True -> Error("both result and error present")
    // Request: method + id, no result/error.
    Some(m), Some(id_val), False, False -> {
      let params = dict_to_json(fields, "params")
      Ok(Request(id: id_val, method: m, params: params))
    }
    // Notification: method, no id, no result/error.
    Some(m), None, False, False -> {
      let params = dict_to_json(fields, "params")
      Ok(Notification(method: m, params: params))
    }
    // Success response: id + result, no method, no error.
    None, Some(id_val), True, False -> {
      use result_json <- result.try(
        dict_to_json(fields, "result")
        |> option.to_result("missing result"),
      )
      Ok(Response(id: id_val, body: Success(result: result_json)))
    }
    // Error response: id + error, no method, no result.
    None, Some(id_val), False, True -> {
      use err_body <- result.try(decode_error_body(fields))
      Ok(Response(id: id_val, body: err_body))
    }
    _, _, _, _ -> Error("unrecognised JSON-RPC message shape")
  }
}

fn check_version(fields: Dict(String, Dynamic)) -> Result(Nil, String) {
  case dict.get(fields, "jsonrpc") {
    Error(_) -> Error("missing jsonrpc field")
    Ok(value) ->
      case decode.run(value, decode.string) {
        Ok("2.0") -> Ok(Nil)
        Ok(other) -> Error("unsupported jsonrpc version: " <> other)
        Error(_) -> Error("jsonrpc field must be a string")
      }
  }
}

fn optional_string(fields: Dict(String, Dynamic), key: String) -> Option(String) {
  case dict.get(fields, key) {
    Error(_) -> None
    Ok(value) ->
      case decode.run(value, decode.string) {
        Ok(s) -> Some(s)
        Error(_) -> None
      }
  }
}

fn optional_id(fields: Dict(String, Dynamic), key: String) -> Option(Id) {
  case dict.get(fields, key) {
    Error(_) -> None
    Ok(value) -> {
      let id_decoder =
        decode.one_of(decode.map(decode.int, IntId), or: [
          decode.map(decode.string, StringId),
        ])
      case decode.run(value, id_decoder) {
        Ok(id) -> Some(id)
        Error(_) -> None
      }
    }
  }
}

fn dict_to_json(
  fields: Dict(String, Dynamic),
  key: String,
) -> Option(json.Json) {
  case dict.get(fields, key) {
    Error(_) -> None
    Ok(value) -> Some(dynamic_to_json(value))
  }
}

fn decode_error_body(
  fields: Dict(String, Dynamic),
) -> Result(ResponseBody, String) {
  let assert Ok(err_dyn) = dict.get(fields, "error")
  let error_decoder = decode.dict(decode.string, decode.dynamic)
  case decode.run(err_dyn, error_decoder) {
    Error(_) -> Error("error field must be an object")
    Ok(err_fields) -> {
      use code <- result.try(
        dict.get(err_fields, "code")
        |> result.map_error(fn(_) { "missing error.code" })
        |> result.try(fn(v) {
          decode.run(v, decode.int)
          |> result.map_error(fn(_) { "error.code must be an integer" })
        }),
      )
      use message <- result.try(
        dict.get(err_fields, "message")
        |> result.map_error(fn(_) { "missing error.message" })
        |> result.try(fn(v) {
          decode.run(v, decode.string)
          |> result.map_error(fn(_) { "error.message must be a string" })
        }),
      )
      let data = dict_to_json(err_fields, "data")
      Ok(Failure(code: code, message: message, data: data))
    }
  }
}

// ---------------------------------------------------------------------------
// Dynamic → json.Json conversion
// ---------------------------------------------------------------------------
// JSON-RPC params/result/error.data are arbitrary JSON values. We decode them
// as Dynamic and re-encode to json.Json so Messages round-trip cleanly.

fn dynamic_to_json(value: Dynamic) -> json.Json {
  // Try each JSON primitive in turn. On Erlang, `json:decode` returns:
  //   binary (string), integer, float, true/false atom, null atom, list, map.
  case decode.run(value, decode.string) {
    Ok(s) -> json.string(s)
    Error(_) ->
      case decode.run(value, decode.int) {
        Ok(n) -> json.int(n)
        Error(_) ->
          case decode.run(value, decode.float) {
            Ok(f) -> json.float(f)
            Error(_) ->
              case decode.run(value, decode.bool) {
                Ok(b) -> json.bool(b)
                Error(_) ->
                  case decode.run(value, decode.list(decode.dynamic)) {
                    Ok(items) ->
                      json.preprocessed_array(
                        list.map(items, dynamic_to_json),
                      )
                    Error(_) ->
                      case
                        decode.run(
                          value,
                          decode.dict(decode.string, decode.dynamic),
                        )
                      {
                        Ok(d) ->
                          json.object(
                            dict.to_list(d)
                            |> list.map(fn(pair) {
                              #(pair.0, dynamic_to_json(pair.1))
                            }),
                          )
                        Error(_) -> json.null()
                      }
                  }
              }
          }
      }
  }
}
