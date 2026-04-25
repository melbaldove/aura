# AGENTS.md

> **MANDATORY: Read [`docs/ENGINEERING.md`](docs/ENGINEERING.md) before designing or implementing anything.** Not after. Not when reminded. Before. Every principle applies — especially #11 (elegance), #12 (no silent errors), and #13 (read the spec, don't guess).

## Project overview

Aura (Autonomous Unified Runtime Agent) is a local-first executive assistant framework built in Gleam on the BEAM VM. It communicates via Discord, manages parallel domains (knowledge partitions), and dispatches Codex sessions for coding tasks.

## Build and test

Prefer the Nix dev shell immediately for local Gleam work. Do not first try the
ambient `gleam` binary and discover the version mismatch after a failed test
run. The repo requires Gleam v1.14+, and the reproducible local path is:

```bash
nix develop --command gleam build              # Compile
nix develop --command gleam test               # Run all tests
nix develop --command gleam run -- start       # Start the agent
nix develop --command gleam run -- init        # First-run setup wizard
```

If `nix develop` is unavailable, then check `gleam --version` before running
builds or tests.

Inside an already-entered Nix shell, on Eisenhower, or in another known-good
Gleam v1.14+ environment:

```bash
gleam build          # Compile
gleam test           # Run all tests
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
- agent-browser (npm) — for browser tool. Install: `npm install -g agent-browser && agent-browser install`

## Architecture

```
supervisor (OneForOne)
├── db          SQLite actor — serializes all DB reads/writes
├── event_ingest Normalizes, tags, and persists integration events
├── cognitive_worker Model-backed cognitive decisions for persisted events
├── cognitive_delivery Validated attention delivery + digest ledger
├── cognitive_replay Label-backed replay checks for cognitive decisions
├── poller      Discord gateway WebSocket
├── flare_manager Flare lifecycle actor — roster, dispatch, monitor, SQLite persist
├── brain       Routes messages, LLM tool loop, progressive streaming, review
├── (domains loaded as context, not actors)
└── scheduler   Config-driven cron + interval + dreaming schedules
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
- **Tool** — primitive operation the LLM can call. 26 built-in tools (filesystem, Discord, skills, memory, tracking, search, web, schedules, shell, browser, attachments, vision, events).
- **Schedule** — a config-driven periodic task defined in `schedules.toml`. Supports fixed intervals ("15m") and cron expressions ("0 9 * * *"). Each schedule invokes a skill, classifies urgency via LLM, and emits findings.
- **Dreaming** — periodic offline memory consolidation. Cron-triggered, per-domain, parallel. Four-phase LLM process (consolidate, promote, reflect, render) that synthesizes knowledge from memory, state, flare outcomes, and conversation summaries. Writes to flat files through SQLite archive for lossless lineage tracking.

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
  cognitive_worker.gleam Async model-backed cognitive decisions for events
  cognitive_delivery.gleam Delivery ledger, digest queue, immediate surfacing
  cognitive_replay.gleam Label-backed replay through current model/policy
  cognitive_probe.gleam Operator-triggered live delivery probe
  concern.gleam         Text-first concern tracking writer
  compressor.gleam      Tiered context compression — tool pruning, domain-aware LLM summarization, iterative updates
  review.gleam          Post-response memory review — auto-persists state + knowledge every N turns
  scaffold.gleam        First-run scaffolding (directory structure, template files, domain creation)
  structured_memory.gleam  Keyed entry memory (§ key/content) with set/remove + security scan
  llm.gleam             OpenAI-compatible chat + streaming + tool calling
  tools.gleam           Built-in tool implementations
  web.gleam             Web search (Brave) and URL fetching with HTML stripping
  dreaming.gleam        Offline memory consolidation — four-phase LLM synthesis, map-reduce orchestration
  scheduler.gleam       Config-driven scheduler actor (cron + interval + dreaming)
  cron.gleam            Cron expression parser and matcher
  shell.gleam           Shell execution with layered security (patterns, normalization, approval)
  browser.gleam         Browser automation (agent-browser CLI wrapper) with SSRF + secret-exfil guards
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
    flare_manager.gleam Flare lifecycle actor — roster, dispatch, monitor, SQLite persistence
    client.gleam        ACP HTTP client (create_run, get_run, cancel, resume, subscribe_events)
    sse.gleam           SSE event stream wrapper for ACP real-time events
    monitor.gleam       Push-based stdio monitor + tmux polling (legacy fallback)
    provider.gleam      Provider-agnostic command builder (legacy tmux path)
    tmux.gleam          tmux session lifecycle (legacy fallback)
    types.gleam         TaskSpec, SessionStatus, AcpReport types

