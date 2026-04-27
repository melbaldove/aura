# ADR-036: Attention memory feedback

**Status:** Accepted
**Date:** 2026-04-27

## Context

ADR-033 made natural cognitive feedback model-facing through a separate
`record_cognitive_feedback` tool, and ADR-035 removed a semantic guard from the
generic memory path. That still left the model with two public write surfaces
for one user intent: one tool recorded replay labels and another stored the
reusable preference. The split made wrong states representable. Aura could tell
the user future notification behavior had changed after only recording a replay
label, or it could save user memory without creating replay evidence for the
event that prompted the correction.

The product invariant is simpler: when the user corrects Aura's proactive
attention behavior, they are changing attention policy. Replay evidence is an
internal learning side effect of that same action, not a second user-visible
operation.

## Decision

Remove `record_cognitive_feedback` from the model-facing tool list. Keep
correction labels and the `cognitive-label` operator command as internal replay
surfaces.

Extend the existing keyed `memory` tool with `target='attention'`. This target
writes ordinary text attention policy to:

```text
~/.local/share/aura/cognitive/ATTENTION.md
```

For general standing preferences, the model writes `memory(target='attention')`
with a key, content, and `scope='standing'`. For feedback grounded in a concrete
external event, the same memory call instead includes the resolved `event_id`
and `expected_attention`. The tool validates the event and appends the
corresponding correction label to replay input before saving the attention
memory. A no-event attention write without `scope='standing'` fails before
writing, so event feedback cannot silently degrade into a standing preference.

A plain attention-memory save is not treated as completion of an event-feedback
loop. If the model writes a standing preference without event evidence, the
channel actor continues one more model step with explicit context that no replay
label was recorded, so the model can either resolve the concrete event and
rewrite with `event_id`/`expected_attention` or honestly report that only a
standing preference was saved.

The model still does the semantic work: resolving natural language, searching
recent events when needed, choosing the expected attention action, and deciding
whether clarification is necessary. Code validates mechanical invariants only:
target, persistence path, security scan, event existence, label validity, and
that front-facing claims match successful tool outcomes.

## Consequences

Aura has one public write path for attention feedback. The user can speak in
ordinary language, the model gets one obvious tool to call, and code cannot
represent "label recorded but live attention policy unchanged" as a successful
preference update.

Replay remains available because event-grounded attention memory writes append
the same label records used by `cognitive-replay`, `cognitive-patch`, and
`cognitive-improve`.

The old `record_cognitive_feedback` tool name remains blocked at the channel
actor boundary as an internal-tool error so stale model traces fail loudly
rather than silently doing the wrong thing.

This supersedes the model-facing `record_cognitive_feedback` decision in
ADR-033 and the two-tool feedback sequence described in ADR-035. It preserves
ADR-035's core rule: storage tools must not contain semantic keyword guards.
