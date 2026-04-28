# ADR-029: Cognitive replay labels

**Status:** Accepted
**Date:** 2026-04-25

## Context

Aura needs a way to improve cognitive attention decisions without adding a
hand-built ontology. The delivery slice can now record, queue, surface, and ask,
but quality cannot be judged from one-off live probes. We need replay: take
persisted real events, rerun them against the current model and text policies,
and compare the result to human labels.

The risk is accidentally building a second decision path for evals. If replay
uses a different context builder, validator, or model call shape, it can pass
while production behavior fails. The replay loop must exercise the same worker
that ambient integrations use.

Replay must also preserve the attention invariant: evaluating historical events
must never spend user attention.

## Decision

Store human replay labels in ordinary JSONL at:

```text
~/.local/share/aura/cognitive/labels.jsonl
```

Each label names a persisted `event_id` and loose expectations:

```json
{
  "event_id": "mail-m123",
  "note": "rollback approval should ask now",
  "attention_any": ["ask_now"],
  "work_any": ["prepare"],
  "authority_any": ["human_judgment"],
  "min_citations": 2,
  "min_gaps": 0,
  "require_gap_contains": ""
}
```

Add `cognitive_replay` as a harness around the production cognitive worker:

1. Load labels from `labels.jsonl`.
2. Verify each labeled event exists in SQLite.
3. Suppress delivery for the event id through `cognitive_delivery`.
4. Ask `cognitive_worker` to rebuild the context and call the current model.
5. Wait for a new appended decision in `decisions.jsonl`.
6. Compare the new decision to the label expectations.

Expose this as:

```bash
aura cognitive-replay labels
```

Replay does not ingest duplicate events and does not call a separate model path.
It reuses persisted events, current policy files, current concerns, current
delivery-target context, the cognitive worker, and the normal validator.

## Consequences

Replay now gives Aura a behavior feedback loop before adding more code
structure. If a decision changes after a policy edit, replay shows whether that
change improved or regressed labeled examples.

JSONL labels keep the interface transparent and easy to edit, matching the
project's text-first policy. The trade-off is weaker querying and no label
schema migration. That is acceptable until there are enough labels to justify a
database table or richer tooling.

Replay currently still calls the live model through the worker. That is useful
for operator checks but not enough for cheap deterministic CI. A later slice
should add recorded-output replay so behavior tests can verify policy/validator
changes without network calls.

The first label-writing UX is intentionally not part of this ADR. Labels can be
written manually or by a later Discord/CLI correction action. This keeps the
first replay slice focused on the invariant that production decisions are
replayable and comparable without notifying the user.
