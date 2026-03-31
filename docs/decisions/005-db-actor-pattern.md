# ADR-005: DB actor for serialized writes

**Status:** Accepted
**Date:** 2026-03-31

## Context

SQLite is single-writer. Multiple actors (brain, workstreams, heartbeats) need to read and write conversation data. Concurrent writes cause SQLITE_BUSY errors.

Hermes Agent (Python) uses `threading.Lock()` with `BEGIN IMMEDIATE` transactions and jitter retry. This is the imperative approach.

## Decision

Use a dedicated OTP actor that owns the single SQLite connection. All reads and writes are serialized through the actor's mailbox.

- `db.gleam` exposes convenience functions (`resolve_conversation`, `append_message`, `load_messages`, `search`) that send a message to the actor and wait for the reply with a 5-second timeout
- The actor holds the `sqlight.Connection` in its state
- On `Shutdown`, the connection is closed cleanly

## Consequences

- No SQLITE_BUSY errors — writes are serialized by the BEAM scheduler
- No mutexes, locks, or retry logic needed
- All DB access is message-passing — naturally async
- Single point of serialization could become a bottleneck at scale (not a concern for a single-user agent)
- 5-second timeout on DB calls prevents actor hangs from blocking callers indefinitely
- Connection lifecycle tied to actor lifecycle — supervisor restart gives a fresh connection
