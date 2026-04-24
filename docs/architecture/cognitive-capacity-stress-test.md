# Cognitive Capacity Design Stress Test

Updated 2026-04-24

Status: adversarial review note. This records the subagent critique pass against
`docs/PRODUCT_PRINCIPLES.md`, `docs/architecture/cognitive-capacity.md`, and
`docs/architecture/cognitive-capacity-first-slice-plan.md`.

## Review Setup

Three independent critiques argued the design from different failure modes:

- Product fit: does the architecture preserve cognitive capacity rather than
  becoming a notification/router system?
- Engineering maintainability: can the first implementation prove an invariant
  without creating dual state or actor backpressure?
- Cognitive-load UX: does the user-facing shape reduce burden, or does it
  create new configuration and preference-management work?

## Accepted Objections

### 1. The First Slice Was Not Actually Log-Only

The earlier plan said "log-only" while still including concern mutation and
generated `STATE.md` writes. That conflicts with the product invariant that
current state has one canonical model and with the current codebase, where
conversation memory, review, and dreaming can still write state directly.

Accepted correction: the first executable slice is now:

```text
AuraEvent
-> Observation
-> EvidenceBundle
-> CognitiveInterpretation
-> Validator
-> compact log
```

No production concern mutation or real `STATE.md` writes happen until there is a
DB-backed concern store and existing direct state writers are removed or
redirected.

### 2. Event Ingestion Must Not Block On Cognition

Model interpretation can time out, retry, or fail validation. Putting that work
inside ingestion would create backpressure and make the ingestion actor carry
manager-agent complexity.

Accepted correction: ingestion persists and returns. Cognitive interpretation
runs in a separate worker fed by persisted event IDs.

### 3. Many Preference Gaps Must Not Mean Many Interruptions

The product wants Aura to learn user preferences, so early timelines should
produce many observed preference gaps. But if each gap interrupts the user,
Aura violates its own cognitive-capacity thesis.

Accepted correction: gaps are observed freely, but interruption requires urgency
or reusable value. Low-urgency preference gaps are batched into learning
digests. User-facing preference resolution is a compact decision packet, not a
configuration form.

### 4. Learned Preferences Need A Lifecycle

Inspectable/correctable/reversible preferences are not just prose principles.
They require explicit provenance and controls, or they become invisible
automation debt.

Accepted correction: learned preferences now require scope, examples,
last-used explanation, precedence, confidence, review/expiry, status, and
disable/edit/revert path.

### 5. Watches Must Be Coverage Contracts, Not Feeds

Concern-indexed world awareness can regress into "interesting things on the
internet." That would spend attention without a concern-relative reason.

Accepted correction: a watch now includes relevance test, coverage limits,
expiry/review cadence, noise budget, stop condition, interruption policy, and
capability gaps. World-state observations may suggest concerns, but durable
activation requires lineage to an existing concern, thesis, watch, explicit
request, or user ratification.

### 6. Attention Spending Needs Stronger Proof

`surface_now` and `ask_now` are the expensive actions. They need stricter
validation than ordinary record/digest behavior.

Accepted correction: attention-spending judgments must cite a claim or gap and
explain why now, what user decision is required, the cost of deferral, and why
record/digest is insufficient.

## Remaining Risks

- The first slice may prove schema validity without proving that user-facing
  surfacing reduces cognitive load. Before enabling proactive messages, add an
  evaluation loop for false interrupts, useful deferrals, and reduced
  verification burden.
- The concern store migration is a hard boundary. Do not let typed concerns
  coexist with writable prose `STATE.md` as dual authority.
- Model-backed concern matching is still the hardest part. The design avoids a
  routing matrix, but it still needs replayable fixtures and validation logs to
  find drift.
- Watch configuration must stay user-language-first. Internal source strategy,
  cadence, extraction, and polling mechanics should remain implementation
  details unless a capability gap requires disclosure.