src/
  aura_ws_ffi.erl       Raw WebSocket (SSL + RFC 6455 framing)
  aura_gateway_bridge.erl  Erlang↔Gleam Subject message bridge
  aura_shell_ffi.erl    Shell execution (/bin/sh -c) + command normalization (ANSI, NFKC)
  aura_browser_ffi.erl  agent-browser subprocess runner
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
- **Use `logging.log()` for all runtime logging, never `io.println`.** The `logging` library wraps OTP's `logger` — process-independent, works from any spawned process (including gen_tcp handlers, spawn_unlinked). `io.println` goes through the Erlang group leader and may not reach the log file from spawned processes under launchd/systemd. Call `logging.configure()` once at startup.

### Naming

- Modules: lowercase, descriptive (`structured_memory` not `mem`)
- Functions: verb_noun (`build_system_prompt`, `resolve_conversation`)
- Actor messages: PascalCase variants (`HandleMessage`, `StoreExchange`)
- FFI modules: `aura_<name>_ffi.erl`

### Testing

Behavior tests run on every commit and deploy (`gleam test` for units,
`gleam run -m features/runner` for BDD scenarios). Contract tests against
live providers are opt-in (reserved under `test/contract/`; manual runs
before releases). Every feature ships with a test per principle #10; the
trivial-test hook catches tautologies.

- Unit tests (gleeunit): `test/aura/`
- Feature tests (dream_test + Gherkin): `test/features/`
- Fakes: `test/fakes/`
- Contract tests (gleeunit, opt-in): `test/contract/`

Full guide: `man aura-testing`.

Additional conventions:
- Use `gleeunit` + `should` assertions for unit tests
- Test pure functions directly. Test actors via their public convenience functions.
- Temp files in `/tmp/aura-*-test`, clean up after
- 586 tests currently. Don't regress.
- **HARD RULE: Every bug fix must include a regression test.** No exceptions for "it's hard to test" — if the buggy code has pure functions (encoding, parsing, extraction), test those. If the bug is in process/IO code that genuinely can't be unit tested, document why in the commit message. A `fix:` commit without a test is incomplete.

### Database

- Single SQLite file at `~/.local/share/aura/aura.db`
- WAL mode, 1s busy timeout
- All access through the `db` actor (never open connections directly)
- FTS5 for full-text search, auto-synced via triggers
- Schema versioned via `schema_version` table (currently v4)
- `memory_entries` table for lossless memory archive with lineage tracking
- `dream_runs` table for dream cycle history
- Conversations keyed by `(platform, platform_id)` — multi-platform ready

### Tool system

- 26 built-in tools defined in `brain_tools.gleam:make_built_in_tools()`
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
- Memory files are materialized views — flat files are source of truth during conversation, backed by SQLite archive (`memory_entries`) for lossless lineage tracking
- Write-through: `set_with_archive` / `remove_with_archive` write flat file and archive entry atomically; archive writes are best-effort
- Token budget (10% of context window, configurable via `dreaming.budget_percent`) replaces hard character caps. Dreaming enforces budget offline; LLM writes freely during conversation
- Security scan blocks prompt injection and exfiltration patterns
- Active memory review: every 10 turns, spawns background processes to auto-persist state + knowledge
- Both global memory and user profile loaded into system prompt on every turn

### Dreaming

- Cron-triggered offline memory consolidation, runs all domains in parallel via map-reduce
- Four phases per domain: consolidate (merge/compress entries), promote (extract durable knowledge from episodic sources), reflect (identify cross-domain patterns), render (produce final working set within token budget)
- Global pass after all domains: consolidates global MEMORY.md and USER.md with domain index summaries
- Config in global `config.toml`: `[models] dream` (model spec, defaults to brain model), `[dreaming] cron` (cron expression, default `"0 4 * * *"`), `[dreaming] budget_percent` (% of context window for memory, default `10`)
- Dream results logged to `dream_runs` table; memory writes go through `set_with_archive` / `remove_with_archive` for lineage tracking
- Retry logic: each phase retries up to 3 times with 5s/15s/30s backoff delays
- Per-domain timeout: 10 minutes; timed-out domains are skipped gracefully

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

