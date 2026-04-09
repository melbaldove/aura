# ADR 011: ACP Manager as OTP Actor

## Status
Accepted (2026-04-09)

## Context
The AcpManager was an immutable value passed by copy through the system. Multiple code paths (brain tools, event handlers, recovery) held different copies and independently called `persist_sessions`, each writing its own `active_sessions` list as the source of truth. A stale copy could overwrite sessions written by a fresh copy, causing sessions to be lost on disk and monitors to not recover after restarts.

## Decision
Replace the AcpManager value with an OTP actor. One process owns the full ACP lifecycle: session state, tmux sessions, monitors, and persistence. Callers interact through synchronous messages (Dispatch, Kill, GetSession, ListSessions, SendInput). Monitor events route through the actor before being forwarded to the brain for Discord notifications. Recovery happens during actor init.

## Consequences
- Single owner of session state — no stale copies, no race conditions on persistence
- Brain becomes thin for ACP events — only sends Discord messages, no state management
- Monitor events are serialized through the actor — consistent state transitions
- Recovery is internal to the actor — supervisor just starts it
- Follows the same pattern as the db actor (SQLite serialized writes)
- Actor crash restarts cleanly via OTP supervisor, reloading from disk
