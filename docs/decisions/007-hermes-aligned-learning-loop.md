# ADR-007: Hermes-aligned learning loop

**Status:** Accepted
**Date:** 2026-03-30

## Context

Hermes Agent (by Nous Research) is the only agent framework with a built-in learning loop — it creates skills from experience, improves them during use, and maintains persistent memory with security scanning.

After analyzing Hermes's actual implementation (not just marketing), the "learning loop" is tools + prompt nudges:

1. `skill_manage` tool creates SKILL.md files (not Python code)
2. `memory_tool` does structured add/replace/remove on MEMORY.md and USER.md
3. System prompt nudges guide the LLM on when to save

There is no magic — the LLM decides when to learn, guided by prompt engineering.

## Decision

Implement the same pattern in Aura, using Hermes's actual prompt text and design:

- `create_skill` and `list_skills` tools for procedural memory
- `memory` tool with add/replace/remove/read for MEMORY.md and USER.md
- `§` delimiter between memory entries (Hermes standard)
- Character limits: 2200 for memory, 1375 for user (Hermes defaults)
- Security scan on all memory writes (15 injection patterns, 16 exfiltration patterns)
- Hermes's exact prompt nudges for memory and skill guidance

## Consequences

- Aura learns from experience without explicit training
- Quality depends on how well the LLM follows nudges (varies by model)
- Memory files are human-readable and editable
- Skills created by the agent are immediately available via `run_skill`
- No dependency on external services (unlike Hermes's optional Honcho integration)
- The `§` delimiter is unusual but matches Hermes for compatibility
