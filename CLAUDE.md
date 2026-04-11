# CLAUDE.md

> **MANDATORY: Read [`docs/ENGINEERING.md`](docs/ENGINEERING.md) before designing or implementing anything.** Not after. Not when reminded. Before. Every principle applies — especially #11 (elegance), #12 (no silent errors), and #13 (read the spec, don't guess).

## Project overview

Aura (Autonomous Unified Runtime Agent) is a local-first executive assistant framework built in Gleam on the BEAM VM. It communicates via Discord, manages parallel domains (knowledge partitions), and dispatches Claude Code sessions for coding tasks.

## Build and test

```bash
gleam build          # Compile
gleam test           # Run all tests (316 tests)
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
├── acp_manager ACP session lifecycle actor — dispatch, monitor, persist
├── brain       Routes messages, LLM tool loop, progressive streaming, review
├── (domains loaded as context, not actors)
└── scheduler   Config-driven cron + interval schedules
```

### Message flow

```
Discord → Gateway → Poller → Brain → Domain → LLM → Brain → Discord
                                   ↘ (direct) → LLM with tools → Discord
```

Brain routes by `channel_id` to resolve a domain. Every channel gets the full tool loop — domains are context selectors, not capability boundaries.

### ACP Handback

When an ACP session completes (`end_turn`), the event loop captures three layers of results:
- Monitor's cumulative summary (Done field from LLM progress)
- Last 5 tool call names (what the agent did at the end)
- Agent's final message text (the actual conclusion)

These are formatted as a system message, appended to the thread conversation, and the brain re-enters its tool loop — responding to the user naturally with the agent's findings. If the tool loop fails, the raw result is posted to Discord as a fallback.

### Vision pipeline

```
User sends image → Gateway parses attachments → Brain detects image
  → Vision model (GLM-5V-Turbo) describes image → Description prepended to user message
  → Normal tool loop (GLM-5.1) continues with enriched message
```

Two-model pipeline: vision model as preprocessor, orchestrator model for tool loop. Config is tiered: domain overrides global overrides built-in defaults. Vision model and prompt configurable per domain via `[models] vision` and `[vision] prompt` in config.toml.

### Key abstractions

- **Domain** — a knowledge partition representing an area of the user's life (job, project, responsibility). Has its own config, AGENTS.md, anchors, logs, skills, conversation history. One Discord channel per domain.
- **Conversation** — per-channel message history. In-memory buffer (hot cache) backed by SQLite. Tiered auto-compression: tool pruning at 50%, LLM summarization at 70% of context window.
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
  compressor.gleam      Tiered context compression — tool pruning, domain-aware LLM summarization, iterative updates
  review.gleam          Post-response memory review — auto-persists state + knowledge every N turns
  scaffold.gleam        First-run scaffolding (directory structure, template files, domain creation)
  structured_memory.gleam  Keyed entry memory (§ key/content) with set/remove + security scan
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
    manager.gleam       ACP session lifecycle actor — dispatch, monitor, state, persistence
    client.gleam        ACP HTTP client (create_run, get_run, cancel, resume, subscribe_events)
    sse.gleam           SSE event stream wrapper for ACP real-time events
    monitor.gleam       tmux session polling + LLM status classification (legacy fallback)
    provider.gleam      Provider-agnostic command builder (legacy tmux path)
    session_store.gleam JSON file store for session persistence across restarts
    tmux.gleam          tmux session lifecycle (legacy fallback)
    types.gleam         TaskSpec, SessionStatus, AcpReport types

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
- 341 tests currently. Don't regress.
- **HARD RULE: Every bug fix must include a regression test.** No exceptions for "it's hard to test" — if the buggy code has pure functions (encoding, parsing, extraction), test those. If the bug is in process/IO code that genuinely can't be unit tested, document why in the commit message. A `fix:` commit without a test is incomplete.

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

- Keyed entry format: `§ key\ncontent` blocks, upserted by key (set/remove)
- Three targets: `state` (per-domain STATE.md), `memory` (per-domain MEMORY.md), `user` (global USER.md)
- XDG paths: STATE.md in `~/.local/state/aura/`, MEMORY.md in `~/.local/share/aura/`, USER.md in `~/.config/aura/`
- Security scan blocks prompt injection and exfiltration patterns
- Active memory review: every 10 turns, spawns background processes to auto-persist state + knowledge
- Both global memory and user profile loaded into system prompt on every turn

