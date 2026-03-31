# ADR-010: LLM-based context compression

**Status:** Accepted
**Date:** 2026-03-30

## Context

Conversation history was hard-capped at 20 user/assistant pairs (40 messages). Oldest messages were silently dropped, losing context. Users in long conversations would find Aura had forgotten earlier discussion.

Hermes Agent uses a 5-phase context compressor: prune old tool results, protect head, protect tail by token budget, LLM summarization of middle, fix orphaned tool pairs.

## Decision

Implement LLM-based compression modeled after Hermes, simplified for Aura:

1. Trigger at 50% of context window (estimated via chars/4)
2. Protect head (3 messages or 1 existing compaction summary) and tail (20 messages)
3. Serialize middle messages and send to LLM with a structured summary template
4. Summary uses Hermes's sections: Goal, Constraints, Progress, Key Decisions, Relevant Files, Next Steps, Critical Context
5. Summary replaces middle messages as a `[CONTEXT COMPACTION]` SystemMessage
6. Subsequent compressions update the existing summary iteratively ("PRESERVE all existing information, ADD new progress")
7. If LLM compression fails, fall back to hard-dropping oldest messages

Summary token budget follows Hermes: `max(2000, min(content_tokens * 0.20, 12000))`.

## Consequences

- Long conversations retain awareness of full history via summary
- Each compression costs one LLM call (~2K-12K tokens of summary)
- Compression happens synchronously in the actor (adds latency to the message that triggers it)
- Iterative updates prevent the summary from going stale
- Fallback to hard drop ensures compression failure doesn't crash the system
- Message serialization truncates content (500 chars user/assistant, 300 for tool results) to bound summary input size
