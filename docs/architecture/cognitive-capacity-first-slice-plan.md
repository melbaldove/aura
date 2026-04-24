# Cognitive Capacity First Slice Plan

Updated 2026-04-24

Status: planning note. This is not yet an ADR. Use this plan to make the
cognitive-capacity model executable without committing early to user-facing
interruption.

## Goal

Build a true log-only cognitive interpretation layer fed by existing event
ingestion:

```text
AuraEvent
-> Observation
-> EvidenceBundle
-> CognitiveInterpretation
-> Validator
-> compact log
```

The first slice should prove the model against personal work events and
concern-indexed world-state changes while keeping integrations out of policy.
It must not mutate concern state, write real `STATE.md`, update durable memory,
dispatch flares, or send proactive user messages.

## Non-Goals

- No Discord surfacing of proactive judgments yet.
- No multi-turn policy capture yet.
- No Gmail-specific policy logic in the cognitive layer.
- No independent writable `STATE.md`.
- No concern mutation or production generated-state writes.
- No flare dispatch from cognitive interpretations.
- No attempt to monitor all world state. World awareness stays concern-indexed.
- No claim-router matrix or source-specific routing table.

## Design Constraints

1. Deterministic code extracts citable evidence and validates model output.
2. The model performs concern-relative interpretation for every non-trivial
   event.
3. Integrations produce observations and evidence; they do not decide user
   attention.
4. The first slice is pure and testable before it is wired into actors.
5. World-state examples must be included in tests even if Gmail is the first
   live source.
6. `STATE.md` is generated from concerns in the target architecture, but
   production writes wait until typed concern persistence exists and direct
   state writers are migrated.

## Proposed Modules

Keep the first implementation narrow. These are conceptual boundaries; they
can start as one or two modules and split only when the type surface proves
stable.

`src/aura/cognitive_event.gleam`

- Defines `Observation`.
- Projects existing `event.AuraEvent` into a source-neutral observation.
- Starts with Gmail and generic JSON fallback.
- Defines `EvidenceBundle`, `EvidenceAtom`, and resource refs.
- Extracts source-direct atoms from structured fields.
- Extracts generic text atoms such as emails, URLs, ticket keys, simple dates,
  commit SHAs, branch-like tokens, money amounts, percentages, and versions.
- Preserves `source_path` or text span for every atom.

`src/aura/cognitive_interpretation.gleam`

- Defines `CognitiveInterpretation` and nested types:
  `ConcernMatch`, `ProposedConcern`, `SemanticClaim`, `AttentionJudgment`,
  `WorkDisposition`, `AuthorityRequirement`, `GapEvent`, and
  `PreferencePrompt`.
- Defines the model prompt/schema boundary, but the first pure tests can use
  mocked interpretation values.

`src/aura/cognitive_validator.gleam`

- Validates model output.
- Ensures evidence refs exist, concern refs are valid fixture inputs or
  proposed, authority boundaries are obeyed, attention-spending judgments carry
  required justification, and gap events have resolution paths.

Later, after the log-only slice is stable:

- `src/aura/concern.gleam`: typed concern state and update functions.
- `src/aura/state_renderer.gleam`: renders active concerns into generated
  prompt-visible state.
- `src/aura/cognitive_worker.gleam`: async worker that consumes persisted event
  IDs and runs model-backed interpretation outside the ingestion actor.

Production concern mutation requires a DB-backed concern store and migration of
existing direct `STATE.md` writers first.

## Fixtures

Use fixtures that force generality:

- Gmail direct request with deadline.
- Jira ticket assigned to user.
- Linear issue moves to blocked.
- Calendar meeting moved earlier.
- Branch push linked to active release.
- CI failure on active branch.
- Startup launch relevant to a thesis.
- Founder hiring signal.
- Paper published in a learning frontier.
- Regulation change affecting a product concern.
- Missing Jira integration.
- Ambiguous identity: same founder/person appears under two emails or handles.
- Verification gap: claim cannot be checked because source is unavailable.

## Baseline Behavior

The baseline evaluator is the mocked/validated interpretation, not a hand-built
claim router.

Expected fixture interpretations:

- Direct request with deadline: match active concern, emit
  `contains_request` and `deadline_created`, attention `surface_now` or
  `ask_now` if a reusable preference is missing, work `prepare`, authority
  `approval` only for external send.
- CI failure on active branch: match release/branch concern, emit
  `artifact_failed_verification`, work `delegate`, attention `record`,
  `digest_later`, or `surface_now` depending on active concern and defaults.
- Startup launch relevant to thesis: match thesis concern, emit weak
  thesis/traction claims, attention `digest_later`, work `prepare` or
  `delegate` enrichment.
- Missing integration needed for requested work: emit `GapEvent(capability)`
  with user-facing options.
- Ambiguous identity with low stakes: record an identity gap with resolver
  `aura`.
- Ambiguous identity with high stakes: attention `ask_now` with
  `GapEvent(identity)` and concrete options.

## Actor Wiring

