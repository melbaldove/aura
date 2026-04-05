# CLAUDE.md

## Project overview

Aura (Autonomous Unified Runtime Agent) is a local-first executive assistant framework built in Gleam on the BEAM VM. It communicates via Discord, manages parallel domains (knowledge partitions), and dispatches Claude Code sessions for coding tasks.

## Build and test

```bash
gleam build          # Compile
gleam test           # Run all tests (184 tests)
gleam run -- start   # Start the agent
gleam run -- init    # First-run setup wizard
```

### esqlite NIF fix

After `gleam clean`, the esqlite NIF may fail with "corrupt atom table" on OTP 27+. Fix:

```bash
cd build/dev/erlang/esqlite/ebin
erlc -o . ../src/esqlite3.erl ../src/esqlite3_nif.erl
```

### Dependencies

- Gleam v1.14+, Erlang/OTP 27+, rebar3
- C compiler (for esqlite NIF)
- tmux (for ACP sessions)

## Architecture

```
supervisor (OneForOne)
├── db          SQLite actor — serializes all DB reads/writes
├── poller      Discord gateway WebSocket
├── brain       Routes messages, LLM tool loop, progressive streaming
├── (domains loaded as context, not actors)
├── scheduler   Config-driven cron + interval schedules
└── acp         One actor per Claude Code session
```

### Message flow

```
Discord → Gateway → Poller → Brain → Workstream → LLM → Brain → Discord
                                   ↘ (direct) → LLM with tools → Discord
```

Brain routes by `channel_id` to resolve a domain. Every channel gets the full tool loop — domains are context selectors, not capability boundaries.

### Vision pipeline

```
User sends image → Gateway parses attachments → Brain detects image
  → Vision model (GLM-5V-Turbo) describes image → Description prepended to user message
  → Normal tool loop (GLM-5.1) continues with enriched message
```

Two-model pipeline: vision model as preprocessor, orchestrator model for tool loop. Config is tiered: domain overrides global overrides built-in defaults. Vision model and prompt configurable per domain via `[models] vision` and `[vision] prompt` in config.toml.

### Key abstractions

- **Domain** — a knowledge partition representing an area of the user's life (job, project, responsibility). Has its own config, AGENTS.md, anchors, logs, skills, conversation history. One Discord channel per domain.
- **Conversation** — per-channel message history. In-memory buffer (hot cache) backed by SQLite. Auto-compresses when token count exceeds 50% of context window.
- **Skill** — a directory with a SKILL.md and optional CLI entrypoint. Instruction-only skills teach the LLM; external skills are invoked as subprocesses.
- **Tool** — primitive operation the LLM can call. 16 built-in tools (filesystem, Discord, skills, memory, search, web, schedules).
- **Schedule** — a config-driven periodic task defined in `schedules.toml`. Supports fixed intervals ("15m") and cron expressions ("0 9 * * *"). Each schedule invokes a skill, classifies urgency via LLM, and emits findings.

## Source layout

```
src/aura/
  brain.gleam           Core actor — routing, LLM tool loop, streaming, vision preprocessing
  vision.gleam          Vision config resolution, image URL extraction
  conversation.gleam    In-memory buffers, DB load/save, compression
  domain.gleam          Domain context loading (AGENTS.md, anchors, skills)
  db.gleam              SQLite actor (serialized writes, FTS5 search)
  db_schema.gleam       DDL, indexes, FTS5 triggers, schema versioning
  db_migration.gleam    One-time JSONL → SQLite migration
  compressor.gleam      LLM-based context compression (Hermes-inspired)
  structured_memory.gleam  MEMORY.md/USER.md with add/replace/remove + security scan
  llm.gleam             OpenAI-compatible chat + streaming + tool calling
  tools.gleam           Built-in tool implementations
  web.gleam             Web search (Brave) and URL fetching with HTML stripping
  scheduler.gleam       Config-driven scheduler actor (cron + interval)
  cron.gleam            Cron expression parser and matcher
  skill.gleam           Skill discovery, creation, invocation
  tier.gleam            Path-based write permission tiers
  validator.gleam       TOML-defined validation rules engine
  config.gleam          Global + domain config parsing
  supervisor.gleam      Root supervision tree startup
  xdg.gleam             XDG Base Directory path resolution
  time.gleam            Shared timestamp helper (ms since epoch)
  discord/
    gateway.gleam       WebSocket gateway client
    rest.gleam          Discord REST API (send, edit, threads, typing)
    types.gleam         Discord event/embed types
  acp/
    manager.gleam       ACP session orchestration
    monitor.gleam       tmux session polling + status classification

src/
  aura_ws_ffi.erl       Raw WebSocket (SSL + RFC 6455 framing)
  aura_gateway_bridge.erl  Erlang↔Gleam Subject message bridge
  aura_stream_ffi.erl   SSE streaming HTTP client (content + tool call deltas)
  aura_time_ffi.erl     erlang:system_time(millisecond) wrapper
  aura_poller_ffi.erl   EXIT message receiver for trap_exits
```

