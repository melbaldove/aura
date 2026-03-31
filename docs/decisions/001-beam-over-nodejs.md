# ADR-001: BEAM/Gleam over Node.js/Python

**Status:** Accepted
**Date:** 2026-03-29

## Context

Aura replaces OpenClaw, which runs on Node.js. OpenClaw suffered a fatal polling deadlock caused by an undici connection pool bug (openclaw#48029) that blocked all I/O on the single event loop. When the poller deadlocked, heartbeat checks, message handling, and ACP monitoring all died simultaneously. Manual restart was required.

Hermes Agent (the other major open-source agent framework) uses Python, which has the same fundamental limitation — a single process crash kills everything.

Aura needs to run 24/7 as an executive assistant. Reliability is the primary requirement.

## Decision

Build Aura in Gleam on the BEAM VM (Erlang/OTP).

- OTP supervision trees restart failed actors in milliseconds
- Each actor (poller, brain, workstreams, heartbeats) runs on its own scheduler
- A poller crash is invisible to heartbeat checks
- No single point of failure within the runtime
- Hot code reloading possible (not used yet but available)

Gleam was chosen over raw Erlang for type safety and developer ergonomics while still compiling to BEAM bytecode.

## Consequences

- Smaller ecosystem than Node.js/Python — fewer libraries, less community
- Gleam is young — some libraries are immature (e.g., stratus WebSocket)
- Erlang FFI needed for raw BEAM primitives (receive, trap_exits, system_time)
- Contributors need to learn Gleam + OTP concepts
- Runtime reliability is excellent — Aura self-heals without manual intervention
