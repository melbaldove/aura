# ADR-033: Natural cognitive feedback capture

**Status:** Accepted
**Date:** 2026-04-26

## Context

Aura already has correction labels and replay, but the first capture surface was
an operator CLI. That is useful for testing, but it makes the user think in
internal label names and commands. The product principle is the opposite: the
user should correct Aura in ordinary language, and Aura should turn that
conversation into auditable learning evidence.

The alternative was to add Discord buttons or a richer feedback UI first. That
would reduce ambiguity for a narrow set of messages, but it would hard-code a
workflow before we know which corrections matter in practice. It also would not
cover normal conversation such as "too noisy", "you should have asked me", or
"this could have waited for digest".

## Decision

Add a model-facing `record_cognitive_feedback` brain tool. The model uses it
when the user gives ordinary-language feedback about a specific cognitive event.
The tool requires an `event_id` and a label from the existing correction-label
vocabulary, optionally with an expected attention action and note.

Code gates the effect. It verifies that the event exists in SQLite, delegates
label validation and security scanning to the existing correction-label module,
and appends to the same `labels.jsonl` replay input. If the event id is unclear,
the model should first try to resolve colloquial references through recent event
search. For example, "don't notify me about Shopee deliveries" should search
events for Shopee/order/delivery, identify the recent event that produced the
digest or notification, and then record a `false_interrupt` label with the
expected attention chosen by the model. It should ask one clarifying question
only when multiple plausible recent events remain.

If the feedback also states a reusable preference, the model should save that
preference to `USER.md` after recording the correction label. Routine feedback
should not directly edit policy files; labels feed replay and improvement
proposals, while user memory gives the immediate preference.

The `memory` tool enforces this order for notification and digest corrections.
If the model tries to save a user-level notification suppression preference
before a recent cognitive feedback label exists, the tool returns a visible
error directing the model to resolve the event with `search_events`, call
`record_cognitive_feedback`, and only then save the reusable preference. This
keeps "don't notify me about X" from silently bypassing replay evidence.

The CLI `cognitive-label` remains as an operator escape hatch and test surface,
not the primary user experience.

## Consequences

The user can correct Aura naturally in Discord while preserving the same
append-only replay evidence used by the CLI. The learning loop stays text-first:
ordinary feedback becomes labels, labels drive replay, and replay drives
policy/concern patch proposals.

The model now performs the semantic mapping from user phrasing to label. That
is intentional under the Bitter Lesson principle, but it means ambiguous
feedback must be clarified rather than deterministically guessed.

Tool-boundary validation is still necessary. Prompt guidance alone is not a
reliable invariant: when a natural correction looks like a preference, the model
may choose memory first. The harness must reject that route until the auditable
feedback event exists.
