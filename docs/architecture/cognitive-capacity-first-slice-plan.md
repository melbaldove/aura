# Cognitive Capacity First Slice Plan

Updated 2026-04-25

Status: first executable decision, delivery, and replay harness implemented. This
supersedes the earlier typed cognitive ontology plan. The slice is a minimal
harness: event persistence, evidence/context building, text-policy context,
model decision envelope, validation, append-only decision logging, delivery
ledger, digest queue, immediate attention surfacing, and label-backed replay.

## Goal

Build the smallest executable loop that can eventually answer:

```text
Given this event, these concern files, these policy files, and these examples,
what should Aura do?
```

Do not build typed concern, claim, gap, learned-preference, or attention
ontologies in code before replay proves they are necessary.

## Current Cut

Implemented:

```text
AuraEvent
-> db.events
-> cognitive_worker
-> Observation
-> EvidenceBundle
-> ContextPacket(policy markdown + concern markdown)
-> LLM DecisionEnvelope
-> validator
-> ~/.local/share/aura/cognitive/decisions.jsonl
-> cognitive_delivery
-> ~/.local/share/aura/cognitive/deliveries.jsonl
-> record | digest queue | surface_now/ask_now Discord delivery
-> decision_ready log
-> ctl probes for smoke/eval/replay, unsuppressed delivery, and digest flush
```

This proves:

- event ingestion persists source events
- duplicates do not enqueue duplicate worker work
- persisted events can be reloaded by ID
- deterministic evidence is citable
- default policy markdown can be created and loaded
- markdown concern files can be loaded as citable text refs
- a model decision is required before a cognitive decision is recorded
- decisions must cite evidence/raw refs and policy refs
- decisions must choose a validated delivery target
- validated decisions are append-only JSONL records
- record decisions do not send user-facing messages
- digest decisions queue until digest flush
- surface_now and ask_now can send immediately with duplicate protection
- smoke/eval event IDs can be suppressed out-of-band without leaking labels to
  the model
- `cognitive-test deliver-now` can inject a realistic Gmail-shaped event,
  require a model decision, and wait for a delivered ledger entry
- `cognitive-digest flush` can force queued digest delivery without waiting for
  a wall-clock window
- `cognitive-replay labels` can rerun labeled persisted events through the
  current worker/model/policy path without notifying Discord
- the worker does not block ingestion

It does not yet prove proactive surfacing quality at scale, concern matching
quality, user-preference learning, label capture quality, or whether the
default policies are good enough.

## Correct Next Cut

Add a correction-label capture UX before expanding proactive thresholds,
autonomy, or cognitive structure.

Files:

- Discord correction actions or a CLI command for writing labels.
- `~/.local/share/aura/cognitive/labels.jsonl`
- Replay report summaries that identify which policy or concern likely needs
  adjustment.

Scope:

- Attach user correction labels to existing event/decision records.
- Produce failure labels such as `false_interrupt`, `missed_important`,
  `bad_concern_match`, and `bad_authority_call`.
- Feed those labels into replay as expectations.
- Keep replay offline-safe where possible: recorded model outputs should be
  enough for behavior regression tests, with live model replay as an explicit
  operator check.

Non-scope:

- No typed concern store.
- No typed semantic claim taxonomy.
- No typed learned preference object.
- No generated `STATE.md`.
- No flare dispatch from cognitive decisions.

## Minimal Types

Keep these because they are harness, not cognition:

```text
Observation
EvidenceBundle
EvidenceAtom
ResourceRef
ContextPacket
DecisionEnvelope
DeliveryDecision
DecisionValidationError
ReplayResult
```

Do not add rich cognitive ontology types back without replay evidence. That
includes code-level objects for concern matching, proposed concerns, semantic
claims, attention judgments, work dispositions, authority requirements, gap
events, and learned preferences.

## Decision Envelope

Use one broad JSON envelope:

```json
{
  "event_id": "...",
  "concern_refs": ["concerns/example.md"],
  "summary": "...",
  "citations": ["evidence:e1", "policy:attention.md"],
  "attention": {
    "action": "record|digest|surface_now|ask_now",
    "rationale": "required: why this is the right attention level",
    "why_now": "",
    "deferral_cost": "",
    "why_not_digest": ""
  },
  "work": {
    "action": "none|prepare|delegate|execute",
    "target": "",
    "proof_required": ""
  },
  "authority": {
    "required": "none|approval|credential|tool|human_judgment",
    "reason": ""
  },
  "delivery": {
    "target": "none|default|domain:<domain-name>",
    "rationale": "why this destination is appropriate"
  },
  "gaps": [],
  "proposed_patches": []
}
```

The validator checks:

- event ID matches the context packet
- citations reference known evidence, policy files, concern files, or raw refs
- `surface_now` and `ask_now` include why-now, deferral-cost, and why-not-digest
- `record` uses `delivery.target=none`
- `digest`, `surface_now`, and `ask_now` use `default` or configured
  `domain:<name>` targets
- non-`none` authority includes a reason
- proposed patches target allowed text-policy or concern files only
- model output cannot mutate state directly

## Text Policies

Default policies should be normal markdown. Example files:

```text
attention.md
authority.md
work.md
learning.md
world-state.md
```

Policy changes happen as proposed patches plus decision logs, not hidden code.

## Concern Files

Concern files are markdown. The first implementation can select candidates by:

- explicit resource IDs in evidence
- actor emails or names in evidence
- file text search over concern files
- recent active concern list

If candidate selection is bad, replay should show `bad_concern_match`; only then
add more structure.

## Replay

Before enabling proactive surfacing, add replay:

```text
historical events
current policy files
concern snapshots
model decisions
validator results
user corrections / later outcomes
evaluation labels
```

Acceptance:

- replay can run without network calls by using recorded model outputs
- replay can run with fresh model calls for policy experiments
- each false interrupt or missed important event is traceable to event evidence,
  policy text, concern text, model output, or validator behavior

## Success Criteria

1. The cognitive worker still cannot block ingestion.
2. There is no typed cognitive ontology in code.
3. Policies and concerns are ordinary text.
4. Model decisions are validated before any effect.
5. Every decision cites evidence and policy/concern context.
6. Replay exists before proactive user-facing behavior.
7. Any new structure is justified by replay failures.
