# ADR-002: Raw WebSocket FFI over stratus

**Status:** Accepted
**Date:** 2026-03-29

## Context

The initial implementation used stratus (v2.0.0), the standard Gleam WebSocket library. A race condition in stratus caused the Discord Hello frame (op 10) to arrive before the actor was ready to receive it (rawhat/stratus#22). The fix existed on main but was not released.

Additionally, macOS Erlang 28 SSL sockets exhibited unreliable behavior with `{active, true}` and `{active, once}` modes — data stopped arriving after a few exchanges.

## Decision

Replace stratus with a raw Erlang WebSocket implementation in `aura_ws_ffi.erl`:

- Direct `ssl:connect` with manual HTTP upgrade handshake
- RFC 6455 Sec-WebSocket-Accept validation
- Frame encoding/decoding (text, binary, close, ping, pong)
- Passive `ssl:recv` loop (works around macOS SSL active mode bug)
- Unlinked relay process to prevent cascade failures

## Consequences

- More code to maintain (~280 lines of Erlang)
- No dependency on stratus release cycle
- Full control over SSL behavior and frame handling
- The macOS SSL issue is worked around, not fixed — may need revisiting if OTP fixes it
- stratus remains in gleam.toml as a transitive dependency (used by gleam_httpc) but not directly used for WebSocket
