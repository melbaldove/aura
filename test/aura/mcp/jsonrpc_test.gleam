import aura/mcp/jsonrpc
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

pub fn encode_request_roundtrip_test() {
  let params =
    json.object([
      #("protocolVersion", json.string("2025-06-18")),
      #("clientInfo", json.object([#("name", json.string("aura"))])),
    ])
  let msg = jsonrpc.request(1, "initialize", params)
  let wire = jsonrpc.encode(msg)
  // Round-trip through the codec.
  let decoded = jsonrpc.decode(wire) |> should.be_ok
  case decoded {
    jsonrpc.Request(id, method, params_opt) -> {
      id |> should.equal(jsonrpc.IntId(1))
      method |> should.equal("initialize")
      case params_opt {
        Some(_) -> Nil
        None -> should.fail()
      }
    }
    _ -> should.fail()
  }
  // Independent wire parsing — the wire must have the right field names
  // and a present "params" key (not omitted, not null).
  let decoder = {
    use jsonrpc_ver <- decode.field("jsonrpc", decode.string)
    use id <- decode.field("id", decode.int)
    use method <- decode.field("method", decode.string)
    use has_params <- decode.optional_field("params", False, decode.success(True))
    decode.success(#(jsonrpc_ver, id, method, has_params))
  }
  let parsed = json.parse(wire, decoder) |> should.be_ok
  parsed.0 |> should.equal("2.0")
  parsed.1 |> should.equal(1)
  parsed.2 |> should.equal("initialize")
  parsed.3 |> should.equal(True)
}

pub fn encode_notification_with_params_wire_test() {
  let params = json.object([#("uri", json.string("gmail://inbox"))])
  let msg = jsonrpc.notification("notifications/resources/updated", params)
  let wire = jsonrpc.encode(msg)
  // Independent wire parsing — params key must be present with the expected uri.
  let params_decoder = {
    use uri <- decode.field("uri", decode.string)
    decode.success(uri)
  }
  let decoder = {
    use jsonrpc_ver <- decode.field("jsonrpc", decode.string)
    use method <- decode.field("method", decode.string)
    use uri <- decode.field("params", params_decoder)
    use has_id <- decode.optional_field("id", False, decode.success(True))
    decode.success(#(jsonrpc_ver, method, uri, has_id))
  }
  let parsed = json.parse(wire, decoder) |> should.be_ok
  parsed.0 |> should.equal("2.0")
  parsed.1 |> should.equal("notifications/resources/updated")
  parsed.2 |> should.equal("gmail://inbox")
  parsed.3 |> should.equal(False)
}

pub fn encode_request_no_params_wire_test() {
  let msg = jsonrpc.request_no_params(3, "tools/list")
  let wire = jsonrpc.encode(msg)
  // Independent wire parsing — params key must be ABSENT (not null).
  let decoder = {
    use jsonrpc_ver <- decode.field("jsonrpc", decode.string)
    use id <- decode.field("id", decode.int)
    use method <- decode.field("method", decode.string)
    use has_params <- decode.optional_field("params", False, decode.success(True))
    decode.success(#(jsonrpc_ver, id, method, has_params))
  }
  let parsed = json.parse(wire, decoder) |> should.be_ok
  parsed.0 |> should.equal("2.0")
  parsed.1 |> should.equal(3)
  parsed.2 |> should.equal("tools/list")
  parsed.3 |> should.equal(False)
}

pub fn encode_notification_no_params_test() {
  let msg = jsonrpc.notification_no_params("notifications/initialized")
  let wire = jsonrpc.encode(msg)
  // Must be a valid JSON object with method="notifications/initialized",
  // no id field, and no params key (omit > null for lighter wire).
  let decoder = {
    use jsonrpc_ver <- decode.field("jsonrpc", decode.string)
    use method <- decode.field("method", decode.string)
    use has_params <- decode.optional_field("params", False, decode.success(True))
    use has_id <- decode.optional_field("id", False, decode.success(True))
    decode.success(#(jsonrpc_ver, method, has_params, has_id))
  }
  let parsed = json.parse(wire, decoder) |> should.be_ok
  parsed.0 |> should.equal("2.0")
  parsed.1 |> should.equal("notifications/initialized")
  parsed.2 |> should.equal(False)
  parsed.3 |> should.equal(False)
}

pub fn encode_success_response_test() {
  let result =
    json.object([
      #("capabilities", json.object([#("resources", json.object([]))])),
    ])
  let msg = jsonrpc.success_response(42, result)
  let wire = jsonrpc.encode(msg)
  let decoder = {
    use jsonrpc_ver <- decode.field("jsonrpc", decode.string)
    use id <- decode.field("id", decode.int)
    use has_result <- decode.optional_field("result", False, decode.success(True))
    use has_error <- decode.optional_field("error", False, decode.success(True))
    decode.success(#(jsonrpc_ver, id, has_result, has_error))
  }
  let parsed = json.parse(wire, decoder) |> should.be_ok
  parsed.0 |> should.equal("2.0")
  parsed.1 |> should.equal(42)
  parsed.2 |> should.equal(True)
  parsed.3 |> should.equal(False)
}

pub fn encode_error_response_test() {
  let msg = jsonrpc.error_response(7, -32_601, "Method not found")
  let wire = jsonrpc.encode(msg)
  let error_decoder = {
    use code <- decode.field("code", decode.int)
    use message <- decode.field("message", decode.string)
    decode.success(#(code, message))
  }
  let decoder = {
    use jsonrpc_ver <- decode.field("jsonrpc", decode.string)
    use id <- decode.field("id", decode.int)
    use err <- decode.field("error", error_decoder)
    use has_result <- decode.optional_field("result", False, decode.success(True))
    decode.success(#(jsonrpc_ver, id, err, has_result))
  }
  let parsed = json.parse(wire, decoder) |> should.be_ok
  parsed.0 |> should.equal("2.0")
  parsed.1 |> should.equal(7)
  parsed.2 |> should.equal(#(-32_601, "Method not found"))
  parsed.3 |> should.equal(False)
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

pub fn decode_request_with_params_test() {
  let wire =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/subscribe\","
    <> "\"params\":{\"uri\":\"gmail://inbox\"}}"
  let msg = jsonrpc.decode(wire) |> should.be_ok
  case msg {
    jsonrpc.Request(id, method, params) -> {
      id |> should.equal(jsonrpc.IntId(1))
      method |> should.equal("resources/subscribe")
      case params {
        Some(_) -> Nil
        None -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

pub fn decode_notification_test() {
  let wire =
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\","
    <> "\"params\":{\"uri\":\"gmail://inbox\"}}"
  let msg = jsonrpc.decode(wire) |> should.be_ok
  case msg {
    jsonrpc.Notification(method, params) -> {
      method |> should.equal("notifications/resources/updated")
      case params {
        Some(_) -> Nil
        None -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

pub fn decode_notification_without_params_test() {
  let wire = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}"
  let msg = jsonrpc.decode(wire) |> should.be_ok
  case msg {
    jsonrpc.Notification(method, params) -> {
      method |> should.equal("ping")
      params |> should.equal(None)
    }
    _ -> should.fail()
  }
}

pub fn decode_success_response_test() {
  let wire =
    "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"ok\":true}}"
  let msg = jsonrpc.decode(wire) |> should.be_ok
  case msg {
    jsonrpc.Response(id, jsonrpc.Success(_)) ->
      id |> should.equal(jsonrpc.IntId(5))
    _ -> should.fail()
  }
}

pub fn decode_error_response_test() {
  let wire =
    "{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32601,"
    <> "\"message\":\"Method not found\"}}"
  let msg = jsonrpc.decode(wire) |> should.be_ok
  case msg {
    jsonrpc.Response(id, jsonrpc.Failure(code, message, data)) -> {
      id |> should.equal(jsonrpc.IntId(9))
      code |> should.equal(-32_601)
      message |> should.equal("Method not found")
      data |> should.equal(None)
    }
    _ -> should.fail()
  }
}

pub fn decode_wrong_jsonrpc_version_returns_error_test() {
  let wire = "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"ping\"}"
  jsonrpc.decode(wire) |> should.be_error
}

pub fn decode_invalid_shape_returns_error_test() {
  // Valid jsonrpc version, has an id, but no method, no result, no error —
  // structurally ambiguous, so the shape discriminator must reject it.
  jsonrpc.decode("{\"jsonrpc\":\"2.0\",\"id\":1}") |> should.be_error
  // Totally malformed input — not JSON at all.
  jsonrpc.decode("not json at all") |> should.be_error
}

pub fn decode_wrong_typed_method_returns_error_test() {
  let wire = "{\"jsonrpc\":\"2.0\",\"method\":42,\"id\":1}"
  jsonrpc.decode(wire)
  |> should.equal(Error("method must be a string"))
}

pub fn decode_wrong_typed_id_returns_error_test() {
  let wire = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":true}"
  jsonrpc.decode(wire)
  |> should.equal(Error("id must be int or string"))
}

pub fn decode_string_id_test() {
  let wire =
    "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"ping\"}"
  let msg = jsonrpc.decode(wire) |> should.be_ok
  case msg {
    jsonrpc.Request(id, _, _) ->
      id |> should.equal(jsonrpc.StringId("abc"))
    _ -> should.fail()
  }
}

pub fn decode_both_result_and_error_returns_error_test() {
  let wire =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":"
    <> "{\"code\":-1,\"message\":\"x\"}}"
  jsonrpc.decode(wire) |> should.be_error
}
