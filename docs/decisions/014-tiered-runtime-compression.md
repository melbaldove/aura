# ADR 014: Tiered Runtime Compression

## Status
Accepted (2026-04-09)

## Context
The compressor existed but only ran on DB load. During long conversations, context grew unchecked until the LLM degraded silently or the API rejected the request. Hermes Agent has a sophisticated runtime compressor with tool pruning, structured summaries, and iterative updates.

## Decision
Tiered compression checked after each turn:
- **Tier 1 (50% of context):** Tool output pruning — replace old ToolResultMessage content >200 chars with placeholder. Free, no LLM call.
- **Tier 2 (70% of context):** Full LLM summarization — structured template (Goal, Constraints, Progress, Decisions, Files, Next Steps, Critical Context, Tools & Patterns). Domain-aware via AGENTS.md and STATE.md injection. Iterative updates across compressions.

Additional features beyond Hermes:
- Domain-aware summaries (AGENTS.md + STATE.md context)
- Summary persistence in DB (survives restarts, Hermes loses this)
- Async compression (doesn't block the brain actor)
- Real token tracking from API `usage.prompt_tokens` via streaming FFI
- Pre-flight check with tool pruning before oversized API calls
- Auto-probe: halves context length on overflow error

## Consequences
- Conversations can run indefinitely without context degradation
- Domain context helps the summarizer prioritize what matters per domain
- Summaries persist across restarts — continuity that Hermes doesn't have
- Two threshold tiers mean free pruning handles most cases without LLM cost
- Token-budget tail protection scales with model context window
- Tool pair sanitization prevents API errors from orphaned call/result messages
