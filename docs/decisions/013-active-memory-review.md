# ADR 013: Active Memory Review (Hermes-Inspired Learning Loop)

## Status
Accepted (2026-04-09)

## Context
Aura's memory was passive — it only saved when the LLM decided to call the memory tool during normal conversation. The LLM frequently forgot to save state and knowledge after significant actions. Hermes Agent solves this with a "periodic nudge" that spawns a background review agent every 10 turns.

## Decision
After every N turns (configurable, default 10), spawn two parallel background processes:
1. State review — "what changed?" → updates domain STATE.md
2. Memory review — "what was learned?" → updates domain MEMORY.md

Both use the cheap monitor model (glm-5-turbo), max 8 iterations, memory tool only. Results logged to domain log.jsonl. Optional Discord notification shows what was written.

Design differences from Hermes:
- Two parallel spawns instead of sequential (BEAM makes this trivial)
- Domain-aware prompts (Hermes is generic)
- Structured logging for review success/failure rates (Hermes silently swallows failures)

## Consequences
- Memory persists automatically without LLM discipline
- Two extra LLM calls every 10 turns on the cheap model — negligible cost
- State and memory accumulate over sessions without user intervention
- Queryable trail of review outcomes via log.jsonl
- No new actor — fire-and-forget processes that write directly to structured_memory
