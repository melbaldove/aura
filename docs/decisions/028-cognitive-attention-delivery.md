# ADR-028: Cognitive attention delivery

**Status:** Accepted
**Date:** 2026-04-25

## Context

Aura's cognitive capacity architecture needs to turn ambient events into user
attention without becoming a hand-built cognitive ontology. The product
principle is that Aura should respect the user's limited cognitive capacity:
record low-value context, batch non-urgent context into digests, surface urgent
state, and ask for a decision when authority, judgment, or preference is
required.

The hard part is judgment, not plumbing. Whether an event should be recorded,
digested, surfaced, or escalated depends on event text, user policy, concern
context, authority boundaries, and current delivery targets. Hardcoding this as
event-type rules would create combinatorial policy code and violate the Bitter
Lesson principle in `docs/ENGINEERING.md`: use the model for general judgment,
keep code as the harness that captures events, builds context, validates safety,
records outcomes, and evaluates behavior over time.

The invariants are:

- Every cognitive decision must be persisted before user-facing delivery.
- User-facing delivery must have an explicit destination rationale.
- `record` decisions must not notify the user.
- Evals and smoke probes must exercise the real path without spamming Discord.
- Duplicate event ids must not send duplicate notifications.

## Decision

Introduce a cognitive delivery layer after the cognitive worker.

The cognitive worker still builds event context and asks the model to choose the
attention action, work action, authority gate, citations, gaps, and proposed
patches. Its decision envelope now also requires:

```json
{
  "delivery": {
    "target": "none|default|domain:<domain-name>",
    "rationale": "why this destination is appropriate"
  }
}
```

Delivery target selection is model-visible policy, not hidden code. The
cognitive context includes `policies/delivery.md` plus the configured delivery
targets. The model may choose `none`, `default`, or `domain:<name>`, but code
validates the target against runtime configuration before anything is sent.

Validation rules are deterministic:

- `record` requires `delivery.target = "none"`.
- `digest`, `surface_now`, and `ask_now` require `default` or a configured
  `domain:<name>`.
- Unknown delivery targets invalidate the decision.

Add a `cognitive_delivery` actor that consumes already-validated decisions from
the cognitive worker and appends delivery outcomes to
`~/.local/share/aura/cognitive/deliveries.jsonl`.

Delivery behavior:

- `record` becomes `recorded` with no Discord send.
- `digest` becomes `queued`; digest windows flush grouped messages by target.
- `surface_now` and `ask_now` send Discord messages immediately to the resolved
  target channel.
- Existing delivery ledger rows for an event id suppress repeat delivery.
- Failed sends are recorded as `failed`; v1 does not silently retry.
- `SuppressEvent(event_id, reason)` lets eval and smoke flows mark synthetic
  events as suppressed before ingesting them.

The supervisor starts `cognitive_delivery` before `cognitive_worker` and passes
the delivery subject into the worker. Existing worker tests can still start the
worker without delivery.

Operator probes are CLI-to-daemon commands:

- `aura cognitive-test deliver-now` injects a realistic Gmail-shaped event,
  waits for event persistence, waits for the model decision, waits for delivery,
  and asserts the result is `ask_now` and delivered.
- `aura cognitive-digest flush` manually flushes queued digest items.

## Consequences

This keeps judgment in the model and policy in ordinary text files, while code
enforces delivery safety, provenance, idempotency, and observability. The
delivery ledger gives an auditable record of what was recorded, queued,
delivered, failed, or suppressed.

The system can now be tested without the user manually sending Gmail messages:
the live probe exercises event ingest, cognitive worker, LLM decision, delivery
ledger, and Discord delivery through the same production path.

The design intentionally does not add a database migration in v1. JSONL is
enough for the current append-only ledger and matches the project's "everything
is a file" practice. If querying, compaction, or retry semantics become
important, the delivery ledger can move behind the DB actor later.

The design also intentionally does not dispatch flares or execute work from
cognitive decisions. This slice is attention delivery only. Autonomous work
dispatch needs a separate decision because it changes authority and
verification requirements.

The main operational limitation is that policy files under `~/.config/aura/`
are user-owned runtime state. Deploying source code does not overwrite existing
live policy files, so policy changes may require explicit migration or an
operator update command.
