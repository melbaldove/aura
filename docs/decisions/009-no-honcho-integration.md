# ADR-009: No Honcho integration

**Status:** Accepted
**Date:** 2026-03-31

## Context

Hermes Agent integrates with Honcho (by Plastic Labs) for dialectic user modeling — an external service that builds Theory of Mind representations of users via LLM reasoning. Honcho achieves strong benchmark scores (90.4% LongMem S, 89.9% LoCoMo).

We evaluated Honcho against Zep/Graphiti (temporal knowledge graphs, which the user has prior experience with) and a simple local approach.

Self-hosted Honcho requires 3 services (PostgreSQL + pgvector, FastAPI server, background deriver worker) plus 2-3 LLM API keys (Anthropic for dialectic, Gemini for summarization, Groq for query generation).

## Decision

Don't integrate Honcho. Use the local memory system (USER.md + MEMORY.md with structured add/replace/remove) instead.

Rationale:
- Infrastructure overhead is disproportionate for a single-user agent
- USER.md + memory tool nudges cover ~80% of the user modeling value
- Honcho is a young project — coupling adds dependency risk
- The memory system is already Hermes-aligned and working
- Zep/Graphiti's temporal knowledge graph is more proven but also heavy (Neo4j dependency)

## Consequences

- No automatic user profiling — the LLM must be nudged to save facts
- No semantic search over user context (FTS5 keyword search only)
- No dialectic reasoning (Theory of Mind snapshots)
- Simpler deployment — no external services
- Can revisit if Honcho matures or a lightweight local alternative emerges
- The USER.md approach is transparent and human-editable
