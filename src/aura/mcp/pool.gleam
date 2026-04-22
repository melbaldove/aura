//// MCP client pool.
////
//// A static supervisor that owns one `mcp_client` actor per configured MCP
//// server. Each client converts incoming `notifications/resources/updated`
//// messages into `AuraEvent`s and fire-and-forget sends them to
//// `event_ingest`.
////
//// Phase 1 uses `static_supervisor` because the server set is fixed at
//// config load time. Phase 4 will swap this for a `factory_supervisor` so
//// chat can add/remove servers at runtime without a restart.
////
//// Failure isolation: `OneForOne` — if one MCP subprocess keeps crashing,
//// its actor restarts in place; healthy siblings are untouched.
////
//// Empty config is valid: the supervisor starts with zero children.
////
//// Notification → AuraEvent mapping (documented once here, not re-derived
//// per-server):
////
//// - `source`     = the server's configured `name` (e.g. `"gmail-work"`).
////                  We use the config name, not a generic `"gmail"`, so
////                  multiple accounts of the same provider are
////                  distinguishable.
//// - `type_`      = `"resource.updated"` for `notifications/resources/
////                  updated`. The MCP method is condensed into a short
////                  event-bus flavoured tag; other methods are currently
////                  dropped (logged at Info).
//// - `subject`    = the resource URI from `params.uri`.
//// - `time_ms`    = 0. `event_ingest` fills this with `time.now_ms()`.
//// - `id`         = "". `event_ingest` generates one.
//// - `tags`       = empty. `event_ingest` invokes the rule-based tagger.
//// - `external_id`= best effort. Preferred: a `message_id` field from
////                  params. Fallback: `time_ms + "@" + uri`. The fallback
////                  is intentionally weak — two notifications in the same
////                  millisecond for the same URI will dedupe to one event.
////                  That's acceptable for Phase 1; Task 11 will revisit
////                  once we see real gmail-mcp payloads.
//// - `data`       = the full JSON params serialised as a string, so the
////                  tagger and any future consumer has the raw payload.

import aura/config
import aura/event
import aura/event_ingest
import aura/mcp/client
import aura/time
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/otp/supervision
import logging

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Build a supervised child spec for the MCP client pool. The returned
/// spec wraps a `static_supervisor` with one `mcp_client` worker per
/// entry in `mcp_config.servers`. All clients share the same
/// `event_ingest` subject — there's no per-server ingest actor.
///
/// Empty `mcp_config.servers` is a valid configuration: the supervisor
/// starts with no children.
pub fn supervised(
  mcp_config: config.McpConfig,
  event_ingest_subject: process.Subject(event_ingest.IngestMessage),
) -> supervision.ChildSpecification(Nil) {
  static_supervisor.supervised(builder(mcp_config, event_ingest_subject))
  |> supervision.map_data(fn(_) { Nil })
}

/// Build the pool's internal supervisor builder. Exposed so tests can
/// start the supervisor directly and observe its Pid; production code
/// should use `supervised/2` and mount it under the root supervisor.
pub fn builder(
  mcp_config: config.McpConfig,
  event_ingest_subject: process.Subject(event_ingest.IngestMessage),
) -> static_supervisor.Builder {
  list.fold(
    mcp_config.servers,
    static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.restart_tolerance(intensity: 10, period: 60),
    fn(b, server) {
      static_supervisor.add(
        b,
        client.supervised(make_client_config(server, event_ingest_subject)),
      )
    },
  )
}

// ---------------------------------------------------------------------------
// Per-server client config
// ---------------------------------------------------------------------------

/// Build a `client.ClientConfig` for one server. The on_notification
/// callback closes over the event_ingest subject and the server's name
/// so the resulting `AuraEvent` carries the right `source`.
fn make_client_config(
  server: config.McpServerConfig,
  event_ingest_subject: process.Subject(event_ingest.IngestMessage),
) -> client.ClientConfig {
  let source = server.name
  client.new_config(
    name: server.name,
    command: server.command,
    args: server.args,
    env: server.env,
    subscribe: server.subscribe,
    on_notification: fn(method, params) {
      handle_notification(source, method, params, event_ingest_subject)
    },
  )
}

/// Route one MCP notification. Phase 1 only handles
/// `notifications/resources/updated`; anything else is logged and
/// dropped.
fn handle_notification(
  source: String,
  method: String,
  params: json.Json,
  event_ingest_subject: process.Subject(event_ingest.IngestMessage),
) -> Nil {
  case method {
    "notifications/resources/updated" -> {
      let data_str = json.to_string(params)
      let parsed = parse_params(data_str)
      let uri = extract_uri(parsed)
      let external_id = derive_external_id(parsed, uri)
      let e =
        event.AuraEvent(
          id: "",
          source: source,
          type_: "resource.updated",
          subject: uri,
          time_ms: 0,
          tags: dict.new(),
          external_id: external_id,
          data: data_str,
        )
      event_ingest.ingest(event_ingest_subject, e)
    }
    other -> {
      logging.log(
        logging.Info,
        "[mcp:"
          <> source
          <> "] Dropping unhandled notification method: "
          <> other,
      )
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parse_params(data: String) -> option.Option(Dynamic) {
  case json.parse(data, decode.dynamic) {
    Ok(d) -> Some(d)
    Error(_) -> None
  }
}

fn extract_uri(parsed: option.Option(Dynamic)) -> String {
  case parsed {
    Some(d) ->
      case decode.run(d, decode.at(["uri"], decode.string)) {
        Ok(uri) -> uri
        Error(_) -> ""
      }
    None -> ""
  }
}

/// Best-effort unique signal for dedup. If the server included a
/// `message_id` (or `messageId`) field we use that; otherwise we fall
/// back to `<now_ms>@<uri>`. The fallback is weak by design: two
/// notifications in the same millisecond for the same URI will collide
/// and dedupe to a single event. Task 11 will replace this once we know
/// what real gmail-mcp emits.
fn derive_external_id(
  parsed: option.Option(Dynamic),
  uri: String,
) -> String {
  let decoder =
    decode.one_of(decode.at(["message_id"], decode.string), or: [
      decode.at(["messageId"], decode.string),
    ])
  case parsed {
    Some(d) ->
      case decode.run(d, decoder) {
        Ok(mid) -> mid
        Error(_) -> fallback_external_id(uri)
      }
    None -> fallback_external_id(uri)
  }
}

fn fallback_external_id(uri: String) -> String {
  int.to_string(time.now_ms()) <> "@" <> uri
}

