# ADR-032: Cognitive correction labels

**Status:** Accepted
**Date:** 2026-04-26

## Context

Aura can now ingest events, ask the model for a decision, validate the envelope,
deliver or queue attention, and replay labeled events. The missing feedback
surface was capture: after Aura interrupts, defers, misses, or matches the
wrong concern, the user or operator needs a low-friction way to record that
correction against the exact event.

Without correction capture, replay cannot become the mechanism that improves
policy. The system would either keep relying on intuition or add hidden
heuristics without evidence.

## Decision

Add append-only cognitive correction labels to
`~/.local/share/aura/cognitive/labels.jsonl`.

The initial operator interface is:

```text
gleam run -- cognitive-label EVENT_ID LABEL [EXPECTED_ATTENTION] [NOTE...]
```

The command validates that the event exists, validates the label name, scans the
note for prompt-injection/exfiltration patterns, and appends a JSONL label
record. Labels are conventional feedback categories such as `false_interrupt`,
`missed_important`, `bad_deferral`, `useful_digest`, `bad_concern_match`, and
`bad_authority_call`.

Replay reads the same labels and reports both the replay result and the likely
adjustment surface, such as `policy:attention.md`, `policy:authority.md`,
`policy:work.md`, or `concerns/*.md`.

## Consequences

Correction capture gives Aura a concrete learning loop without adding a typed
preference store or cognitive ontology. Labels are evidence that can drive text
policy and concern-file patches.

The v1 interface is deliberately operator-oriented rather than polished Discord
UX. It proves the data path and replay behavior first. A later Discord button
or natural-language correction UX can write the same JSONL records once the
label semantics are stable.
