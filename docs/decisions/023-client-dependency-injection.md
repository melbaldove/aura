# ADR-023: Dependency injection for external client boundaries

**Status:** Accepted
**Date:** 2026-04-19

## Context

Production code called external services directly at ~50 call sites:
`rest.send_message(...)` for Discord, `llm.chat_streaming_with_tools(...)`
for LLM, `skill.invoke(...)` for subprocess skills, `aura_browser_ffi:run`
for agent-browser. Testing any workflow end-to-end required either
spinning up real HTTP servers or monkey-patching global state — both
brittle. Writing integration tests against this shape was infeasible.

## Decision

Introduce typed clients at every external boundary, in `src/aura/clients/`:

- `DiscordClient` — wraps `discord/rest.*`
- `LLMClient` — wraps `llm.chat_streaming_with_tools`, `llm.chat_with_tools`, and `llm.chat_with_options`
- `SkillRunner` — wraps `skill.invoke`
- `BrowserRunner` — wraps `browser.run_ffi` and `browser.url_has_secret`

Each is a Gleam record of function fields. Production constructs clients
via `production(...)` that delegate to the existing low-level modules —
zero new behavior, just wrapping. Tests construct fake clients from
`test/fakes/*.gleam`.

Clients flow through `BrainConfig` → `BrainState` / `ChannelState` /
`ToolContext` as regular fields.

## Consequences

**Better:**
- Every test is a fake swap away from full coverage
- External contracts are explicit at the type level
- Future backend swaps (Telegram instead of Discord, alternate LLM provider)
  become one-line changes to the production constructor
- Matches existing subject-passing pattern (db_subject, scheduler_subject)

**Worse:**
- Touched ~50 call sites, ~15 files in the rollout
- `ToolContext` and `BrainConfig` gained extra fields
- `brain.gleam` and `brain_tools.gleam` thread every REST/LLM/skill call
  through the client

## Related

- ADR-024 (dual-framework testing strategy depends on this)
- Principle #10 in docs/ENGINEERING.md (verification non-negotiable)
