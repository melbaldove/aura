//// MCP client pool.
////
//// A static supervisor that owns one `mcp_client` actor per configured MCP
//// server. Phase 1.5 (ADR 026) retired the ambient-subscription path; the
//// pool now owns the lifecycle of the MCP handshakes and exposes a lookup
//// registry so the brain can find a named client at runtime to issue tool
//// calls.
////
//// Phase 1 uses `static_supervisor` because the server set is fixed at
//// config load time.
////
//// Failure isolation: `OneForOne` — if one MCP subprocess keeps crashing,
//// its actor restarts in place; healthy siblings are untouched.
////
//// Empty config is valid: the supervisor starts with zero children.
////
//// Registry mechanism: each `mcp_client` registers itself at start under a
//// deterministic atom of the form `aura_mcp_<server_name>` (see
//// `aura_mcp_registry_ffi.erl`). Because names are deterministic, any caller
//// with the server's string name can look the client up via `get_client/1`
//// without the pool holding any state of its own. When a client process dies
//// the BEAM auto-unregisters the atom; the supervisor restarts it and the
//// new process re-registers under the same atom.

import aura/config
import aura/mcp/client
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
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
pub fn supervised(
  mcp_config: config.McpConfig,
) -> supervision.ChildSpecification(Nil) {
  static_supervisor.supervised(builder(mcp_config))
  |> supervision.map_data(fn(_) { Nil })
}

/// Build the pool's internal supervisor builder. Exposed so tests can
/// start the supervisor directly and observe its Pid; production code
/// should use `supervised/1` and mount it under the root supervisor.
pub fn builder(
  mcp_config: config.McpConfig,
) -> static_supervisor.Builder {
  list.fold(
    mcp_config.servers,
    static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.restart_tolerance(intensity: 10, period: 60),
    fn(b, server) {
      let cfg = make_client_config(server)
      static_supervisor.add(b, client.supervised(cfg, name_for(server.name)))
    },
  )
}

/// Look up a running MCP client by its configured server name.
///
/// Returns `Some(subject)` if a client is currently registered under
/// `aura_mcp_<name>` — i.e. the mcp_client actor for that server is alive
/// and past start-up. Returns `None` if the name is unknown or the client
/// process has exited and not yet been restarted by the supervisor.
///
/// The returned subject is a `NamedSubject`: sending to it resolves the
/// registered pid at send time, so it remains valid across supervisor
/// restarts (each restart re-registers under the same atom). The caller
/// can safely pass it to `client.call_tool/4`.
///
/// Callers should not cache `Some(subject)` aggressively — between the
/// lookup and the use the registered pid may change. `call_tool/4` sends
/// via the NamedSubject each invocation, so recomputing the lookup per
/// call is a no-op performance-wise and the natural idiom is
/// `pool.get_client(name) |> option.map(call_tool(...))`.
pub fn get_client(
  name: String,
) -> Option(Subject(client.ClientMessage)) {
  let registered = name_for(name)
  case process.named(registered) {
    Ok(_pid) -> Some(process.named_subject(registered))
    Error(_) -> None
  }
}

// ---------------------------------------------------------------------------
// Per-server client config
// ---------------------------------------------------------------------------

/// Build a `client.ClientConfig` for one server. ADR 026 retired the
/// ambient-subscription path; this maps the server's connection fields
/// onto the simplified client config.
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

// ---------------------------------------------------------------------------
// Registry atom generation (FFI)
// ---------------------------------------------------------------------------

/// Map a server's string name onto its deterministic registration atom
/// (`aura_mcp_<name>`). Both the client (which calls `actor.named(name)` at
/// start-up) and `get_client/1` (which does `process.named(...)`) resolve
/// through this function, so they agree on the atom for any given string.
///
/// Safe: the atom namespace is bounded by the MCP server count in
/// configuration, known at start-up. See `aura_mcp_registry_ffi.erl`.
@external(erlang, "aura_mcp_registry_ffi", "make_name")
fn name_for(server_name: String) -> Name(client.ClientMessage)
