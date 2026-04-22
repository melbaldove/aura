# ADR 026: Native Integrations — No Public Endpoint, No MCP Subscribe

**Status:** Accepted
**Date:** 2026-04-22
**Supersedes:** ADR 025 (Ambient awareness via MCP and generalized flares)

## Context

ADR 025 claimed "MCP is the event substrate for ambient awareness." Two assumptions turned out to be wrong on contact with reality:

1. **MCP resource subscriptions are not adopted in the ecosystem.** The MCP spec marks `resources/subscribe` / `notifications/resources/updated` as explicitly optional capabilities. No official Gmail MCP server exists; the widely-used community Gmail MCP (`GongRzhe/Gmail-MCP-Server`, archived March 2026) implements tools only, no subscription. The pattern is representative — most MCP servers expose tools for actions and don't implement subscriptions because "resources" in MCP is shaped for file/dataset watching, not event streams.

2. **Webhooks require a public HTTPS endpoint** — incompatible with running on a personal laptop behind home NAT. Cloudflare Tunnel / self-hosted proxies / paid tunnels could bridge this, but the project's stance is that A.U.R.A. shouldn't require that infrastructure. The assistant should work on any user's machine without network-topology assumptions.

Phase 1 shipped an event pipeline (schema v5, event_ingest, event_tagger, search_events tool) driven by an MCP client that subscribed to resources — a pipeline whose upstream will never fire in production.

## Decision

### Event ingestion: native integrations per source, running in-process

Each external source gets its own first-class integration module inside A.U.R.A.'s Gleam codebase. The integration is a supervised OTP actor that:

- Opens an **outbound** connection using the source's native push protocol
- Authenticates with stored credentials
- Stays connected; the server pushes events over the existing connection
- Translates service-specific payloads into `AuraEvent`
- Forwards to `event_ingest`
- Reconnects with backoff on disconnect

No subprocess per source, no public HTTPS endpoint, no MCP dependency for ingestion. Fast — events travel through BEAM message passing (microseconds), not fork/exec. All integrations share A.U.R.A.'s identity, crash-recovery, and lifecycle.

### Per-source outbound protocols

| Source | Protocol |
|---|---|
| Gmail | IMAP IDLE (RFC 2177) over TLS + XOAUTH2 auth |
| Linear | GraphQL subscriptions over WebSocket |
| Slack | Socket Mode WebSocket (Slack's own "for apps without public endpoints" mechanism) |
| Discord | Gateway WebSocket (already in A.U.R.A. today; eventually moves under integrations/) |
| GitHub, Notion | No first-party push-to-client — accepted as lookup-only or falls back to modest polling |

Each integration is bespoke because protocols differ. A.U.R.A. provides shared primitives (backoff, OAuth helper, WebSocket wrapper) but integrations do not share a common abstraction type. The contract is behavioral: same actor shape, same `event_ingest` target, same supervision pattern.

### MCP keeps its strong job: action surface

MCP stays in A.U.R.A. as the **tool surface for the LLM to take actions** (draft email, close ticket, post message). `mcp_client` becomes handshake + `tools/call`; no subscribe path. `mcp_client_pool` becomes a registry of action-client connections the brain queries.

Ingestion and action are separately configured, separately supervised, separately scoped.

### Native-language integration, not subprocess

All integrations are Gleam modules with thin `@external` bindings to Erlang stdlib when needed (e.g. `ssl` for TLS, `ws` FFI we already have). No subprocess-per-source pattern (rejected: not a library, not fast, harder to share code, language fragmentation). The subprocess pattern stays appropriate for MCP servers (external tools) and skills (external behaviors), but integrations are A.U.R.A. code.

### Library of shared primitives

```
src/aura/
  backoff.gleam            Exponential + cap; generalized from poller
  oauth.gleam              OAuth 2.0 authorization code + refresh flows
  imap.gleam               IMAP4rev1 subset: connect, LOGIN/XOAUTH2, SELECT, IDLE, FETCH
  ws.gleam                 WebSocket wrapper (reuse or generalize aura_ws_ffi.erl)
  integrations/
    gmail.gleam            IMAP IDLE actor, translates to AuraEvent
    linear.gleam           (later) GraphQL subs
    slack.gleam            (later) Socket Mode
```

### Alternatives considered

1. **MCP poll via scheduler** (proposed earlier, rejected). Each source polls at an interval. Works but interval-tick is wasteful and laggy for a feature whose whole point is real-time ambient awareness. Ecosystem already provides push mechanisms — use them.

2. **Webhook receivers behind Cloudflare Tunnel**. Works technically. Rejected because it couples A.U.R.A.'s architecture to specific infrastructure assumptions and adds a managed service dependency.

3. **Subprocess-per-source listener with JSONL IPC**. Rejected: each integration becomes a standalone program in a different language, not a shared library; spawn overhead per event; harder to share code. Keep that pattern for MCP servers and skills where it's appropriate.

4. **Depend on third-party IMAP library (Plover)**. Considered. Only BEAM-world library with both XOAUTH2 and IDLE, but author's own disclaimer says "AI-generated, not production ready." Writing our own focused ~400-line IMAP subset against a 22-year-stable protocol is a Discord-WS-FFI-scale task with lower supply-chain risk.

## Consequences

### Easier
- Works on any user's laptop behind NAT — no tunnel, no public endpoint, no hosting assumptions. A.U.R.A. stays a local-first assistant.
- Fast ambient awareness — real-time push over existing outbound connections; no polling.
- Clean split between ingestion (integrations) and action (MCP tools).
- Integrations are first-class A.U.R.A. code; contributors can add new sources by writing one Gleam module.
- Existing `event.gleam` / `event_tagger` / `event_ingest` / `search_events` tool / schema v5 all salvaged unchanged.
- Existing `mcp_client` / `jsonrpc` / stdio FFI salvaged for the action surface.

### Harder
- Per-source integration work is bespoke. No shared "listener protocol" abstraction to lean on. First integration (Gmail) writes IMAP from scratch (~400 lines). Each subsequent source is its own project.
- OAuth flows need to be handled per-source (Gmail OAuth 2.0, Linear personal token, Slack app token, etc.). Some initial in-chat or CLI-driven flow needed.
- Writing our own IMAP IDLE client is real protocol work — though bounded and against a stable RFC.
- Integrations can't be written in other languages (intentional — matches "one A.U.R.A., shared codebase" philosophy).

### Compatibility notes
- Phase 1 code is mostly salvaged. The changes are (a) cut the MCP subscribe state machine, (b) repurpose `mcp_client_pool` as action-only registry, (c) add new integration modules.
- Phase 2 (flare selectors, routing) is unaffected — still receives `AuraEvent`s from `event_ingest` regardless of source.
- Future push-capable MCP servers are accommodated by adding the subscribe path back when a real use case appears (deferred).

### Implementation phasing
Phase 1.5 = refactor + first integration. Seven logical chunks: (1) remove MCP subscribe surface, (2) add `call_tool` to MCP client, (3) shared primitives (backoff, OAuth, WebSocket, IMAP), (4) Gmail integration module, (5) config + supervisor wiring, (6) OAuth setup UX, (7) live Gmail deploy + smoke. Detailed plan: `docs/superpowers/plans/2026-04-22-ambient-awareness-phase-1-5.md`.
