# ADR-008: chars/4 token estimation

**Status:** Accepted
**Date:** 2026-03-31

## Context

Context compression needs to know when conversation history is approaching the model's context window limit. Accurate token counting requires a tokenizer (tiktoken for OpenAI, sentencepiece for others), which adds a Python dependency or requires implementing BPE in Gleam.

Hermes Agent uses `len(text) // 4` — dividing character count by 4 — for all token estimation. This is within ~20% accuracy for English text.

## Decision

Use `string.length(text) / 4` as the token estimate. Same heuristic as Hermes.

- Compression triggers at 50% of context window (100K tokens for GLM-5.1's 200K window)
- Summary token budget: `max(2000, min(content_tokens * 0.20, 12000))`
- No external tokenizer dependency

## Consequences

- Simple, fast, no dependencies
- ~20% inaccurate for English, worse for CJK (where chars/token is closer to 1-2)
- Compression may trigger slightly early or late — acceptable for a threshold check
- If Aura adds CJK-heavy workstreams, may need adjustment
- Matches Hermes's approach, so compression behavior is comparable
