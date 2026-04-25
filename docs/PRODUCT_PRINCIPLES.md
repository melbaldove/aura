# Product Principles

Updated 2026-04-25

This document describes what Aura is for. `docs/ENGINEERING.md` describes how
we build it. Architecture notes and ADRs describe how current implementations
satisfy these product principles.

## North Star

Aura is a conversational, ambient manager agent.

The user can directly tell Aura what to do, ask what matters, delegate work,
correct judgment, and set preferences in natural language. Aura also watches
relevant world state and agent work in the background, prepares context, verifies
claims, coordinates flares, and interrupts only when human attention or authority
is genuinely needed.

The user should control Aura through natural delegation and correction, not by
administering internal machinery. Concepts like concerns, evidence, labels,
routing, delivery ledgers, and replay should stay implementation surfaces unless
the user is explicitly inspecting or debugging Aura.

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

**World state is in scope when it is concern-indexed.** Aura may monitor
companies, founders, markets, repositories, papers, regulations, communities,
competitors, and other external state when the user has a concern, thesis,
relationship, project, risk, or opportunity that makes the change relevant.
World-state observations should not create durable work for the user unless
they connect to an existing concern, thesis, watch, or explicit request.

**Concerns are durable units of care or work.** A concern may be a person,
project, ticket, branch, release, trip, commitment, topic, relationship, or
learning frontier. Events matter when they affect a concern.

**Active state is concern-centered.** Aura has one canonical representation of
what is alive: concern files plus their linked observations, decisions, gaps,
work, and authority history. Start with ordinary text; promote structure only
when replay shows text and model judgment are insufficient.

**Attention judgments spend user capacity.** Aura must decide whether a change
should be suppressed, recorded, digested, surfaced now, clarified now, or
deferred until conditions change. Work execution and authority checks are
separate decisions.

**Gap events are metacognitive signals.** When Aura lacks a tool, permission,
credential, context, preference, verification path, authority, confidence, or
other required condition, it should represent that as a gap with a resolution
path.

**Preferences are learned, not hard-coded.** Aura should start with sensible
defaults and learn user-specific judgment through gap events, corrections,
examples, and ratified policy. Preference gaps should help the user think by
explaining the situation, options, consequences, and proposed default.
Early timelines may produce many observed preference gaps, but Aura should
interrupt only for gaps that are urgent or reusable enough; the rest should be
batched into a learning digest.

**Learned preferences have provenance.** A learned preference must be visible in
ordinary policy text or a decision log with scope, examples, last-used
explanation, confidence, review or expiry condition, and edit/disable/revert
path. Otherwise it becomes invisible automation debt.

**Model interprets; code validates.** Aura should use model intelligence for
concern-relative interpretation of non-trivial events, while deterministic code
extracts evidence, validates citations, enforces authority, renders state, and
logs outcomes.

## Product Invariants

1. Aura spends user attention deliberately. Responsiveness is not the goal;
   preserving the user's best thinking over time is.
2. Aura distinguishes raw observations from semantic claims, concerns, and
   attention judgments.
3. Aura keeps attention, work, and authority decisions separate.
4. Aura asks for help only when the answer is required or reusable enough to
   improve future behavior. Many gaps may be observed; few should interrupt.
5. Aura uses agents to reduce planning and verification burden before involving
   the user.
6. Aura escalates only the irreducible human parts: goals, taste, values, risk
   tolerance, missing authority, and ambiguous tradeoffs.
7. Aura's proactive actions must be explainable in human terms, not only by
   source-specific fields or classifier scores.
8. Aura's learned preferences must be inspectable, correctable, and reversible.
9. Aura must not let integrations become policy engines. Source adapters may
   describe what changed; the common layer decides why it matters.
10. Aura's ambient world awareness is concern-indexed. It watches broadly enough
    to notice relevant change, but spends attention only when that change
    affects a concern, thesis, commitment, relationship, risk, or opportunity.
11. Current state is concern-centered and text-first. Aura must not keep a
    hidden structured policy engine that can drift from the concern and policy
    files the user and model can inspect.
12. Aura must not hard-code user preference where it can learn. Early user
    timelines should produce many observed preference gap events, and those
    gaps should become thoughtful decision prompts or batched learning digests
    rather than raw configuration.
13. Model outputs are proposals until validated. Every decision must cite
    evidence and policy/concern context, obey authority boundaries, and survive
    deterministic validation before it mutates files or spends user attention.
14. Aura must not activate durable concerns from ambient world-state events
    unless they have lineage to an existing concern, thesis, watch, or explicit
    user ratification.
15. Any `surface_now` or `ask_now` action must explain why now, what user
    decision is required, the cost of deferral, and why digest/record is
    insufficient.

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
raw changes + worker activity + relevant world-state movement
```

into:

```text
concern updates + verified claims + attention judgments + precise gap requests
```

while protecting the user's capacity for deep work, synthesis, and problem
selection.