`event_ingest` should remain a narrow, fire-and-forget ingestion boundary. It
persists the event and returns; it does not block on model calls, state
rendering, or concern mutation.

After the pure modules pass tests, wire log-only interpretation through a
separate cognitive worker fed by persisted event IDs:

```text
event_ingest persists event
-> enqueue event id
-> cognitive worker reads event
-> normalize observation
-> extract evidence
-> call mocked interpreter first, model interpreter later
-> validate interpretation
-> log compact structured summary
```

Do not send Discord messages, mutate concerns, write `STATE.md`, or dispatch
flares in this slice. Model failure, timeout, invalid output, or missing
capability should produce a validation/gap log entry and no state mutation.

## Tests

Add behavior tests at the lowest useful layer:

- `AuraEvent -> Observation`
- `Observation -> EvidenceBundle`
- evidence atoms include source paths or text spans
- `CognitiveInterpretation` schema construction
- validator accepts valid interpretations
- validator rejects missing evidence refs
- validator rejects unsafe authority requirements
- validator rejects attention-spending judgments that lack why-now,
  user-decision, deferral-cost, or why-not-digest justification
- duplicate event does not produce duplicate interpretation logs
- invalid model output produces no mutation
- interpreter timeout/model failure produces a gap log and does not block
  ingestion
- event ingestion remains non-blocking under cognitive worker backpressure
- restart/replay behavior is deterministic from persisted event IDs
- untrusted event text cannot be treated as instructions
- fixtures across personal work and world-state examples

The tests should fail if a source adapter decides attention, if invalid model
output mutates state, or if the cognitive worker can block ingestion.

## Success Criteria

1. The same interpretation schema handles Gmail, Jira, Linear, Calendar,
   Git/CI, and world-state fixtures.
2. Attention, work, authority, and gaps stay separate fields in one structured
   interpretation.
3. Interpretations cite evidence atoms.
4. Integrations do not decide whether the user should care.
5. Attention-spending judgments explain why now, what user decision is needed,
   the cost of deferral, and why a cheaper digest/record action is insufficient.
6. Log-only output is compact enough to inspect during real Gmail ingestion.
7. The worker cannot block ingestion and invalid interpretation cannot mutate
   state.
8. The implementation reveals whether the model is stable enough for an ADR and
   persistence.

## Minimum Implementation Cut

The minimum slice should be implemented in two tight cuts. The first proves the
data contract. The second makes it run against real ingested events without
blocking ingestion or mutating state.

### Cut 1: Pure Cognitive Core

Files:

- `src/aura/cognitive_event.gleam`
- `src/aura/cognitive_interpretation.gleam`
- `src/aura/cognitive_validator.gleam`
- `test/aura/cognitive_event_test.gleam`
- `test/aura/cognitive_validator_test.gleam`

Scope:

- Define `Observation`, `EvidenceBundle`, `EvidenceAtom`, and source refs.
- Convert existing `event.AuraEvent` into `Observation`.
- Extract citable evidence from subject, tags, source fields, and JSON payload:
  actor email, resource IDs, URLs, simple dates, message/thread IDs, status-like
  fields, and raw text spans.
- Define `CognitiveInterpretation` shape, including attention, work, authority,
  gaps, and preference prompt fields.
- Validate mocked interpretations against evidence refs and attention-spending
  requirements.

Non-scope:

- No DB schema migration.
- No worker actor.
- No LLM call.
- No concern store.
- No `STATE.md` renderer.

Acceptance:

- Fixtures cover Gmail, Linear/Jira-shaped ticket events, Calendar-shaped time
  changes, Git/CI-shaped events, and one world-state watch event.
- Validator rejects missing evidence refs.
- Validator rejects `surface_now` and `ask_now` without why-now,
  user-decision, deferral-cost, and why-not-digest fields.
- Validator turns invalid interpretation into explicit errors, never defaults.

### Cut 2: Async Log-Only Worker

Files:

- `src/aura/cognitive_worker.gleam`
- `src/aura/db.gleam`
- `test/aura/cognitive_worker_test.gleam`
- `test/aura/event_ingest_test.gleam`

Scope:

- Add a DB actor read seam for loading one persisted event by ID.
- Add a cognitive worker message such as `InterpretEventId(id)`.
- Worker loads the event, builds observation and evidence, runs an injected
  interpreter, validates, and logs one compact structured summary.
- Keep the production interpreter conservative until the model prompt exists:
  it may produce record-only or gap-only interpretations, but must not invent
  claims without evidence.
- Add an optional observer/worker subject to event ingestion while preserving
  current `event_ingest.start(db_subject)` behavior for existing callers.
- `event_ingest` sends the worker only after `db.insert_event` returns
  `Ok(True)`, so duplicates do not double-interpret.

Non-scope:

- No production model prompt.
- No proactive Discord message.
- No concern mutation.
- No memory/state write.
- No flare dispatch.

Acceptance:

- `event_ingest` remains fire-and-forget.
- Duplicate events are persisted once and interpreted at most once.
- Worker failure, timeout, invalid interpretation, or missing event is logged and
  does not crash ingestion.
