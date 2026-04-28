# ADR-037: Auto-resolved attention feedback

**Status:** Accepted
**Date:** 2026-04-28

## Context

ADR-036 made `memory(target='attention')` the single public write path for
attention feedback, but still required the model to resolve an event id before
the memory write. In live use, the model could first try to save a standing
preference, receive a tool error that exposed a matching event id, and then
retry with that id. The final state was correct, but correctness depended on an
error-recovery loop.

That violates the intended invariant: ordinary attention feedback should be
fully applied or not applied at all. The user should not need event ids, and the
model should not need to spend tokens discovering ids through failure messages.

## Decision

For event-grounded attention feedback, `memory(target='attention')` accepts
`expected_attention` without requiring `event_id`. The tool resolves a matching
recent event from the attention memory key, content, and note, then records the
replay label and writes the durable attention memory in one operation.

`event_id` remains available as an override when the exact event is already
known. `scope='standing'` remains the explicit path for general preferences not
grounded in a concrete recent event or prior Aura notification.

Standing attention writes that overlap recent events still fail before writing,
but the error no longer makes event-id discovery the normal recovery path. It
asks the model to retry with `expected_attention`, letting the tool resolve and
label the event.

## Consequences

The normal feedback path becomes one tool call:

```text
memory(target='attention', expected_attention='record', ...)
```

The model still performs the semantic judgment of what attention level the user
wanted. Code owns deterministic grounding, validation, persistence, and
ambiguity handling.

This partially supersedes ADR-036's requirement that the model provide a
resolved `event_id` for concrete event feedback.
