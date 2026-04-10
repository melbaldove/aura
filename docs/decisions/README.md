# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for Aura. Each ADR captures a single architectural decision, its context, and consequences.

## Format

Each ADR follows this template:

```markdown
# ADR-NNN: Title

**Status:** Accepted | Superseded by ADR-NNN | Deprecated
**Date:** YYYY-MM-DD

## Context

What is the issue? What forces are at play?

## Decision

What did we decide?

## Consequences

What are the trade-offs? What becomes easier? What becomes harder?
```

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [001](001-beam-over-nodejs.md) | BEAM/Gleam over Node.js/Python | Accepted |
| [002](002-raw-websocket-ffi.md) | Raw WebSocket FFI over stratus | Accepted |
| [003](003-sqlite-over-jsonl.md) | SQLite over JSONL for persistence | Accepted |
| [004](004-multi-platform-schema.md) | Multi-platform conversation schema | Accepted |
| [005](005-db-actor-pattern.md) | DB actor for serialized writes | Accepted |
| [006](006-streaming-with-tool-calls.md) | SSE streaming with tool call accumulation | Accepted |
| [007](007-hermes-aligned-learning-loop.md) | Hermes-aligned learning loop | Accepted |
| [008](008-chars-over-4-token-estimation.md) | chars/4 token estimation | Accepted |
| [009](009-no-honcho-integration.md) | No Honcho integration | Accepted |
| [010](010-context-compression.md) | LLM-based context compression | Superseded by ADR-014 |
| [011](011-acp-manager-actor.md) | ACP Manager as OTP actor | Accepted |
| [012](012-keyed-memory-entries.md) | Keyed memory entries (set/remove by key) | Accepted |
| [013](013-active-memory-review.md) | Active memory review (Hermes-inspired) | Accepted |
| [014](014-tiered-runtime-compression.md) | Tiered runtime compression | Accepted |
| [015](015-acp-protocol.md) | ACP protocol for agent dispatch | Accepted |
| [016](016-push-based-stdio-monitor.md) | Push-based stdio monitor with LLM summarization | Accepted |
| [017](017-background-agent-architecture.md) | Background agent architecture (OpenPoke pattern) | Superseded by ADR-018 |
| [018](018-flare-architecture.md) | Flare architecture for background agents | Accepted |

## Adding a new ADR

1. Copy the template above
2. Number sequentially (next is 019)
3. Add to the index in this README
4. Commit with the code change it relates to
