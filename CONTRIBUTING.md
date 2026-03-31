# Contributing to Aura

## Getting started

```bash
git clone https://github.com/yourusername/aura.git
cd aura
gleam build
gleam test
```

You need Gleam v1.14+, Erlang/OTP 27+, rebar3, and a C compiler (for the SQLite NIF).

If tests fail with "corrupt atom table" after a clean build, run:

```bash
cd build/dev/erlang/esqlite/ebin
erlc -o . ../src/esqlite3.erl ../src/esqlite3_nif.erl
```

## Before you submit

1. **All 184+ tests pass** (`gleam test`)
2. **No new warnings** (`gleam build` should be clean)
3. **New public functions have `///` doc comments**
4. **New features have tests** covering the happy path and at least one error path

## Code style

- Gleam for business logic. Erlang FFI only for BEAM primitives (raw sockets, `receive`, `system_time`).
- No premature abstractions. Three similar lines are better than a helper nobody understands.
- Pure functions where possible. Side effects belong in actors.
- `use _ <- result.try(...)` for error propagation.
- Actor messages are the public API. Direct state access stays private.

## Adding a tool

The most common contribution. Three steps:

1. Add a `llm.ToolDefinition` to `make_built_in_tools()` in `brain.gleam`
2. Add a case in `execute_tool()` in `brain.gleam`
3. Add a test (if the tool has testable logic)

See `CLAUDE.md` for details.

## Adding a skill

Drop a directory in `~/.local/share/aura/skills/<name>/` with a `SKILL.md` and optionally an entrypoint script. No code changes needed.

## Adding a platform (Telegram, Slack, etc.)

The database schema already supports multi-platform via `(platform, platform_id)`. You need:

1. A gateway module (like `discord/gateway.gleam`)
2. A message bridge (like `aura_gateway_bridge.erl`)
3. Route messages through brain with `platform: "telegram"`

Everything downstream (conversation loading, DB persistence, search) works automatically.

## Project structure

Read `CLAUDE.md` for the full source layout and architecture. The key files:

- `brain.gleam` — message routing, LLM tool loop, streaming
- `conversation.gleam` — history buffers, DB persistence, compression
- `db.gleam` — SQLite actor (all DB access goes through here)
- `llm.gleam` — LLM client (chat, streaming, tool calling)

## Commit messages

Use conventional commits:

```
feat: add Telegram gateway adapter
fix: handle empty tool call arguments in streaming
refactor: extract message formatting helper
test: add db migration roundtrip tests
docs: update CLAUDE.md with new tool
chore: update gleam dependencies
```

## Questions?

Open an issue. We're friendly.
