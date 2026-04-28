# ADR-037: Recent attention output context

**Status:** Accepted
**Date:** 2026-04-28

## Context

ADR-036 made `memory(target='attention')` the single public write path for
natural attention feedback. That removed the wrong state where replay labels
and live attention memory could diverge, but it did not solve grounding.

When the user says a recent Aura notification was noisy, missing, or should
have been deferred, Aura needs to know which prior front-facing output the user
is correcting. Searching raw events can work, but it makes the model recover
context indirectly and can waste tool calls. Hard-coded phrase guards or
tool-side semantic resolvers are worse: they encode brittle theories in code
and leak fixtures into production behavior.

The existing invariant is stronger: every front-facing Aura output must be
conversation state. If Aura already sent the user an attention message, the
brain should see that message when interpreting later feedback.

## Decision

Render a bounded **Recent Aura Attention Outputs** section into each
`channel_actor` system prompt.

The section is built mechanically from two existing records:

- `~/.local/share/aura/cognitive/deliveries.jsonl` says which cognitive
  delivery entries reached a user-facing surface.
- SQLite conversation history stores the exact assistant message content the
  user saw in that channel.

Only latest `delivered` entries for the current Discord channel are rendered.
`recorded`, `queued`, `suppressed`, `failed`, and `dead_letter` entries are not
shown because they were not successful user-facing attention outputs in the
current channel.

The base prompt tells the model to resolve natural feedback against this recent
output context before calling `search_events`. `search_events` remains the
fallback when the referent is absent or ambiguous. The model still chooses the
event id, expected attention action, and whether clarification is required.
Code only reads records, filters by channel/status, clips content, and renders
context.

## Consequences

Natural feedback can refer to what Aura actually showed the user without asking
the user for event ids, attention labels, or internal action names.

This preserves the Bitter Lesson direction: no keyword classifier, no
vendor-specific resolver, and no hand-built semantic ontology in code. The
general method is better context plus model judgment, with replay labels as the
learning signal.

Prompt size grows by a bounded amount per channel turn. If the delivery ledger
is corrupt, the system prompt includes a visible unavailable note rather than
silently hiding the context failure.

This depends on ADR-028's delivery ledger and the system invariant that
successful front-facing outputs are persisted to conversation history.
