# ADR-035: No semantic memory guard for cognitive feedback

**Status:** Accepted
**Date:** 2026-04-27

## Context

ADR-033 introduced natural-language cognitive feedback capture and added a
`memory` guard intended to prevent feedback such as notification suppression
from bypassing replay labels. The guard was deterministic: it inspected memory
content for notification and suppression terms, then rejected the memory write
until `record_cognitive_feedback` had run in the same turn.

That mechanism violated Aura's architecture direction. It put semantic language
classification into a storage tool, encoded policy as word lists, and created a
combinatorial maintenance surface where every natural phrasing risked needing a
new code case. It also conflicted with the Bitter Lesson principle: Aura should
prefer a minimal harness that records events, exposes tools, calls models,
validates mechanical invariants, and learns from replay over time.

## Decision

Remove semantic keyword guarding from `memory`. The `memory` tool is keyed
plaintext storage: it validates target, key, permissions, persistence, and the
existing security scan, but it does not decide whether natural language is
cognitive feedback.

Natural feedback capture remains model-facing. Runtime prompt and tool policy
should tell the model to resolve the referenced event with `search_events`, call
`record_cognitive_feedback`, and then save any reusable preference with
`memory`. Code validates only the mechanical boundary of the feedback tool:
the referenced event must exist, the label must be valid, the entry must pass
the correction-label security scan, and the label is appended to replay input.

The delivery/Discord guard that prevents final responses from claiming failed
feedback recording as success remains appropriate because it validates actual
tool outcomes, not natural-language semantics.

## Consequences

Aura no longer has hidden language policy embedded in the storage path. New
phrases do not require code changes, and `memory` returns to a single
responsibility.

The trade-off is that the model may still save a reusable preference before
recording the event-level label. That is a model/tool-loop failure, not a
storage-layer concern. The correct pressure is replay-aware evals, prompt
updates, and, if needed later, a more explicit model-routing harness for
feedback turns. It is not keyword lists in unrelated tools.

This supersedes the semantic memory-guard portion of ADR-033. It does not
supersede the `record_cognitive_feedback` tool, replay labels, event existence
validation, or the natural user experience.