- Real Gmail ingestion can produce `[cognitive]` logs that show event ID,
  evidence count, interpretation status, attention action, work action, gaps,
  and validation errors.

### Explicitly Deferred

- Model-backed interpreter prompt and JSON parsing.
- Typed concern persistence.
- Generated `STATE.md` write path.
- Migration of conversational memory, active review, and dreaming away from
  direct state writes.
- Preference ledger UI.
- Watch coverage runtime.
- Proactive attention surfacing.

## Design Decisions And Open Questions

### 1. Resolved: Concern Persistence And Generated STATE.md

Correct overhaul design: `Concern` is the canonical model of active state.
`STATE.md` is a generated prompt-visible view over active concerns.

Aura should not maintain independent writable prose state in parallel with typed
concern state. Dual sources of truth create drift:

```text
Concern says ticket is blocked.
STATE.md says ticket is unblocked.
Memory says blocker was resolved.
Event log says CI still fails.
```

The canonical split:

```text
Concern store = canonical current active state
Observation/event log = canonical evidence history
CognitiveInterpretation = interpreted facts and manager decisions
STATE.md = generated prompt view
MEMORY.md = durable learned knowledge from settled concerns and repeated patterns
USER.md = durable user profile and preferences
```

Execution boundary: no production concern mutation happens until Aura has a
DB-backed concern store and the existing direct `STATE.md` writers are removed
or redirected. Current direct state writers include conversational memory
updates, active review, and dreaming. Until those are migrated, the first slice
may define concern-shaped fixture inputs and generated-state render tests, but
it must not update real state.

### 2. Preference Learning Before Surfacing

Correct design: do not hard-code user preferences. Aura should ship with
sensible defaults, then learn from the user through gap events, corrections,
examples, and ratified policy. Early in a user's Aura timeline, many observed
`GapEvent(preference)` events are expected. That is not failure; it is the
system discovering where user-specific judgment is required. But many observed
gaps must not mean many interruptions. Aura should interrupt only for preference
gaps that are urgent or reusable enough; otherwise it batches them into a
learning digest.

Preference gaps should help the user think. Aura should explain the situation,
why the preference is reusable, what the options are, what consequences follow,
and what default it recommends if the user does not want to decide now.

Internal decision surface:

- Scope: global, domain, concern, thesis, actor, source, resource type, or
  situation.
- Target: attention action, work disposition, authority requirement, digest
  cadence, escalation threshold, or verification bar.
- Expression: structured fields, natural-language policy, examples, learned
  corrections, or hybrid.
- Temporality: one-off instruction, durable policy, time-bounded policy, or
  concern-lifetime policy.
- Inspection: how the user sees, edits, disables, or explains a learned
  preference.
- Conflict handling: what wins when current instruction, stored preference,
  domain policy, and safety policy disagree.

The user-facing surface is a compact decision packet, not a configuration form:

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

Learned preferences need a lifecycle object:

```text
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

The first slice should emit `GapEvent(preference)` when a reusable preference is
missing, log the specific preference shape Aura wishes it had, and record
whether the gap would interrupt now or be batched for a learning digest.

### 3. Resolved Direction: Model-Backed Cognitive Interpretation

The hard part is matching observations to concerns and interpreting what a
change means for this user. The first slice should not build a claim-routing
matrix.

Deterministic enrichment should extract citable evidence. The model should
produce `CognitiveInterpretation` for every non-trivial event. Flares are used
only when the interpretation requires tool use, multiple sources, external
research, code/log inspection, or verification.

This keeps the architecture maintainable:

```text
deterministic code = evidence, validation, enforcement, rendering
model = concern-relative interpretation
flare = deeper investigation and verification
```

`EvidenceShape` may be introduced later as derived metadata for optimization or
metrics. It is not core to v1.

### 4. General Internet Source Configuration UX

Ideal UX: the user describes what they care about in natural language. Aura
figures out the source strategy, required integrations, polling/search cadence,
evidence extraction, interpretation, and attention behavior.

User-facing examples:

```text
Watch for early signs of local-first AI agent companies.
Track papers that affect our browser-agent thesis.
Tell me when this repo changes license or gets a major release.
Watch for regulation changes that affect healthcare AI workflows.
Track founder hiring signals in this market.
```

Aura should translate that into an internal watch plan:

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

The user should not need to choose between RSS, search, API, webhook, GitHub,
email, browser scraping, or scheduled polling. Aura may disclose gaps when a
capability is missing, but the question should be framed in user terms:

```text
I can monitor this from web search and GitHub releases now. To include LinkedIn
or private CRM data, I need that integration connected.
```

Open design questions:

- What is the smallest `Watch` object that can cover web search, RSS, APIs,
  GitHub, email, documents, and future sources?
- How does Aura explain coverage limits without exposing implementation detail?
- How does the user correct a bad watch in user language: too noisy, not
  relevant, missed important, wrong concern, ask less, digest only, or watch
  until a date?
- How do watches avoid becoming generic news feeds?
- When should Aura ask for a new integration versus proceed with degraded
  coverage?
