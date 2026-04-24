# Cognitive Capacity Architecture

Updated 2026-04-24

Status: exploratory architecture note. The current direction is a minimal code
harness around model judgment, ordinary text policies, replay, and validation.
Do not promote richer cognitive schemas until replay evidence proves they are
necessary.

## Purpose

Aura should preserve and compound the user's cognitive capacity. It does that by
managing the boundary between outside-world changes, agent work, and the user's
attention.

This note translates `docs/PRODUCT_PRINCIPLES.md` and the Bitter Lesson
engineering principle into implementation direction. Related research is tracked
in `docs/research/cognitive-capacity-literature.md`.

## First Principles

**Attention is finite.** Aura should spend it deliberately, not maximize
responsiveness.

**Events are evidence.** A Gmail message, Jira comment, branch push, CI failure,
calendar update, founder launch, or regulation change is not inherently
important. It is an observation that may matter under the user's policies and
current concerns.

**Policy is text first.** User preferences, attention defaults, authority
boundaries, and watch intent should live in ordinary files the user and model can
read. Code should not become a hidden policy engine.

**Concerns are text first.** A concern is initially a markdown file describing
why something matters, current state, resources, standing instructions, open
questions, and recent decisions. Do not build a rich typed concern store until
replay shows text files are insufficient.

**Model interprets; code gates.** The model reads event evidence, policy files,
concern files, and examples. Code validates citations, authority, patch paths,
and output shape. Code does not encode the ontology of cognition.

**Replay decides structure.** If repeated historical events fail because plain
text plus model judgment lacks a specific structure, then add the smallest
structure that fixes the replay failure. Do not add structure by intuition.

## Architecture

```text
Source Adapter
-> AuraEvent log
-> Evidence/context builder
-> Text policy + concern context
-> Model decision envelope
-> Validator / authority gate
-> Decision log
-> Optional patch, digest, surface, or flare dispatch
-> Replay evaluation
```

The current executable slice stops at evidence/context building:

```text
AuraEvent
-> Observation
-> EvidenceBundle
-> [cognitive] context_ready log
```

That is intentional. It proves the ingestion and provenance substrate without
pretending to make attention/work decisions before a real model+policy loop
exists.

## Filesystem Model

Policy files:

```text
~/.config/aura/policies/
  attention.md
  authority.md
  work.md
  learning.md
  world-state.md
```

Concern files:

```text
~/.local/state/aura/concerns/
  rel-42-release.md
  vc-sourcing-thesis.md
  alice-relationship.md
```

Cognitive logs:

```text
~/.local/share/aura/cognitive/
  events.jsonl
  decisions.jsonl
  evaluations.jsonl
```

The SQLite `events` table remains the durable event store. The JSONL paths are
operator-friendly materialized logs when useful, not a second source of truth.

## Minimal Code Harness

Code owns only the parts that must be reliable:

- Persist raw events losslessly.
- Deduplicate source events.
- Extract minimal citable evidence and resource references.
- Select policy and concern text for context.
- Call the model with a bounded context packet.
- Validate decision-envelope shape, citations, authority, and patch paths.
- Append decisions and evaluation outcomes.
- Apply validated file patches through existing tiers.
- Replay historical events against current policies.

Code must not own:

- A hard-coded cognitive ontology.
- Source-specific attention policy.
- A claim routing matrix.
- A typed concern schema before text concerns fail replay.
- Durable learned preference rules without provenance and correction paths.

## Observation And Evidence

`Observation` and `EvidenceBundle` are acceptable because they are provenance
scaffolding, not cognition.

An observation answers "what changed?" Evidence atoms answer "what can the model
cite?" Neither answers "should the user care?"

Evidence extraction should stay minimal and generic. When a source payload has
important fields the extractor does not understand, that should become replay
data or a model-visible raw reference, not an expanding hand-written field
ontology.

## Decision Envelope

The model should eventually return one small JSON object:

```json
{
  "event_id": "event id",
  "concern_refs": ["concerns/rel-42-release.md"],
  "summary": "what changed and why it matters",
  "citations": ["event.subject", "evidence:e1", "concerns/rel-42-release.md"],
  "attention": {
    "action": "record|digest|surface_now|ask_now",
    "why_now": "required for surface_now/ask_now",
    "deferral_cost": "required for surface_now/ask_now",
    "why_not_digest": "required for surface_now/ask_now"
  },
  "work": {
    "action": "none|prepare|delegate|execute",
    "target": "optional target",
    "proof_required": "what would prove the work is done"
  },
  "authority": {
    "required": "none|approval|credential|tool|human_judgment",
    "reason": "why this gate applies"
  },
  "gaps": ["plain-language gaps with resolution paths"],
  "proposed_patches": []
}
```

This is a transport envelope, not a domain ontology. Fields stay broad. Do not
add detailed claim kinds until replay proves the envelope cannot express a real
decision.

## Text Policies

Policy files should be ordinary markdown with examples:

```markdown
# Attention Policy

Interrupt only when the user must decide now or delay is materially costly.

## Defaults
- Routine external updates: record.
- Active commitment changed: digest unless deadline moved earlier.
- Missing reusable preference: batch unless urgent.

## Examples
- If CI fails on an active release branch, delegate verification first.
- If an email asks for approval to send externally, ask before sending.
```

The user should correct policy in natural language. Aura can later propose
patches to these files, but the files remain inspectable and reversible.

## Concern Files

A concern file should be readable by the user and model:

```markdown
# REL-42 Release

## Why This Matters
...

## Current State
...

## Resources
- Jira REL-42
- branch release/x

## Standing Instructions
...

## Open Gaps
...
```

This gives Aura an addressable unit of care without committing to a typed
database model too early.

## Replay Evaluation

Replay is the mechanism that prevents architecture-by-intuition.

For every historical event, store:

```text
event id
policy snapshot refs
concern snapshot refs
model decision
validator result
actual user correction or later outcome
evaluation labels
```

Initial evaluation labels:

```text
false_interrupt
missed_important
bad_deferral
useful_digest
bad_concern_match
bad_authority_call
verification_burden_reduced
planning_burden_reduced
```

The rule: structure earns its way into code only by reducing replay failures.

## Invariants

1. Integrations describe what changed; they do not decide whether the user
   should care.
2. Policies and concerns are ordinary text first.
3. Code validates safety, provenance, authority, and patch paths; it does not
   encode cognitive ontology.
4. Model decisions cite event evidence and concern/policy files.
5. `surface_now` and `ask_now` require why-now, deferral-cost, and
   why-not-digest proof.
6. Many gaps may be observed; few should interrupt.
7. World-state awareness is concern-indexed, not an unbounded feed of
   interesting facts.
8. Replay evaluation is required before proactive surfacing.
9. New structure is added only when replay shows text plus model judgment is
   insufficient.