### Compression

- Tiered: tool output pruning at 50% of context window (free), full LLM summarization at 70%
- Domain-aware structured summaries using AGENTS.md + STATE.md context
- Iterative updates: subsequent compressions update the previous summary, not re-summarize
- Token-budget tail protection (~20% of context window), tool pair sanitization
- Summaries persisted in DB `compaction_summary` column, restored on session reload
- Pre-flight check prunes tool outputs before sending oversized requests
- Auto-probe: halves context length on overflow error and retries

## Engineering practice

The core rule: **"Does this make Aura do work for me today?"** Vertical slices first, polish last.

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
- [ ] **Production deploy** — use `bash scripts/deploy.sh` (NEVER manual scp+build). Update the launchd plist if env vars changed.

## Common tasks

### Add a new built-in tool

1. Add `llm.ToolDefinition` to `make_built_in_tools()` in `brain.gleam`
2. Add execution case in `execute_tool()` in `brain.gleam`
3. If the tool needs new credentials, add env var to: CLAUDE.md, README.md, init.gleam, .env
4. Write tests for any testable logic
5. Add `///` doc comment to the tool description
6. Update tool count in CLAUDE.md
7. The tool is available to the LLM immediately

### Add a new domain

Domains follow XDG Base Directory layout:
- Config: `~/.config/aura/domains/<name>/` — AGENTS.md, config.toml
- Data: `~/.local/share/aura/domains/<name>/` — MEMORY.md, log.jsonl, repos/, logs/
- State: `~/.local/state/aura/domains/<name>/` — STATE.md

Steps:
1. Create config: `~/.config/aura/domains/<name>/config.toml` with name, description, cwd, tools, discord channel
2. Optionally add `[acp]` section for provider config (defaults: `provider = "claude-code"`, `worktree = true`)
3. Create `~/.config/aura/domains/<name>/AGENTS.md` with repo index, domain expertise, jira instance if applicable
4. Create data/state dirs (or use `scaffold.scaffold_domain`)
5. Create the Discord channel (if it doesn't exist)
6. Restart Aura to pick up the new domain

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
- `ANTHROPIC_API_KEY` — Anthropic API key (for ACP, optional if using CLAUDE_CODE_OAUTH_TOKEN)
- `CLAUDE_CODE_OAUTH_TOKEN` — Claude Code auth token for headless ACP sessions (from `claude setup-token`)
- `BRAVE_API_KEY` — Brave Search API key (optional, for web_search tool)
- `HOME` — used for XDG path resolution

Configured in the launchd plist (`~/Library/LaunchAgents/com.aura.agent.plist`) on macOS.

## Architecture Decision Records

Significant architectural decisions are documented in `docs/decisions/`. Each ADR captures context, decision, and consequences.

When making a change that involves choosing between approaches (e.g., "should we use X or Y?"), write an ADR:

1. Create `docs/decisions/NNN-short-title.md` using the template in `docs/decisions/README.md`
2. Add it to the index in `docs/decisions/README.md`
3. Commit it with the code change

ADRs are immutable once accepted. If a decision is reversed, write a new ADR that supersedes the old one.

Current ADRs cover: BEAM over Node.js, raw WebSocket FFI, SQLite over JSONL, multi-platform schema, DB actor pattern, streaming with tool calls, Hermes learning loop, token estimation, no Honcho, context compression (superseded), ACP manager actor, keyed memory entries, active memory review, tiered runtime compression, ACP protocol for agent dispatch.

## Known limitations

- Streaming tool call parsing is manual JSON extraction (no JSON parser in Erlang FFI) — works for OpenAI format but fragile for non-standard APIs
- esqlite NIF requires recompilation after `gleam clean` on OTP 27+
- No graceful shutdown — process stops on SIGTERM, SQLite WAL handles crash recovery
- Discord only — Telegram/Slack gateway modules not yet built (schema ready)
