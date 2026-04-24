# Product Principles

Updated 2026-04-24

This document describes what Aura is for. `docs/ENGINEERING.md` describes how
we build it. Architecture notes and ADRs describe how current implementations
satisfy these product principles.

## Core Thesis

Aura exists to preserve and compound the user's cognitive capacity.

The user should be able to spend more of their limited attention on the work
humans do best:

- learning
- thinking
- building
- synthesizing
- refining taste in problem selection

Aura is not an inbox assistant, notification filter, or task router. Those are
possible surfaces. The product is a metacognitive manager agent that converts
raw changes and agent work into high-leverage decisions, verified claims, and
precise help requests.

## Product Model

**Aura is a manager agent.** The brain coordinates work, supervises flares,
monitors uncertainty, and decides when to continue, verify, delegate, ask, or
stop.

**Flares are object-level workers.** A flare can investigate, implement,
verify, or monitor a bounded concern. The brain remains responsible for
manager-level judgment: goal fit, planning quality, verification quality,
authority, and user load.

**Integrations are evidence feeds.** Gmail, Linear, Calendar, Jira, branches,
CI, Slack, and future sources report changes. They do not decide whether the
user should care.

**Concerns are durable units of care or work.** A concern may be a person,
project, ticket, branch, release, trip, commitment, topic, relationship, or
learning frontier. Events matter when they affect a concern.

**Attention judgments spend user capacity.** Aura must decide whether a change
should be suppressed, recorded, digested, surfaced now, clarified now, or
deferred until conditions change. Work execution and authority checks are
separate decisions.

**Gap events are metacognitive signals.** When Aura lacks a tool, permission,
credential, context, preference, verification path, authority, confidence, or
other required condition, it should represent that as a gap with a resolution
path.

## Product Invariants

1. Aura spends user attention deliberately. Responsiveness is not the goal;
   preserving the user's best thinking over time is.
2. Aura distinguishes raw observations from semantic claims, concerns, and
   attention judgments.
3. Aura keeps attention, work, and authority decisions separate.
4. Aura asks for help only when the answer is required or reusable enough to
   improve future behavior.
5. Aura uses agents to reduce planning and verification burden before involving
   the user.
6. Aura escalates only the irreducible human parts: goals, taste, values, risk
   tolerance, missing authority, and ambiguous tradeoffs.
7. Aura's proactive actions must be explainable in human terms, not only by
   source-specific fields or classifier scores.
8. Aura's learned preferences must be inspectable, correctable, and reversible.
9. Aura must not let integrations become policy engines. Source adapters may
   describe what changed; the common layer decides why it matters.

## Planning And Verification

Planning and verification are two of the most expensive parts of orchestrating
agents. Aura should not treat them as human-only work. Instead, it should use
flares and tools to compress them into clear human judgment points.

Agents can help with planning by drafting options, decomposing work, identifying
dependencies, surfacing tradeoffs, and simulating paths.

Agents can help with verification by running checks, inspecting diffs,
cross-checking sources, reproducing failures, reviewing assumptions, and
producing concise proof packets.

The user's role is highest-leverage judgment: choosing goals, setting taste,
deciding acceptable risk, and resolving ambiguity that cannot be responsibly
settled from available evidence.

## Working Definition

Aura should convert:

```text
raw changes + worker activity
```

into:

```text
concern updates + verified claims + attention judgments + precise gap requests
```

while protecting the user's capacity for deep work, synthesis, and problem
selection.
