# PRD: Aura Work Orchestration And Harness Engineering

Status: Draft tracking document
Date: 2026-05-04

## Purpose

Track the product and engineering findings from OpenAI's Symphony and harness
engineering posts, then translate them into Aura's source-neutral architecture.

Aura should become a manager-agent substrate for Symphony-like workflows while
also using harness engineering principles to build Aura itself. The result
should preserve Aura's existing model:

- The brain is the manager.
- Flares are bounded object-level workers.
- Integrations are evidence feeds, not policy engines.
- Concerns are durable units of care and work.
- Gaps are explicit states with resolution paths.
- Policy and active state start as ordinary text before promoted structure.

This PRD is not an accepted implementation plan. It records the current
direction, requirements, open questions, and first candidate slices.

Related analysis:

- `docs/architecture/aura-work-orchestration-harness-gap-analysis.md`

## Source Findings

### Harness Engineering

The central finding is that agent productivity depends on the harness around
the model more than on one-off prompting. Useful harnesses make the codebase,
runtime, and workflow legible to agents.

Key lessons:

- Human leverage moves from writing code to designing environments, specifying
  intent, and building feedback loops.
- Repo-local knowledge should be the system of record. If an agent cannot
  discover a policy, decision, architecture boundary, or workflow from the repo
  or active context, it effectively does not exist.
- Agent instructions should be an entrypoint into structured docs, not a giant
  prompt blob.
- Agents need direct visibility into runtime behavior: logs, screenshots,
  traces, UI state, metrics, test results, and CI output.
- Architectural taste and quality rules should be enforced mechanically through
  tests, linters, validation scripts, and recurring cleanup tasks.
- High agent throughput creates entropy. Cleanup and doc-gardening must be
  continuous, not an occasional manual event.
- Review should shift toward proof packets: what changed, how it was verified,
  what risk remains, and where human judgment is required.

### Symphony-Style Orchestration

The central finding is that after coding agents become useful, the bottleneck
moves from implementation to managing agentic work.

Key lessons:

- Work should be organized around durable objectives, not ephemeral terminal
  sessions or individual pull requests.
- A task tracker can become a control plane, but Aura should generalize this to
  concern-centered work rather than any one tracker.
- Each active work unit should have an isolated workspace, clear objective,
  progress trail, proof requirement, and review handoff.
- Agents should be given objectives and tools, not only rigid state-machine
  transitions.
- The manager should handle blockers, retries, crashes, stale work, dependency
  sequencing, review loops, and final handoff.
- Speculative work becomes cheaper when the system can safely start, monitor,
  discard, or promote explorations.
- The workflow itself should be explicit and versioned so agents can follow it.

## Aura Product Direction

Aura should support a generalized work orchestration loop:

```text
raw change or user delegation
-> concern/work objective
-> manager-level planning and authority check
-> one or more bounded flares
-> progress, evidence, and gap tracking
-> verification/proof packet
-> handback to brain
-> user-facing decision, review, or completion
```

This should work across sources such as issue trackers, code hosts, calendars,
branches, documents, messages, research feeds, and manual user delegation
without letting any source define the product model.

## Product Requirements

### R1. Concern-Centered Work Units

Aura must represent durable work as concern-linked objectives, not as raw
sessions. A work unit may start from a user request, an existing concern, an
external task, a branch, a calendar commitment, a CI failure, or an ambient
event that has lineage to something the user already cares about.

Minimum fields:

- Objective
- Concern reference or explicit lineage
- Source evidence
- Current status
- Blockers and gaps
- Authority required
- Verification requirement
- Active flare references
- Latest proof or handback

### R2. Brain-Owned Management

The brain remains the sole manager. Flares may investigate, implement, verify,
or monitor, but they do not own manager-level judgment.

The brain decides:

- Whether the objective is worth doing
- Whether the plan is good enough
- Which work can run in parallel
- Whether authority or human judgment is required
- Whether proof is sufficient
- Whether the user should be interrupted, briefed, or left alone

### R3. Flare Workspaces And Identity

Each non-trivial work unit should dispatch flares with stable identity,
workspace isolation where applicable, progress visibility, and resumable
context.

Aura should be able to answer:

- What is currently active?
- Why is it active?
- Which concern or objective does it serve?
- What has the flare tried?
- What is blocked?
- What proof would finish the work?

### R4. Proof Packets

Every flare handback that claims progress should include a proof packet scaled
to the risk of the task.

Minimum proof packet:

- Summary of result
- Files, resources, or evidence touched
- Commands/checks run
- Outcome of each check
- Residual risk
- Human decision required, if any

Proof packets should become part of conversation state and concern history.

### R5. Explicit Gap States

Aura must stop low-value autonomous motion when the next responsible action is
to ask, defer, verify, or request authority.

Gap types include:

- Context gap
- Tool gap
- Credential gap
- Permission gap
- Verification gap
- Authority gap
- Confidence gap
- Strategy gap
- Preference gap

