# Cognitive Capacity Architecture

Updated 2026-04-24

Status: exploratory architecture note. Promote to an ADR when the first
implementation slice commits to concrete schemas and actor responsibilities.

## Purpose

Aura should preserve and compound the user's cognitive capacity. It does that by
managing the boundary between outside-world changes, agent work, and the user's
attention.

This note translates the product principles in
`docs/PRODUCT_PRINCIPLES.md` into a source-neutral architecture model. Related
research is tracked in `docs/research/cognitive-capacity-literature.md`.

## First Principles

**Attention is finite.** Aura should spend it deliberately, not maximize
responsiveness.

**Events are evidence.** A Gmail message, Jira comment, branch push, CI failure,
calendar update, founder launch, or regulation change is not inherently
important. It is an observation that may support an interpretation about a
concern.

**World state is concern-indexed.** Aura should be ambiently aware of relevant
outside-world change, but relevance is defined by concerns, theses,
relationships, commitments, risks, and opportunities. It should not become an
undifferentiated news monitor.

**Concerns are the center.** Humans do not primarily manage events. They manage
ongoing cares: projects, people, tickets, releases, commitments, trips,
relationships, risks, opportunities, and learning frontiers.

**Concern matching is the hard part.** The core question is not "which rule
matches this event?" It is "what does this change mean relative to what this
user currently cares about?" A model should be involved for every non-trivial
event interpretation.

**Model interprets; code validates.** The model may connect evidence to
concerns, claims, attention, work, authority, and gaps. Deterministic code owns
normalization, evidence extraction, schema validation, authority enforcement,
state rendering, and logging.

**Metacognition is operational.** When Aura cannot responsibly continue, it
should emit a precise gap with attempted self-help and a resolution path.

## Architecture

```text
Source Adapter
-> Observation
-> EvidenceBundle
-> CognitiveInterpreter
-> Validator
-> Concern Store
-> Generated STATE.md
-> Attention Surface / Digest / Work Dispatch
```

The design keeps deterministic code boring and lets the model do the integrated
concern-relative interpretation.

Runtime boundary: source ingestion should persist observations and return. Model
interpretation, validation, concern mutation, generated-state rendering, and
attention decisions belong in a cognitive worker fed by persisted observation
IDs, not inside the ingestion actor.

## Components

### Source Adapter

Each integration normalizes source payloads into observations and preserves raw
provenance. Adapters may extract source-direct evidence, but they do not decide
whether the user should care.

Examples:

- Gmail: messages and threads
- Linear/Jira: issues, assignments, comments, status transitions
- Calendar: meetings, attendees, time/location changes
- Git/CI: branches, commits, PRs, check runs
- World-state watches: companies, founders, papers, repositories, regulations,
  markets, competitors

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
raw_ref
raw_data
```

An observation answers "what changed?" It does not answer what the change means.

### EvidenceBundle

The deterministic, citable fact set extracted from an observation.

Candidate fields:

```text
observation_id
atoms
resource_refs
raw_refs
```

Evidence atoms:

```text
id
kind
value
source_path
text_span
confidence
provenance
```

Examples:

```text
ActorEmail("bob@company.com", source_path="data.from")
ResourceId(ticket, "REL-42", text_span=63..69)
RelativeTimeExpression("tomorrow", text_span=36..44)
MachineResult("failed", source_path="data.conclusion")
Url("https://github.com/org/repo/pull/17", text_span=...)
```

Evidence is not interpretation. It is what the model and validator can cite.

`EvidenceShape` may exist later as derived metadata for optimization or
metrics, but it is not a core v1 abstraction. The stronger invariant is that
every model interpretation cites `EvidenceAtom`s.

### Concern

A durable unit of user care or work. Concerns may represent personal work,
relationships, world-state objects, or evaluative theses.

Candidate fields:

```text
id
label
kind
summary
actors
resources
theses
status
active_claims
open_gaps
attention_history
work_state
authority_state
watches
```

Candidate concern kinds:

```text
person
project
ticket
branch
release
commitment
company
founder
market
thesis
repository
paper
regulation
relationship
risk
opportunity
learning_frontier
```

Concerns are the canonical active-state model. If Aura needs a prompt-visible
current-state file, that file is generated from active concerns. Prose state is
a view; concerns are the source of truth.

### CognitiveInterpreter

The model-backed interpreter receives:

```text
Observation
EvidenceBundle
active concerns
relevant preferences/defaults
recent generated state when useful
source/watch metadata
```

It returns one structured `CognitiveInterpretation`:

```text
observation_id
concern_matches
proposed_concerns
semantic_claims
attention_judgment
work_disposition
authority_requirement
gap_events
explanation
confidence
```

This is the core simplification. Aura does not maintain a hand-built routing
matrix from source to claim to model. The interpreter answers the integrated
question: what does this observation mean relative to the user's concerns?

### CognitiveInterpretation

`concern_matches` link the observation to existing concerns:

```text
concern_id
relation
confidence
evidence_refs
explanation
```

`proposed_concerns` allow Aura to identify new concerns:

```text
label
kind
reason
evidence_refs
lineage_ref
activation_status
```

World-state observations may suggest concerns, but they should not activate a
new durable concern merely because something seems interesting. Activation
requires lineage to an existing concern, thesis, watch, explicit user request,
or later user ratification.

`semantic_claims` are falsifiable statements supported by evidence:

```text
kind
subject
object
confidence
evidence_refs
explanation
verification_status
```

Initial claim kinds should stay small and useful:

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

`attention_judgment` spends or preserves user attention:

```text
action
reason
confidence
trigger_or_schedule
user_decision_required
deferral_cost
why_not_digest
review_condition
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

