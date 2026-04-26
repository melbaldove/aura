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
the model should ask one clarifying question instead of guessing.

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
