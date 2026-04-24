# Cognitive Capacity Architecture

Updated 2026-04-24

Status: exploratory architecture note. Promote to an ADR when the first
implementation slice commits to concrete schemas and actor responsibilities.

## Purpose

Aura should preserve and compound the user's cognitive capacity. It does that by
managing the boundary between outside-world changes, agent work, and the user's
attention.

This note translates the product principles in
`docs/PRODUCT_PRINCIPLES.md` into a source-neutral architecture model.

## First Principles

**Attention is finite.** Aura should spend it deliberately, not maximize
responsiveness.

**Events are evidence.** A Gmail message, Jira comment, branch push, CI failure,
calendar update, or Linear transition is not inherently important. It is an
observation that may support claims about a concern.

**Concerns are the center.** Humans do not primarily manage events. They manage
ongoing cares: projects, people, tickets, releases, commitments, trips,
relationships, risks, opportunities, and learning frontiers.

**Planning and verification are managed work.** Aura should use agents and tools
to reduce planning and verification load before asking the user to decide.

**Metacognition is operational.** When Aura cannot responsibly continue, it
should emit a precise gap with attempted self-help and a resolution path.

## Core Objects

### Observation

A source-neutral record that something changed.

Candidate fields:

```text
id
source
resource_id
resource_type
event_type
event_time_ms
actors
text
state_before
state_after
relations
raw_ref
raw_data
```

Examples:

- Gmail message received: resource is a thread, actors are sender and
  recipients, text is subject plus snippet.
- Jira ticket transitioned: resource is an issue, state changed from one status
  to another, actors include assignee and changer.
- Branch pushed: resource is a branch or PR, relations include repository,
  commit, CI run, and linked ticket.

Integrations produce observations. They do not decide attention policy.

### Concern

A durable unit of user care or work.

Candidate fields:

```text
id
label
kind
summary
actors
resources
status
stakes
active_window
preference_refs
history_refs
```

Concerns may be explicit ("track this release") or inferred from repeated
observations and user behavior. Concern identity is what lets Aura group
evidence across integrations.

### SemanticClaim

A typed claim Aura believes about an observation, concern, actor, or state
change. Claims are falsifiable statements supported by evidence. They do not
decide attention by themselves.

Candidate fields:

```text
id
kind
subject
object
confidence
evidence_refs
about_observation
about_concern
about_actor
explanation
qualifiers
status
```

Initial claim kinds should stay small, useful, and source-neutral:

```text
contains_request
responsibility_assigned
commitment_created
commitment_changed
deadline_created
deadline_moved_earlier
deadline_moved_later
work_blocked
work_unblocked
approval_requested
approval_granted
approval_rejected
artifact_changed
artifact_failed_verification
artifact_passed_verification
decision_needed
decision_made
risk_increased
risk_decreased
duplicate_or_superseded
```

Claims are the bridge between source-specific evidence and source-neutral
judgment.

Do not use claims for everything in the middle of the pipeline. These are
separate concepts:

- `mentions_user` is usually evidence, not enough to drive judgment.
- `belongs_to_active_concern` is a `ConcernLink`, not a claim.
- `high_consequence` is a `StakesEstimate`, not a claim.
- `routine_update` and `low_signal` are often attention outcomes; use narrower
  evidence or claims such as `duplicate_or_superseded` or `status_only_update`
  only when the statement is falsifiable.
- `needs_review` is too broad; prefer claims like `approval_requested`,
  `artifact_changed`, `artifact_failed_verification`, or `decision_needed`.

Before adding a claim kind, check:

- Can this be false?
- What evidence supports it?
- Can more than one integration emit it?
- Does it avoid deciding attention by itself?
- Can the user correct it?
- Can later observations supersede it?
- Does it help planning, verification, or attention judgment?

### ConcernLink

A source-neutral relation between an observation, resource, actor, or claim and
a concern.

Candidate fields:

```text
id
concern_id
target_ref
relation
confidence
evidence_refs
explanation
```

Concern links answer "what does this relate to?" without deciding how important
it is or whether to surface it.

### StakesEstimate

An estimate of what happens if Aura ignores or delays action on a concern or
claim.

Candidate fields:

```text
id
concern_id
claim_refs
level
reversibility
deadline_pressure
blast_radius
reason
confidence
```

Stakes are derived from claims, concern state, reversibility, actor importance,
deadline pressure, and learned preferences. They are not source fields and not
attention actions.

### AttentionJudgment

Aura's decision about how to spend or preserve user attention.

Candidate fields:

```text
id
attention_action
reason
confidence
concern_id
observation_refs
claim_refs
mode
trigger
correction_path
```

Initial attention actions:

```text
suppress
record
digest_later
surface_now
ask_now
defer_until_condition
```

`suppress` means no user-facing surface. Retention policy separately decides
whether any audit or event record remains.

`record` stores the event or concern update without spending attention.

`digest_later` includes the update in a scheduled or opportunistic summary.

`surface_now` interrupts or prominently presents the update.

`ask_now` requests a human answer because responsible progress depends on it.
The reason is usually represented by a `GapEvent`.

`defer_until_condition` holds the update until a time, context, or stakes
condition changes.

The judgment must explain itself in human terms:

```text
Surfaced because this changes an active commitment and the deadline moved earlier.
```

not only:

```text
Matched sender bob@example.com.
```

Attention judgments must not encode work execution or authority. Those are
separate decisions.

