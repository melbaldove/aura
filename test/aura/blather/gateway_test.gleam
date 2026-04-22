import aura/blather/gateway
import gleam/string
import gleeunit/should

pub fn resolve_ws_target_with_explicit_port_and_path_prefix_test() {
  let assert Ok(#(host, port, path)) =
    gateway.resolve_ws_target("http://10.0.0.2:18100/api", "blather_abc")

  host |> should.equal("10.0.0.2")
  port |> should.equal(18100)
  path |> should.equal("/api/ws/events?api_key=blather_abc")
}

/// No path component — WS path is just `/ws/events?...`, no empty prefix.
pub fn resolve_ws_target_no_path_prefix_test() {
  let assert Ok(#(_host, _port, path)) =
    gateway.resolve_ws_target("http://localhost:3000", "k")

  path |> should.equal("/ws/events?api_key=k")
}

/// Trailing slash on base_url must not produce `//ws/events`.
pub fn resolve_ws_target_trailing_slash_is_stripped_test() {
  let assert Ok(#(_, _, path)) =
    gateway.resolve_ws_target("http://host:3000/api/", "k")

  path |> should.equal("/api/ws/events?api_key=k")
}

/// Default to port 80 when the URL omits it and uses plain http/ws.
pub fn resolve_ws_target_defaults_port_80_for_http_test() {
  let assert Ok(#(_, port, _)) =
    gateway.resolve_ws_target("http://somehost/api", "k")

  port |> should.equal(80)
}

/// For TLS-fronted URLs the default jumps to 443. Not an intended
/// deployment today (plain ws is the norm on the VPN), but documents
/// the behavior so a future TLS-on-VPN switch doesn't surprise anyone.
pub fn resolve_ws_target_defaults_port_443_for_https_test() {
  let assert Ok(#(_, port, _)) =
    gateway.resolve_ws_target("https://secure.blather/api", "k")

  port |> should.equal(443)
}

/// API keys may contain characters that need URL-encoding. Real Blather
/// keys are `blather_<hex>` (URL-safe) but the encoder should handle
/// anything the server returns without leaking raw query chars.
pub fn resolve_ws_target_percent_encodes_api_key_test() {
  let assert Ok(#(_, _, path)) =
    gateway.resolve_ws_target("http://host:3000", "a b+c/d")

  // A raw `+` or `/` in the query would change the key's interpretation.
  // Expect percent-encoding by gleam/uri.
  string.contains(path, "a b") |> should.be_false
  string.contains(path, "?api_key=") |> should.be_true
}

pub fn resolve_ws_target_rejects_invalid_url_test() {
  gateway.resolve_ws_target("definitely not a url", "k")
  |> should.be_error
}

