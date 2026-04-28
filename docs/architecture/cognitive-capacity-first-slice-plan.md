# Cognitive Capacity First Slice Plan

Updated 2026-04-26

Status: first executable decision, delivery, and replay harness implemented. This
supersedes the earlier typed cognitive ontology plan. The slice is a minimal
harness: event persistence, evidence/context building, text-policy context,
model decision envelope, validation, append-only decision logging, delivery
ledger, digest queue, immediate attention surfacing, delivery dead letters,
correction-label capture, and label-backed replay.

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
-> delivery dead-letter retry for failed send effects
-> natural correction capture into ~/.local/share/aura/cognitive/labels.jsonl
-> patch proposal reports in ~/.local/share/aura/cognitive/patch-proposals/
-> replay-aware improvement reports in ~/.local/share/aura/cognitive/improvement-proposals/
-> decision_ready log
-> ctl probes for smoke/eval/replay, operator correction labels,
   unsuppressed delivery, digest flush, dead-letter retry, patch proposal
   generation, and replay-aware improvement proposal generation
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
- send failures are explicit dead letters, not silent drops
- `cognitive-delivery retry-dead-letter` can resend failed delivery effects
  after channel configuration or provider recovery, without rerunning the model
- smoke/eval event IDs can be suppressed out-of-band without leaking labels to
  the model
- `cognitive-test deliver-now` can inject a realistic Gmail-shaped event,
  require a model decision, and wait for a delivered ledger entry
- `cognitive-digest flush` can force queued digest delivery without waiting for
  a wall-clock window
- ordinary Discord feedback can be recorded as correction labels when it names
  or clearly references a specific event id
- recent delivered attention outputs are rendered into the channel prompt so
  ordinary feedback can resolve against what Aura actually showed before
  falling back to raw event search
- `cognitive-label <event_id> <label> [expected_attention] [note...]` can
  attach correction labels to existing persisted events
- `cognitive-replay labels` can rerun labeled persisted events through the
  current worker/model/policy path without notifying Discord and report the
  likely policy or concern surface implicated by each label
- `cognitive-replay propose-patches` can turn captured labels into a durable
  markdown proposal report grouped by allowed policy or concern surface without
  applying changes
- `cognitive-improve propose` can rerun labeled events through current policy
  and write a replay-aware improvement report with pass/fail evidence next to
  each proposed policy or concern surface
- the worker does not block ingestion

It does not yet prove proactive surfacing quality at scale, concern matching
quality, model-written policy diffs, user-preference learning from labels, or
whether the default policies are good enough.

## Current Learning Cut

Use correction labels to propose text-policy and concern-file patches before
expanding proactive thresholds, autonomy, or cognitive structure.

Initial implementation:

- `cognitive-replay propose-patches` reads labels and writes
  `~/.local/share/aura/cognitive/patch-proposals/<timestamp>.md`.
- `cognitive-improve propose` reads labels, runs live replay, and writes
  `~/.local/share/aura/cognitive/improvement-proposals/<timestamp>.md`.
- Reports group labeled failures by allowed text target such as
  `policies/attention.md`, `policies/authority.md`, `policies/work.md`, or
  `policies/concerns.md`.
- Reports are proposal artifacts only. Policy and concern files are not mutated.

Remaining files:

- `~/.local/share/aura/cognitive/labels.jsonl` as input evidence.
- Existing `policies/*.md` and `concerns/*.md` as the only mutable targets.

Scope:

- Summarize repeated replay failures by implicated surface.
- Propose ordinary markdown patch briefs for attention, authority, work,
  delivery, concerns policy, or specific concern files.
- Keep patch application behind the existing approval/tier path.
- Keep replay offline-safe where possible, with live model replay as an
  explicit operator check.
- Keep GEPA/DSPy as reference designs for reflective prompt/policy
  optimization, not immediate runtime dependencies.
- Preserve Aura's local-first text-file substrate. Optimizer adoption must be
  earned by replay results against real correction labels.

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