### WorkDisposition

Aura's decision about what work, if any, should happen after an observation or
judgment.

Candidate fields:

```text
id
work_action
target
reason
proof_required
result_expected
```

Initial work actions:

```text
none
prepare
delegate
execute
```

Examples:

- CI failed on an active branch: attention may be `digest_later` or
  `surface_now`; work may be `delegate` a flare to inspect the failure.
- Email asks for approval: attention may be `ask_now`; work may be `prepare` a
  reply draft.
- Newsletter: attention may be `suppress`; work is usually `none`.

### AuthorityRequirement

Aura's decision about whether progress requires approval, credentials, tools,
context, or human judgment.

Candidate fields:

```text
id
requirement
reason
resolver
gap_ref
```

Initial requirements:

```text
none
approval
credential
permission
capability
context
human_judgment
```

Authority is separate from attention. Aura may technically be able to send an
email, merge a PR, or close a ticket, while still requiring user authority
before doing so.

### GapEvent

A metacognitive event emitted when Aura cannot responsibly proceed.

Candidate fields:

```text
id
kind
scope
observed_during
concern_id
blocks
attempted
self_help_available
impact
resolver
options
recommended_next_step
durable
risk_if_ignored
```

Kinds:

```text
capability
credential
permission
availability
context
spec
scope
identity
preference
authority
verification
confidence
ambiguity
conflict
```

`capability` means Aura lacks a capability to perform or observe something: no
Jira integration, no browser, no calendar write API, or no CI inspection tool.

`credential` means authentication material is missing or expired.

`permission` means credentials exist but lack the required remote or local
authorization.

`availability` means an external system, local service, dependency, or network
path is unavailable.

`context` means missing facts block progress.

`spec` means missing rules, contract, expected behavior, or definition of done.

`scope` means missing boundaries: how broad the task is, where to stop, or what
autonomy level is intended.

`identity` means Aura cannot resolve whether two people, resources, tickets,
branches, or concerns are the same.

`preference` means reusable user policy is missing.

`authority` means Aura can technically act but should not act without approval.

`verification` means Aura cannot prove or check a claim it needs to rely on.

`confidence` means Aura has an answer but cannot trust it enough for the stakes.

`ambiguity` means multiple interpretations remain plausible even after
available context is used.

`conflict` means instructions, sources, tests, preferences, or flare results
disagree.

Do not add stages such as `planning` or `execution` as gap kinds. Use
`observed_during` for stage:

```text
planning
execution
verification
attention_judgment
handback
```

Do not add `safety`, `privacy`, or `urgency` as gap kinds. Model those as risk,
sensitivity, impact, or policy dimensions.

A good gap event is precise:

```text
I cannot verify the migration because the test DB is unavailable. I can wait,
run static checks, or ask a flare to inspect the deploy path.
```

It is not a generic failure:

```text
Something went wrong.
```

## Manager Loop

The brain is Aura's manager agent. Flares perform object-level work. The brain
supervises planning quality, verification quality, authority, uncertainty, and
user load.

Loop:

```text
objective
-> plan
-> delegate or execute
-> verify
-> assess claims, concern links, stakes, and gaps
-> continue, ask, surface, park, or stop
```

Manager questions:

- Is the flare still pursuing the right goal?
- Does the plan preserve the user's actual objective?
- Can this result be verified with available tools?
- Which claims are proven, assumed, or uncertain?
- Is more execution useful, or is the next step a gap resolution?
- Would asking the user now reduce future cognitive load?
- Does this cross an authority or approval boundary?

## Self-Help And Escalation

Aura should exhaust cheap reversible self-help before asking the user. It should
escalate when the gap requires human judgment, authority, credentials, missing
context, or a reusable preference.

Self-help examples:

- run tests
- inspect logs
- search existing memory
- ask a flare to review
- cross-check sources
- derive a smaller proof packet
- defer until a scheduled digest

Escalation examples:

- missing credentials
- missing tool integration
- ambiguous goal
- irreversible external action
- preference that will recur
- verification path unavailable
- tradeoff involving taste, risk, or values

## First Implementation Slice

A practical first slice can stay narrow while preserving the general model:

1. Convert ingested events into source-neutral observations.
2. Add a small semantic claim extractor for deterministic claims.
3. Add a first-pass concern linker for obvious resource and actor links.
4. Add a deterministic attention-judgment evaluator.
5. Represent missing reusable preferences, capability gaps, and verification
   gaps as gap events.
6. Keep work disposition and authority requirement separate from attention.
7. Surface judgments and gaps through the existing brain/channel actor path.
8. Add behavior tests for observation projection, claim extraction, concern
   linking, judgment, work disposition, authority requirement, and gap emission.

Gmail can be the first source, but the abstraction must also fit Linear,
Calendar, Jira, branch changes, CI, and future integrations.

## Invariants

1. Integrations describe what changed; they do not decide whether the user
   should care.
2. Observations, semantic claims, concern links, stakes estimates, attention
   judgments, work dispositions, authority requirements, and gap events are
   distinct concepts.
3. Every proactive surface has a human-readable reason and correction path.
4. Gap events include what Aura tried, why progress is blocked or unsafe, and
   the recommended next step.
5. Agents should reduce planning and verification burden before the user is
   asked to decide.
6. Aura escalates human judgment only where available evidence and tools cannot
   responsibly settle the question.
7. Attention actions spend or preserve attention. They must not encode work
   execution or authority gates.
