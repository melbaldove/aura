# ADR-003: SQLite over JSONL for persistence

**Status:** Accepted
**Date:** 2026-03-31

## Context

Conversation history was stored as one JSONL file per Discord channel_id. This had several problems:

- No search — finding a past conversation required reading every file
- No structured queries — filtering by date, workstream, or platform required custom code
- Overwrite bug — after restart, appending to an empty in-memory buffer then saving overwrote full disk history
- Not multi-platform ready — filenames were Discord channel IDs with no platform namespace

Hermes Agent uses SQLite with FTS5 for session persistence and full-text search.

## Decision

Replace JSONL with SQLite via the `sqlight` Gleam library (wraps esqlite NIF with SQLite + FTS5 compiled in).

- Single database file at `~/.local/share/aura/aura.db`
- WAL mode for concurrent reads
- FTS5 virtual table with porter stemming for full-text search
- Auto-sync triggers keep the FTS5 index current
- Schema versioning for forward migration
- Dedicated DB actor serializes all writes (BEAM-idiomatic, no mutexes)

## Consequences

- Requires C compiler for esqlite NIF compilation
- esqlite NIF needs recompilation after `gleam clean` on OTP 27+ (known issue)
- rebar3 required as build tool (for the NIF)
- Single file makes backup trivial (`cp aura.db aura.db.bak`)
- Full-text search across all conversations is now instant
- Schema can evolve with versioned migrations
- JSONL files migrated automatically on first startup