- [ ] **AGENTS.md** — does this change the build process, conventions, tool count, env vars, or architecture?
- [ ] **README.md** — does this change user-facing features, setup steps, or workspace structure?
- [ ] **ARCHITECTURE.md** — does this change the supervision tree, data model, message flow, or FFI surface?
- [ ] **Tests** — new public functions need tests. Don't regress the count.
- [ ] **Doc comments** — new public functions need `///` comments.
- [ ] **ADR** — does this involve choosing between approaches? Write a decision record.
- [ ] **Environment variables** — new credentials need: AGENTS.md, README.md, init.gleam onboarding, .env template
- [ ] **Tool count** — adding/removing tools? Update the count in AGENTS.md and README.md.
- [ ] **Onboarding** — new required config? Update `init.gleam` first-run wizard.
- [ ] **Production deploy** — use `bash scripts/deploy.sh` (NEVER manual scp+build). Update the launchd plist if env vars changed.

## Deploy

**Always use `bash scripts/deploy.sh`.** Never manual scp+build — it causes stale beams, missing NIF, and FFI mismatch bugs.

**Before deploying, tail `/tmp/aura.log` on Eisenhower for in-flight work.** A deploy SIGTERMs the VM and kills any unlinked background process. Specifically, check for:
- `[review] Spawned ... review for <domain>` with no matching `... review for <domain>: N entries written` or `... review failed` — a skill/memory/state review is still running, its LLM call will be aborted and no outcome will be logged
- Active `[brain] Tool:` calls in the current tool loop — the user's in-progress turn will be interrupted
- `[dreaming]` phases mid-run — dream cycles can take minutes per phase
- Streaming LLM calls (`[llm] Streaming`) without a corresponding completion

If any of these are in-flight, wait for them to settle (or warn the user) before deploying. Deploying over a conversation is more disruptive than it looks — we already lost a skill-review outcome to a mid-review deploy.

The script does:
1. `rsync` source + test `.gleam`/`.erl` files and `evals/` fixtures to Eisenhower (192.168.50.140)
2. `gleam clean && gleam build` — ensures no stale beams from previous builds
3. Fix esqlite NIF — `gleam clean` wipes the NIF, OTP 27+ needs manual `erlc` recompile
4. Recompile all Erlang FFI beams — `gleam build` doesn't compile `.erl` files, so every `aura_*_ffi.erl` is compiled with `erlc -o ebin`
5. `launchctl kickstart -k` restarts the launchd service (`com.aura.agent`)
6. Waits 5s and tails the log to verify startup

**Gotchas:**
- Never deploy with `gleam build` alone — FFI beams won't update
- Never `gleam clean` without the subsequent `erlc` steps — esqlite NIF will be corrupt
- If you add a new env var, update `~/Library/LaunchAgents/com.aura.agent.plist` on Eisenhower
- The deploy script never kills tmux sessions — running flares survive deploys
- Exit code 1 from the script is usually the final `tail | grep` not matching — the deploy itself succeeded if you see "Restarting Aura"

## Common tasks

### Add a new built-in tool

1. Add `llm.ToolDefinition` to `make_built_in_tools()` in `brain_tools.gleam`
2. Add execution case in `execute_tool()` in `brain_tools.gleam`
3. If the tool needs new credentials, add env var to: AGENTS.md, README.md, init.gleam, .env
4. Write tests for any testable logic
5. Add `///` doc comment to the tool description
6. Update tool count in AGENTS.md
7. The tool is available to the LLM immediately

### Add a new domain

Domains follow XDG Base Directory layout:
- Config: `~/.config/aura/domains/<name>/` — AGENTS.md, config.toml
- Data: `~/.local/share/aura/domains/<name>/` — MEMORY.md, log.jsonl, repos/, logs/
- State: `~/.local/state/aura/domains/<name>/` — STATE.md

Steps:
1. Create config: `~/.config/aura/domains/<name>/config.toml` with name, description, cwd, tools, discord channel
2. Optionally add `[acp]` section for provider config (defaults: `provider = "Codex"`, `worktree = true`)
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
- `CLAUDE_CODE_OAUTH_TOKEN` — Codex auth token for headless ACP sessions (from `Codex setup-token`)
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

Current ADRs cover: BEAM over Node.js, raw WebSocket FFI, SQLite over JSONL, multi-platform schema, DB actor pattern, streaming with tool calls, Hermes learning loop, token estimation, no Honcho, context compression (superseded), ACP manager actor, keyed memory entries, active memory review, tiered runtime compression, ACP protocol for agent dispatch, memory dreaming, and text-first concern tracking.

## Known limitations

- Streaming tool call parsing is manual JSON extraction (no JSON parser in Erlang FFI) — works for OpenAI format but fragile for non-standard APIs
- esqlite NIF requires recompilation after `gleam clean` on OTP 27+
- No graceful shutdown — process stops on SIGTERM, SQLite WAL handles crash recovery
- Discord only — Telegram/Slack gateway modules not yet built (schema ready)
