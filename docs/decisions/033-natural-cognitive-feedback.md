# ADR-033: Natural cognitive feedback capture

**Status:** Accepted; semantic memory guard superseded by ADR-035
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
search using source-neutral content words from the user's message. It then
records a correction label with expected attention chosen from meaning: no
future user-facing attention means `record`, later batch attention means
`digest`, and immediate interruption means `surface_now` or `ask_now`. It should
ask one clarifying question only when multiple plausible recent events remain.
Runtime prompts and tool descriptions must stay source-neutral. They must not
include vendor/device-specific examples or phrase-to-action mappings copied from
live tests; concrete cases belong in replay fixtures, not in production policy.

If the feedback also states a reusable preference, the model should save that
preference to `USER.md` after recording the correction label. Routine feedback
should not directly edit policy files; labels feed replay and improvement
proposals, while user memory gives the immediate preference.

The original version of this ADR made the `memory` tool enforce this order for
notification and digest corrections. ADR-035 supersedes that mechanism: semantic
keyword guards in `memory` are the wrong abstraction. The desired model
behavior remains the same, but it is enforced through prompt/policy pressure,
replay labels, and evaluation rather than deterministic word lists in storage
code.

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

Tool-boundary validation is still necessary for mechanical invariants such as
event existence, label validity, append-only persistence, and security scanning.
It must not become semantic language classification inside unrelated tools.
