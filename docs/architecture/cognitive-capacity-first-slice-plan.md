# Cognitive Capacity First Slice Plan

Updated 2026-04-25

Status: first executable decision harness implemented. This supersedes the
earlier typed cognitive ontology plan. The first slice is a minimal harness:
event persistence, evidence/context building, text-policy context, model
decision envelope, validation, append-only decision logging, and later replay.

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
-> decision_ready log
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
- validated decisions are append-only JSONL records
- the worker does not block ingestion

It does not yet prove proactive surfacing quality, concern matching quality,
user-preference learning, replay evaluation, or whether the default policies are
good enough.

## Correct Next Cut

Add replay before any proactive user-facing behavior.

Files:

- `src/aura/cognitive_replay.gleam`
- `test/aura/cognitive_replay_test.gleam`
- CLI or ctl entrypoint for replaying recent decisions

Scope:

- Re-run historical events against recorded or fresh model outputs.
- Compare validator outcomes and decision envelopes.
- Attach user correction labels to decision records.
- Produce failure labels such as `false_interrupt`, `missed_important`,
  `bad_concern_match`, and `bad_authority_call`.
- Keep replay offline-safe: recorded model outputs must be enough for behavior
  regression tests.

Non-scope:

- No typed concern store.
- No typed semantic claim taxonomy.
- No typed learned preference object.
- No generated `STATE.md`.
- No proactive Discord surfacing.
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
  "gaps": [],
  "proposed_patches": []
}
```

The validator checks:

- event ID matches the context packet
- citations reference known evidence, policy files, concern files, or raw refs
- `surface_now` and `ask_now` include why-now, deferral-cost, and why-not-digest
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
