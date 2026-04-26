# Cognitive Capacity Architecture

Updated 2026-04-26

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
-> Delivery ledger
-> Optional digest or immediate surface
-> Replay evaluation against labels
```

The current executable slice reaches validated attention delivery:

```text
AuraEvent
-> Observation
-> EvidenceBundle
-> ContextPacket
-> LLM DecisionEnvelope
-> validator
-> decisions.jsonl
-> cognitive_delivery
-> deliveries.jsonl
-> record | digest queue | Discord surface_now/ask_now
-> cognitive-label correction capture
-> cognitive_replay over labels.jsonl
-> cognitive_patch proposal reports
-> [cognitive] decision_ready log
```

It proves the ingestion, provenance, text-policy, model, validation, delivery
ledger, duplicate suppression, digest queue, and immediate-surface substrate
without dispatching autonomous work. Delivery send failures become explicit
dead-letter ledger entries so they can be retried after configuration or
provider recovery without rerunning the model decision. Operator commands can
also inject a realistic Gmail-shaped event through the live daemon
(`cognitive-test deliver-now`), replay human-labeled persisted events
(`cognitive-replay labels`), attach correction labels (`cognitive-label`),
force digest delivery (`cognitive-digest flush`), and retry failed delivery
effects (`cognitive-delivery retry-dead-letter`). Correction labels can also be
converted into reviewable markdown patch proposal reports
(`cognitive-replay propose-patches`) without mutating policy or concern files.
These probes let the decision, correction, learning, and delivery paths be
verified without asking the user to send provider messages.

## Filesystem Model

Policy files:

```text
~/.config/aura/policies/
  attention.md
  authority.md
  delivery.md
  concerns.md
  work.md
  learning.md
  world-state.md
```

User and domain context files:

```text
~/.config/aura/USER.md
~/.local/state/aura/MEMORY.md
~/.local/state/aura/STATE.md
~/.config/aura/domains/<name>/AGENTS.md
~/.local/share/aura/domains/<name>/MEMORY.md
~/.local/state/aura/domains/<name>/STATE.md
```

These are the directed-conversation surfaces Aura already uses when the user
says "remember this", "save to state", "check current memory", or corrects a
workflow. Ambient cognitive decisions load the same files as citable context, so
the user does not need to create or administer concerns before Aura can use what
it has learned.

Concern files:

```text
~/.local/state/aura/concerns/
  rel-42-release.md
  vc-sourcing-thesis.md
  alice-relationship.md
```

The user should not need to create or manage concern files directly. In normal
use the user talks to Aura naturally: "watch this", "keep track of this",
"remember this for next time", "where are we on X?", or simply asks Aura to do
work that reveals a durable object of care. Aura's internal `track` tool is the
mechanism that turns resolved durable intent into a markdown concern file.

Cognitive logs:

```text
~/.local/share/aura/cognitive/
  events.jsonl
  decisions.jsonl
  deliveries.jsonl
  labels.jsonl
  patch-proposals/*.md
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
- Append decisions, delivery outcomes, and evaluation outcomes.
- Enforce duplicate protection before spending user attention.
- Replay labeled events through the current worker/model/policy path without
  notifying Discord.
- Propose reviewable policy/concern patch reports from correction labels.
- Apply validated file patches through existing tiers.
- Track durable concerns through the `track` tool as ordinary markdown.
- Replay historical events against current policies.

Code must not own:

- A hard-coded cognitive ontology.
- Source-specific attention policy.
- A claim routing matrix.
- A typed concern schema before text concerns fail replay.
- Durable learned preference rules without provenance and correction paths.

## Concern Tracking

Aura tracks concerns; the user uses ordinary language. A concern is any durable
object future observations should be interpreted against: a ticket, branch,
release, project, person, company, thesis, risk, workflow, learning frontier,
deadline, or open question.

The `track` tool is intentionally small. It can start, update, pause, or close a
markdown concern file under `~/.local/state/aura/concerns/`. Code validates the
slug, path, security scan, and file write. The model decides whether tracking is
appropriate from policy, conversation, state, memory, and evidence.

Concern creation is not input parsing. A command like "triage X" may reveal a
concern, but the concern should be created only after Aura has enough context to
know X is durably alive, or when the user has explicitly asked Aura to keep it
in view. Ambient events should update or cite existing concerns when possible;
if Aura suspects a new durable concern but lacks lineage, the gap is the event.

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
    "rationale": "required: why this is the right attention level",
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
  "delivery": {
    "target": "none|default|domain:<domain-name>",
    "rationale": "why this destination is appropriate"
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
- Future-window requests: digest when the next scheduled digest can reach the
  user before the action window; surface now only when digest would miss or
  materially shrink that window.
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
Replay reports should carry the correction label and likely adjustment surface
so the next move is a text policy or concern-file patch, not a hidden heuristic.

GEPA and DSPy are useful reference designs for this loop. In Aura's version,
real events are examples, decisions and deliveries are traces, correction
labels are textual feedback, and `policies/*.md` plus `concerns/*.md` are the
candidate artifacts being improved. Do not adopt GEPA/DSPy as runtime
dependencies before the local replay loop proves the need; first implement the
minimal replay-to-policy-patch path, then evaluate GEPA-style reflective
optimization once enough labeled failures exist.

## Invariants

1. Integrations describe what changed; they do not decide whether the user
   should care.
2. A persisted cognitive decision must have gone through a model call and
   validator.
3. Every accepted decision must cite at least one evidence/raw ref and one
   policy ref.
4. A cognitive decision log is not user notification. Spending attention
   requires a validated delivery target and a delivery ledger entry.
5. Policies and concerns are ordinary text first.
6. Code validates safety, provenance, authority, delivery targets, and patch paths; it does not
   encode cognitive ontology.
7. Model decisions cite event evidence and concern/policy files.
8. `surface_now` and `ask_now` require why-now, deferral-cost, and
   why-not-digest proof.
9. The model sees delivery timing, including local digest windows, before it
   decides that digest is insufficient.
10. Many gaps may be observed; few should interrupt.
11. World-state awareness is concern-indexed, not an unbounded feed of
   interesting facts.
12. Replay evaluation is required before expanding proactive thresholds,
    autonomy, or cognitive structure.
13. New structure is added only when replay shows text plus model judgment is
   insufficient.
