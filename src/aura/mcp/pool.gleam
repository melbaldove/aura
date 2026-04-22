//// MCP client pool.
////
//// A static supervisor that owns one `mcp_client` actor per configured MCP
//// server. Phase 1.5 (ADR 026) retired the ambient-subscription path; the
//// pool now simply owns the lifecycle of the MCP handshakes. Task 3
//// repurposes this module as the action registry for the `mcp_call` tool.
////
//// Phase 1 uses `static_supervisor` because the server set is fixed at
//// config load time.
////
//// Failure isolation: `OneForOne` — if one MCP subprocess keeps crashing,
//// its actor restarts in place; healthy siblings are untouched.
////
//// Empty config is valid: the supervisor starts with zero children.

import aura/config
import aura/event_ingest
import aura/mcp/client
import gleam/erlang/process
import gleam/list
import gleam/otp/static_supervisor
import gleam/otp/supervision

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Build a supervised child spec for the MCP client pool. The returned
/// spec wraps a `static_supervisor` with one `mcp_client` worker per
/// entry in `mcp_config.servers`.
///
/// Empty `mcp_config.servers` is a valid configuration: the supervisor
/// starts with no children.
///
/// `event_ingest_subject` is currently unused (ADR 026 retired the
/// ambient-ingest path) but retained in the signature so Task 3 can
/// repurpose the pool as the action registry without another surface
/// change.
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
  let _ = event_ingest_subject
  list.fold(
    mcp_config.servers,
    static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.restart_tolerance(intensity: 10, period: 60),
    fn(b, server) {
      static_supervisor.add(b, client.supervised(make_client_config(server)))
    },
  )
}

// ---------------------------------------------------------------------------
// Per-server client config
// ---------------------------------------------------------------------------

/// Build a `client.ClientConfig` for one server. ADR 026 retired the
/// ambient-subscription path; this maps the server's connection fields
/// onto the simplified client config. Task 3 will extend the pool with
/// the action registry surface.
fn make_client_config(
  server: config.McpServerConfig,
) -> client.ClientConfig {
  client.new_config(
    name: server.name,
    command: server.command,
    args: server.args,
    env: server.env,
  )
}