Each gap needs:

- What is missing
- What Aura already tried or inspected
- Why it matters
- Useful next options
- Whether the gap should interrupt now or be batched

### R6. Agent-Legible Aura Repo

Aura's own repo should become more agent-operable over time.

Required surfaces:

- A short agent entrypoint that points to deeper docs
- Workflow docs for issue-to-flare, code-change, review, deploy, and rollback
- Architecture maps for brain, flares, cognitive decisions, delivery, and ACP
- Quality principles that can be checked mechanically
- Verification commands and expected proof format
- Known runtime gotchas and recovery steps
- Current active plans and completed plans

### R7. Mechanical Guardrails

Harness principles should be enforceable by code where possible.

Candidate guardrails:

- Doc freshness checks for changed architecture surfaces
- Regression-test requirement checks for bug-fix commits
- Proof-packet shape checks for flare handbacks
- Stale concern/work cleanup checks
- Runtime-log visibility checks for new background processes
- Prompt-hygiene checks against concrete incident leakage
- Validation that new public functions have doc comments and tests

### R8. Continuous Cleanup

Aura should support recurring cleanup flares that scan for entropy and produce
targeted reports or PRs.

Candidate cleanup loops:

- Stale docs versus current code
- Repeated one-off helpers that should become shared utilities
- Unverified runtime claims in docs
- Flaky or weak tests
- Concerns with no recent evidence or clear next state
- Work units with no active flare, proof packet, blocker, or close reason

### R9. Source-Neutral Adapters

Integrations should report changes and provide evidence. They must not decide
attention, work priority, or policy.

Adapters should normalize:

- Source id
- Event type
- Human-readable summary
- Evidence references
- Related resource links
- Candidate concern references, if directly available

The common layer decides whether the event matters.

## Non-Goals

- Do not build a workflow that only works for one issue tracker.
- Do not turn Aura into a PR bot.
- Do not give flares independent product authority.
- Do not create a hidden structured policy engine before replay proves text
  policy is insufficient.
- Do not add a large typed work ontology as the first slice.
- Do not encode one incident, vendor workflow, or current repo state as durable
  runtime policy.

## Candidate First Slices

### Slice A: Work Objective File And Proof Packet

Add a text-first work objective format under Aura state, linked to concerns and
flares. Teach flare handback to produce and persist a proof packet.

Why first:

- Minimal structure.
- Builds directly on existing concerns and flare handback.
- Gives the brain better management context without requiring external source
  adapters.

### Slice B: Aura Repo Harness Guide

Create `docs/WORKFLOW.md` and related proof-packet guidance for building Aura
with agents. Add a small verification checklist that agents and humans follow
before claiming work is done.

Why first:

- Immediately improves how Aura is built.
- Low runtime risk.
- Gives future flares clearer expectations.

### Slice C: Work Roster View

Expose a user-facing and operator-facing summary of active work: objectives,
flares, blockers, proof status, and next decision needed.

Why first:

- Makes orchestration visible.
- Helps validate whether the model has enough context to manage work.
- Can be read-only before adding new mutation paths.

Recommended sequence:

1. Slice B to make the repo more agent-legible.
2. Slice A to create the minimal work-objective substrate.
3. Slice C to make manager state inspectable.

## Success Criteria

Aura should be able to:

- Start from a natural user delegation and create a bounded work objective.
- Dispatch one or more flares with clear objective, context, and proof
  requirement.
- Track progress, blockers, and gaps without losing the user-facing thread.
- Receive flare handback and decide whether to continue, verify, ask, or stop.
- Produce a concise proof packet before claiming work is complete.
- Keep the Aura repo's own workflow and quality expectations discoverable to
  future agents.
- Surface irreducible human judgment points instead of making the user manage
  every session.

## Open Questions

1. Should the first work objective format live under concern files, separate
   work files, or both?
2. Should proof packets be stored in conversation history only, concern history,
   or a dedicated work log?
3. Which status model is enough for the first slice without overfitting to an
   issue tracker?
4. How should Aura distinguish speculative explorations from committed work?
5. What is the first read-only roster command the user should be able to ask
   for naturally?
6. Which existing deploy/review checks should become mechanical guardrails
   first?

## References

- OpenAI Engineering: "Harness engineering: leveraging Codex in an
  agent-first world" (2026-02-11)
  https://openai.com/index/harness-engineering/
- OpenAI Engineering: "An open-source spec for Codex orchestration: Symphony"
  (2026-04-27)
  https://openai.com/index/open-source-codex-orchestration-symphony/
- Aura product principles: `docs/PRODUCT_PRINCIPLES.md`
- Aura engineering practice: `docs/ENGINEERING.md`
- Aura cognitive capacity architecture:
  `docs/architecture/cognitive-capacity.md`
- Aura flare architecture: `docs/decisions/018-flare-architecture.md`