`work_disposition` decides what work should happen:

```text
action
target
reason
proof_required
expected_result
```

Initial work actions:

```text
none
prepare
delegate
execute
```

`authority_requirement` decides what must be approved, connected, or clarified:

```text
requirement
reason
resolver
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

`gap_events` are metacognitive events:

```text
kind
scope
observed_during
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

Raw gaps are not user prompts. A renderer turns high-value gaps into decision
packets only when they are urgent or reusable enough to spend attention:

```text
situation
evidence
reusable_question
recommended_default
consequences
answer_shortcuts
use_default_for_now
make_durable
not_now
show_evidence
```

Many gaps may be observed; few should interrupt. Low-urgency preference gaps
belong in a batched learning digest with a shared `batch_key`, reuse score, and
defer-to-digest behavior.

Initial gap kinds:

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

### LearnedPreference

User-specific policy learned from gap resolutions, corrections, examples, and
explicit ratification.

Candidate fields:

```text
id
scope
rule
examples_that_created_it
last_used_explanation
precedence
confidence
expiry_or_review
status
disable_edit_revert_path
```

Learned preferences are automation debt unless they are inspectable,
correctable, reversible, and scoped. A preference that cannot explain its
provenance should not silently govern attention.

### Validator

The validator enforces what the model may only suggest.

Checks:

- schema is valid
- cited evidence refs point to real `EvidenceAtom`s
- concern IDs exist or are marked as proposed
- claims cite evidence
- evidence is fresh enough for the claim being made
- claims do not contradict active claims without emitting a conflict gap or
  supersession explanation
- unverified claims do not mutate verified concern state
- authority gates obey policy
- attention actions are allowed and cite the claim or gap that justifies them
- `surface_now` and `ask_now` include why now, what user decision is required,
  the cost of deferral, and why record/digest is insufficient
- gap events have resolver, options, and recommended next step
- confidence and explanation are present

Invalid output becomes a validation gap or retry, not silent state mutation.

### Concern Updater

Applies validated interpretations:

- update existing concerns
- create proposed concerns when allowed
- attach claims
- record gaps
- append attention/work/authority history
- close or supersede stale claims

This component requires a durable concern store. Until that store exists and
direct prose-state writers are migrated, validated interpretations can be logged
or tested against fixtures but must not mutate production state.

### Generated STATE.md Renderer

Renders active concerns into prompt-visible current state:

```text
Concern store -> STATE.md
```

Example generated entry:

```text
§ concern:release-2026-04
Status: blocked
Resources: branch release/x, Jira REL-42, Gmail thread 77
Active claims: contains_request, deadline_created
Open gaps: preference gap resolved
Next: prepare release-notes update; require approval before sending
```

`STATE.md` is not independent writable state.

### Attention Surface

Consumes `AttentionJudgment`:

```text
suppress
record
digest_later
surface_now
ask_now
defer_until_condition
```

The first implementation should stay log-only. User-facing surfacing comes
after the interpretation and validation loop proves itself.

### Work Dispatch

Consumes `WorkDisposition`:

```text
none
prepare
delegate flare
execute
```

Flares are for deeper investigation, tool use, verification, or synthesis. Not
every event gets a flare.

### Authority Gate

Consumes `AuthorityRequirement` and prevents unsafe action. The model can
recommend action; code enforces approval, credential, permission, capability,
context, and human-judgment boundaries.

### Watch Coverage Contract

For concern-indexed world state, the user describes what they care about:

```text
Watch early local-first AI agent companies.
Track papers that affect our browser-agent thesis.
Tell me when this repo changes license or gets a major release.
```

Aura translates that into a watch plan:

```text
concern_or_thesis_id
candidate_sources
query_or_watch_strategy
cadence
evidence_targets
relevance_test
coverage_limits
expiry_or_review_cadence
noise_budget
stop_condition
interruption_policy
capability_gaps
```

The user should not need to choose between RSS, search, API, webhook, browser
scraping, or polling.

A watch is not a news feed. It is a coverage contract: what Aura is watching,
why it matters, what sources it can and cannot cover, when it will interrupt,
when it will only digest, when it expires or needs review, and how the user can
correct it in plain language.

## Invariants

1. Integrations describe what changed; they do not decide whether the user
   should care.
2. Evidence atoms are citable; interpretations must cite evidence.
3. The model interprets; deterministic code validates and enforces.
4. Concerns are canonical active state; `STATE.md` is generated.
5. Attention, work, authority, and gaps remain separate fields in one
   interpretation object.
6. Preferences are learned through gaps, corrections, examples, and ratified
   policy; they are not hard-coded per source.
7. Many gaps may be observed, but only urgent or reusable gaps should interrupt;
   the rest are batched into learning digests.
8. Gap events include what Aura tried, why progress is blocked or unsafe, and
   the recommended next step.
9. Ambient world awareness is concern-indexed. Aura watches the world through
   concerns and theses, not through an unbounded feed of interesting facts.
10. World-state observations may not activate durable concerns without existing
    concern, thesis, watch, or explicit user lineage.
11. Attention-spending actions explain why now, what decision is required, what
    deferral costs, and why cheaper handling is insufficient.
12. Learned preferences carry scope, provenance, precedence, confidence,
    review/expiry, and an edit/disable/revert path.