## Conventions

### Code style

- **Gleam** for all business logic. Erlang FFI only when BEAM primitives are needed (raw sockets, receive, system_time).
- **One Gleam wrapper per FFI function.** `@external` declarations can't be verified at compile time. Each FFI function gets one wrapper in a shared module (e.g., `time.now_ms()`). Other modules import the wrapper, never declare their own `@external` to the same FFI.
- No unnecessary abstractions. Three similar lines > premature helper.
- Pure functions where possible. Side effects in actors.
- `use _ <- result.try(...)` for error propagation (Gleam's Result chaining).

### Naming

- Modules: lowercase, descriptive (`structured_memory` not `mem`)
- Functions: verb_noun (`build_system_prompt`, `resolve_conversation`)
- Actor messages: PascalCase variants (`HandleMessage`, `StoreExchange`)
- FFI modules: `aura_<name>_ffi.erl`

### Testing

- Tests in `test/aura/<module>_test.gleam`
- Use `gleeunit` + `should` assertions
- Test pure functions directly. Test actors via their public convenience functions.
- Temp files in `/tmp/aura-*-test`, clean up after
- 190 tests currently. Don't regress.

### Database

- Single SQLite file at `~/.local/share/aura/aura.db`
- WAL mode, 1s busy timeout
- All access through the `db` actor (never open connections directly)
- FTS5 for full-text search, auto-synced via triggers
- Schema versioned via `schema_version` table
- Conversations keyed by `(platform, platform_id)` — multi-platform ready

### Tool system

- 16 built-in tools defined in `brain.gleam:make_built_in_tools()`
- Tools are static — constructed once at brain startup, stored in `BrainState.built_in_tools`
- Skill-based tools invoked via `run_skill` tool → subprocess
- New tools: add definition to `make_built_in_tools()`, add execution case to `execute_tool()`

### Vision

- Two-model pipeline: vision model describes image, orchestrator runs tool loop
- Vision call is synchronous (`llm.chat_with_options`), runs before the streaming tool loop
- Config is tiered: domain `config.toml` overrides global `config.toml` overrides built-in defaults
- `[models] vision` sets the vision model, `[vision] prompt` sets the description prompt
- Only first image attachment per message is processed
- Graceful fallback: if vision fails, original message is used without description

### Streaming

- LLM calls use SSE streaming via `aura_stream_ffi.erl`
- Content deltas forwarded to brain process for progressive Discord editing
- Tool call deltas accumulated in the Erlang FFI, returned as JSON on stream_complete
- GLM-5.1 sends `reasoning_content` tokens before `content` — the FFI handles both

### Tiers (write permissions)

- **Autonomous**: logs/, anchors.jsonl, events.jsonl, MEMORY.md, skills/
- **NeedsApproval**: config files, domain config, USER.md
- **NeedsApprovalWithPreview**: SOUL.md, META.md

### Memory

- `MEMORY.md` — agent notes, max 2200 chars, `§` delimited entries
- `USER.md` — user profile, max 1375 chars, `§` delimited entries
- Security scan blocks prompt injection and exfiltration patterns
- Both loaded into system prompt on every turn

## Engineering practice

Read `docs/ENGINEERING.md` before starting any feature. The core rule: **"Does this make Aura do work for me today?"** Vertical slices first, polish last.

## Crosscutting concerns checklist

When making any non-trivial change, check whether these need updating:

- [ ] **CLAUDE.md** — does this change the build process, conventions, tool count, env vars, or architecture?
- [ ] **README.md** — does this change user-facing features, setup steps, or workspace structure?
- [ ] **ARCHITECTURE.md** — does this change the supervision tree, data model, message flow, or FFI surface?
- [ ] **Tests** — new public functions need tests. Don't regress the count.
- [ ] **Doc comments** — new public functions need `///` comments.
- [ ] **ADR** — does this involve choosing between approaches? Write a decision record.
- [ ] **Environment variables** — new credentials need: CLAUDE.md, README.md, init.gleam onboarding, .env template
- [ ] **Tool count** — adding/removing tools? Update the count in CLAUDE.md and README.md.
- [ ] **Onboarding** — new required config? Update `init.gleam` first-run wizard.
- [ ] **Eisenhower deploy** — did you deploy the change? Update the launchd plist if env vars changed.

## Common tasks

### Add a new built-in tool

1. Add `llm.ToolDefinition` to `make_built_in_tools()` in `brain.gleam`
2. Add execution case in `execute_tool()` in `brain.gleam`
3. If the tool needs new credentials, add env var to: CLAUDE.md, README.md, init.gleam, .env
4. Write tests for any testable logic
5. Add `///` doc comment to the tool description
6. Update tool count in CLAUDE.md
7. The tool is available to the LLM immediately

### Add a new Discord REST endpoint

1. Add the function to `src/aura/discord/rest.gleam`
2. Use `authed_request()` helper for auth headers
3. Follow existing patterns (URL construction, error handling, response parsing)

### Add a new platform (Telegram, Slack, etc.)

1. The `conversations` table already supports `(platform, platform_id)` — no schema changes
2. Create a new gateway module (like `discord/gateway.gleam`)
3. Route messages through brain with `platform: "telegram"` instead of `"discord"`
4. `conversation.get_or_load_db` handles the rest

### Modify the database schema

1. Increment `current_version` in `db_schema.gleam`
2. Add migration SQL in `migrate_version()` for `v < current_version`
3. `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` for new objects
4. The `migrate_version` function handles forward migration and blocks downgrades

## Environment variables

- `AURA_DISCORD_TOKEN` — Discord bot token
- `ZAI_API_KEY` — z.ai/GLM API key
- `ANTHROPIC_API_KEY` — Anthropic API key (for ACP)
- `BRAVE_API_KEY` — Brave Search API key (optional, for web_search tool)
- `HOME` — used for XDG path resolution

Stored in `~/.config/aura/.env`, sourced by the launchd service plist.

## Architecture Decision Records

Significant architectural decisions are documented in `docs/decisions/`. Each ADR captures context, decision, and consequences.

When making a change that involves choosing between approaches (e.g., "should we use X or Y?"), write an ADR:

1. Create `docs/decisions/NNN-short-title.md` using the template in `docs/decisions/README.md`
2. Add it to the index in `docs/decisions/README.md`
3. Commit it with the code change

ADRs are immutable once accepted. If a decision is reversed, write a new ADR that supersedes the old one.

Current ADRs cover: BEAM over Node.js, raw WebSocket FFI, SQLite over JSONL, multi-platform schema, DB actor pattern, streaming with tool calls, Hermes learning loop, token estimation, no Honcho, context compression.

## Known limitations

- Streaming tool call parsing is manual JSON extraction (no JSON parser in Erlang FFI) — works for OpenAI format but fragile for non-standard APIs
- esqlite NIF requires recompilation after `gleam clean` on OTP 27+
- No graceful shutdown — process stops on SIGTERM, SQLite WAL handles crash recovery
- Discord only — Telegram/Slack gateway modules not yet built (schema ready)
