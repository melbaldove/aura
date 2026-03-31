# Architecture

## Overview

Aura is an OTP application where every component is a supervised actor. Actors communicate via message passing with no shared state. If one crashes, the supervisor restarts it without affecting the others.

```
supervisor (OneForOne, 3 restarts / 5s)
├── db              SQLite actor — single writer, serialized via mailbox
├── poller          Discord WebSocket — reconnects with exponential backoff
├── brain           Routes messages, runs LLM tool loop with streaming
├── workstream_sup  Factory — one actor per configured workstream
├── heartbeat_sup   Factory — one actor per monitoring check
└── acp_sup         Factory — one actor per Claude Code session
```

## Message flow

```
                    ┌──────────┐
   Discord ──SSE──> │  Poller  │
                    └────┬─────┘
                         │ HandleMessage
                    ┌────▼─────┐
                    │  Brain   │──── route_message(channel_id)
                    └────┬─────┘
                   ┌─────┴──────┐
              matched?     no match
                   │           │
            ┌──────▼──┐  ┌─────▼──────┐
            │Workstream│  │ Brain LLM  │
            │  Actor   │  │ Tool Loop  │
            └──────┬───┘  └─────┬──────┘
                   │            │
              WorkstreamResponse │
                   │      ┌─────▼──────┐
                   └─────>│  Discord   │
                          │  REST API  │
                          └────────────┘
```

### Routing

Brain routes by `channel_id`. Each workstream has a dedicated Discord channel. Messages in a workstream's channel go directly to that workstream actor — no LLM classification needed. Messages in unmatched channels (like #aura) are handled by the brain directly.

## Data model

### SQLite (primary persistence)

```sql
conversations
├── id TEXT PRIMARY KEY          -- "discord:123456"
├── platform TEXT                -- "discord", "telegram", etc.
├── platform_id TEXT             -- native ID from that platform
├── parent_id TEXT               -- thread parent (nullable)
├── workstream TEXT              -- which workstream owns this
├── last_active_at INTEGER       -- ms since epoch
├── compaction_summary TEXT      -- compressed context
└── UNIQUE(platform, platform_id)

messages
├── id INTEGER PRIMARY KEY
├── conversation_id TEXT FK
├── role TEXT                    -- "system", "user", "assistant", "tool"
├── content TEXT
├── author_id TEXT
├── author_name TEXT
├── tool_call_id TEXT
├── tool_calls TEXT              -- JSON
├── tool_name TEXT
├── created_at INTEGER           -- ms since epoch
└── seq INTEGER                  -- ordering within same ms

messages_fts (FTS5 virtual table)
└── content                      -- auto-synced via triggers
    tokenize='porter unicode61'
```

### In-memory (hot cache)

```
conversation.Buffers = Dict(String, List(llm.Message))
```

Key is `platform:platform_id`. Loaded from SQLite on first access, written through on every exchange. Compression triggers at 50% of context window (100K tokens for GLM-5.1).

### Files (configuration + identity)

```
~/.config/aura/config.toml       Global settings
~/.config/aura/SOUL.md           Agent personality
~/.config/aura/USER.md           User profile
~/.config/aura/.env              Credentials
~/.local/share/aura/aura.db      SQLite database
~/.local/share/aura/skills/      Skill definitions
~/.local/state/aura/MEMORY.md    Agent long-term memory
```

## LLM integration

### Streaming

All LLM calls use SSE streaming via an Erlang FFI (`aura_stream_ffi.erl`). The FFI:

1. Makes an async HTTP POST with `{stream, self}` to the OpenAI-compatible API
2. Receives SSE chunks, parses `data:` lines
3. For `delta.content` — sends `{stream_delta, Binary}` to the caller (brain edits Discord progressively)
4. For `delta.tool_calls` — accumulates index/id/name/arguments internally
5. For `reasoning_content` (GLM-5.1) — sends `stream_reasoning` (keeps timeout alive)
6. On `[DONE]` — sends `{stream_complete, Content, ToolCallsJson}` with the full response

### Tool loop

The brain's `tool_loop_progressive` function:

1. Spawns a streaming LLM call with tool definitions
2. Collects the response (content + tool calls) via `collect_stream_loop`
3. If tool calls: executes them, builds traces, edits Discord with progress, loops
4. If text only: returns the response for final Discord edit
5. Max 20 iterations per user message

### Context compression

When conversation history exceeds 50% of context window (estimated via `chars / 4`):

1. Protect head (3 messages or 1 compaction summary) and tail (20 messages)
2. Serialize middle messages for an LLM summarization call
3. LLM produces a structured summary (Goal, Constraints, Progress, Decisions, Files, Next Steps)
4. Summary replaces the middle messages as a `[CONTEXT COMPACTION]` SystemMessage
5. Subsequent compressions update the existing summary iteratively
6. If LLM fails, falls back to hard-dropping oldest messages

## Security model

### Write tiers

| Tier | Paths | Approval |
|------|-------|----------|
| Autonomous | logs/, anchors.jsonl, events.jsonl, MEMORY.md, skills/ | None |
| NeedsApproval | config.toml, workstream config, USER.md | `propose()` |
| NeedsApprovalWithPreview | SOUL.md, META.md | `propose()` + diff |

### Validation harness

Rules defined in `validations.toml`:

```toml
[[rules]]
path = "workstreams/*/anchors.jsonl"
type = "valid_jsonl"

[[rules]]
path = "config.toml"
type = "valid_toml"
```

Enforced on every `write_file` and `append_file` call.

### Memory security

Memory entries (`MEMORY.md`, `USER.md`) are scanned for:
- Prompt injection patterns (15 patterns: "ignore previous instructions", "you are now", etc.)
- Exfiltration patterns (curl/wget with credentials, .env/.ssh access)
- Character limits (2200 for memory, 1375 for user)

## Learning loop

Inspired by Hermes Agent. Three mechanisms:

1. **Skill auto-creation** — system prompt nudges the LLM to save complex workflows as SKILL.md files via the `create_skill` tool
2. **Structured memory** — `memory` tool with add/replace/remove for durable facts in MEMORY.md and USER.md
3. **Session search** — `search_sessions` tool queries FTS5 across all past conversations

The LLM is guided by Hermes-aligned prompt nudges:
- "Save durable facts... keep it compact and focused on facts that will still matter later"
- "Prioritize what reduces future user steering"
- "After completing a complex task (3+ tool calls)... save the approach as a skill"

## Multi-platform design

The database schema uses `(platform, platform_id)` as the unique key for conversations. Adding a new platform (Telegram, Slack) requires:

1. A gateway module that connects to the platform
2. A message bridge that converts platform events to `IncomingMessage`
3. Routing through brain with the platform identifier

All downstream systems (conversation loading, search, compression, persistence) work automatically.

## Erlang FFI modules

| Module | Purpose |
|--------|---------|
| `aura_ws_ffi` | Raw WebSocket (SSL, RFC 6455 framing, passive recv) |
| `aura_gateway_bridge` | Bridge raw WS messages to Gleam Subject |
| `aura_stream_ffi` | SSE streaming HTTP with content + tool call parsing |
| `aura_time_ffi` | `erlang:system_time(millisecond)` |
| `aura_poller_ffi` | `receive {'EXIT', _, _}` for trap_exits |
| `aura_skill_ffi` | `os:cmd/1` for skill subprocess invocation |
| `aura_env_ffi` | `os:getenv/1`, `os:putenv/2` |
| `aura_init_ffi` | Interactive stdin for setup wizard |
| `aura_io_ffi` | Terminal I/O helpers |
| `aura_runtime_ffi` | `os:find_executable/1` for dependency checks |
