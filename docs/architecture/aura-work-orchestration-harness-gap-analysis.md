# Gap Analysis: Aura Work Orchestration And Harness Engineering

Status: Draft analysis
Date: 2026-05-04
Against: `docs/architecture/aura-work-orchestration-harness-prd.md`

## Scope

This analysis compares the PRD requirements against the current Aura repo and
runtime design. It spans two surfaces:

1. The development workflow for building Aura itself.
2. Aura's own work orchestration capabilities.

The analysis is intentionally source-neutral. Linear, GitHub, Jira, branches,
calendar events, and similar systems are treated as possible evidence feeds or
work sources, not as product-specific centers of gravity.

## Evidence Inspected

Core product and engineering docs:

- `AGENTS.md`
- `README.md`
- `docs/ENGINEERING.md`
- `docs/PRODUCT_PRINCIPLES.md`
- `docs/ROADMAP.md`
- `docs/architecture/cognitive-capacity.md`
- `docs/architecture/aura-work-orchestration-harness-prd.md`
- `docs/decisions/018-flare-architecture.md`
- `docs/ACP.md`
- `docs/man/aura-testing.7`

Runtime surfaces:

- `src/aura/acp/flare_manager.gleam`
- `src/aura/acp/types.gleam`
- `src/aura/acp/transport.gleam`
- `src/aura/acp/monitor.gleam`
- `src/aura/brain.gleam`
- `src/aura/channel_actor.gleam`
- `src/aura/brain_tools.gleam`
- `src/aura/concern.gleam`
- `src/aura/event.gleam`
- `src/aura/cognitive_event.gleam`
- `src/aura/cognitive_context.gleam`
- `src/aura/cognitive_decision.gleam`
- `src/aura/cognitive_worker.gleam`
- `src/aura/cognitive_delivery.gleam`
- `src/aura/db.gleam`
- `src/aura/db_schema.gleam`
- `src/aura/review.gleam`
- `src/aura/scheduler.gleam`
- `src/aura/validator.gleam`
- `src/aura/supervisor.gleam`

Development workflow and verification surfaces:

- `.claude/settings.json`
- `.githooks/pre-commit`
- `.githooks/commit-msg`
- `scripts/deploy.sh`
- `test/features/README.md`
- `test/features/runner.gleam`
- `test/test_harness.gleam`
- `test/aura/*`

## Executive Summary

Aura already has strong foundations for the PRD:

- It has a text-first concern substrate.
- It has persistent flare identity and lifecycle state.
- It routes flare handback back through the brain/channel actor.
- It has source-neutral event ingestion, evidence extraction, cognitive
  decision envelopes, delivery ledgers, labels, replay, and improvement reports.
- It has explicit engineering principles, behavior tests, feature tests, local
  hooks, deploy scripts, and live diagnostic man pages.

The largest gap is the missing work-objective layer. Today, Aura has concerns
and flares, but not a durable object that says:

```text
this objective exists
because of this concern/evidence
with this authority boundary
using these active flares
blocked by these gaps
and finished only when this proof exists
```

Without that layer, Symphony-like orchestration remains mostly prompt-shaped.
The brain can dispatch and monitor flares, but it cannot reliably manage an
objective portfolio, compare proof against requirements, distinguish
speculative exploration from committed work, or expose a trustworthy work
roster.

For building Aura itself, the largest gap is that the repo has strong principles
but only partial mechanical enforcement. `AGENTS.md`, `ENGINEERING.md`, man
pages, hooks, and tests help, but there is no explicit `docs/WORKFLOW.md`, no
proof-packet standard, no tracked current-plan surface, no doc freshness gate
outside local Claude hooks, no CI, and no recurring cleanup process aimed at
the Aura repo itself.

## Status Legend

- **Solid**: implemented with clear docs and tests.
- **Partial**: useful substrate exists, but the PRD behavior is not complete.
- **Missing**: no durable product or engineering surface exists yet.
- **Drift risk**: docs or claims exist, but enforcement or runtime behavior
  does not fully match.

## Requirement Matrix

| PRD Requirement | Current Status | Development Workflow Gap | Aura Runtime Gap |
| --- | --- | --- | --- |
| R1. Concern-centered work units | Partial | No work-objective spec or workflow file. | Concerns exist; flares exist; no durable work objective linking concern, evidence, authority, flare refs, blockers, and proof. |
| R2. Brain-owned management | Partial | Engineering docs say this; no proof/review workflow forces it. | Brain owns tools and handback, but planning quality, proof sufficiency, dependency sequencing, and escalation are not represented as first-class state. |
| R3. Flare workspaces and identity | Partial to solid | No standard for when Aura contributors should use flares or how to review their proof. | Flare identity, status, domain, thread, workspace, session id, and handback exist; no objective/proof linkage or robust restart recovery for stdio handles. |
| R4. Proof packets | Missing to partial | No repo-wide proof-packet standard for Aura changes. | `AcpReport` and `result_text` exist, but proof shape is not required, validated, stored as structured state, or linked to concerns/work. |
| R5. Explicit gap states | Partial | Rejection and deploy docs identify gaps, but no workflow requires gap classification in proof/review. | Cognitive decisions and concern files carry gap text; rejection strings encode strategy/authority gaps; no typed gap lifecycle across work objectives. |
| R6. Agent-legible Aura repo | Partial | `AGENTS.md`, `ENGINEERING.md`, man pages, ADRs, and tests are strong; missing workflow/proof/current-plan surfaces. | Runtime can read docs/man pages, but does not have an Aura-build harness protocol to follow. |
| R7. Mechanical guardrails | Partial | Local hooks and githooks exist; no CI, no default validations, no proof/doc freshness/test-doc-comment gate. | File-write validator exists, but not used as an orchestration quality harness. |
| R8. Continuous cleanup | Partial | Memory/skill review exists; no recurring repo cleanup or doc gardening workflow. | Scheduler can run skills and dreaming; no first-class cleanup flares for work entropy. |
| R9. Source-neutral adapters | Partial | Docs preserve source-neutral framing. | Event and evidence model is generic; adapters are still shallow, work decisions are not bridged into orchestration, and many source types have no native integration. |

## Development Workflow Gap Analysis

### D1. Agent Entrypoint And Repo Knowledge

Current state: partial.

What exists:

- `AGENTS.md` is comprehensive and explicitly points to `docs/ENGINEERING.md`.
- `docs/ENGINEERING.md` captures Unix, OTP, metacognitive principles, invariants,
  test categories, deploy constraints, and the crosscutting checklist.
- `README.md` gives an operator-level overview.
- Man pages expose diagnostics, testing, config, and flares in a way both
  humans and agents can read.
- ADRs capture many accepted architecture decisions.

Gaps:

- `AGENTS.md` is both entrypoint and encyclopedia. It is useful, but not yet a
  compact map into progressively deeper documents.
- There is no dedicated `docs/WORKFLOW.md` that describes the actual
  issue/request-to-spec-to-plan-to-implementation-to-review-to-deploy loop.
- There is no explicit "how to build Aura with agents" guide. Current practice
  is distributed across `AGENTS.md`, `ENGINEERING.md`, hooks, man pages, and
  session memory.
- There is no current-plan surface that says what is active, what was recently
  completed, what is blocked, and what should not be touched.
- `docs/superpowers/` is gitignored, so plans/specs created there are not a
  durable repo knowledge surface unless moved elsewhere. The PRD had to be
  moved to `docs/architecture/` for this reason.

Impact:

- A new agent can obey many instructions, but cannot quickly infer the whole
  development operating model.
- Important process knowledge stays in memory, chat, hooks, and local habits
  instead of versioned project files.

Needed:

- Add `docs/WORKFLOW.md` as the canonical Aura development workflow.
- Add `docs/architecture/README.md` as a map of exploratory notes versus ADRs.
- Add `docs/current-work.md` or an equivalent tracked text surface for active
  plans, blocked work, and recently completed slices.
- Keep `AGENTS.md` as an entrypoint that links to those documents rather than
  expanding indefinitely.

### D2. Planning, Spec, And Implementation Flow

Current state: partial.

What exists:

- `docs/ENGINEERING.md` says architectural workflow changes should be
  brainstormed with the user first.
- ADRs exist for accepted architecture choices.
- Older detailed plans exist under `docs/superpowers/plans/`, but that path is
  ignored and therefore not a durable repo-level record.
- The PRD now exists in `docs/architecture/`.

Gaps:

- There is no canonical PRD/spec template for Aura.
- There is no canonical implementation-plan template for Aura.
- There is no rule for when a PRD becomes an ADR, when it remains exploratory,
  and when it turns into an implementation plan.
- There is no standard decision gate for "this is now approved enough to build."
- There is no durable link between a work objective, its spec, implementation
  plan, tests, deploy, and proof packet.

Impact:

- Large architecture shifts can be documented, but the transition into
  implementation is ad hoc.
- Agents can generate plans, but Aura has no repo-native lifecycle for those
  plans.

Needed:

- Define PRD, design, implementation plan, proof packet, and ADR roles.
- Create templates under a tracked path such as `docs/templates/`.
- Add an index of active and accepted specs.

### D3. Verification Workflow

Current state: partial to solid.

What exists:

- Unit tests are broad under `test/aura/`.
- Feature tests exist under `test/features/`.
- `test/test_harness.gleam` creates realistic fake-backed systems with DB,
  brain, channel supervisor, and flare manager.
- `docs/ENGINEERING.md` gives a strong test taxonomy.
- `docs/man/aura-testing.7` documents behavior, contract, and fault-injection
  tests.
- `.githooks/pre-commit` runs `gleam test`.
- `.githooks/commit-msg` blocks `fix:` commits without staged test files unless
  an explicit override is included.
- `.claude/settings.json` has a local hook that checks edited test files for
  tautologies.

Gaps:

- The pre-commit hook runs `gleam test`, but not `gleam run -m features/runner`.
- `scripts/deploy.sh` builds and restarts, but does not run unit tests or
  feature tests before deploy.
- There is no CI configuration in the repo.
- Fault-injection tests are documented as a category, but the feature
  subdirectory is described as future and is not a populated workflow surface.
- Contract tests are documented but no tracked `test/contract/` surface appears
  in the current tree.
- The tautology hook is Claude-local, not repo-portable or CI-enforced.
- New public function doc-comment enforcement is documented, but no mechanical
  checker was found.

Impact:

- The test culture is strong, but the enforcement surface is inconsistent.
- A non-Claude agent, human shell, or remote CI path can bypass some intended
  quality gates.

Needed:

- Add a repo-native verification command, e.g. `scripts/verify.sh`, that runs
  the intended default verification set.
- Decide whether feature tests are default-on for commits or pre-deploy only.
- Add CI or document why Aura remains local-only without CI.
- Move tautology/doc-comment checks into repo-native scripts if they are
  expected to be universal.

### D4. Deploy Workflow And Runtime Safety

Current state: partial with drift risk.

What exists:

- `scripts/deploy.sh` captures many real deploy gotchas: source sync, npm tool
  bootstrap, clean build, esqlite NIF rebuild, Erlang FFI compilation, man page
  installation, launchd restart, and startup log tail.
- `AGENTS.md` explicitly says to tail `/tmp/aura.log` before deploy to avoid
  interrupting in-flight review, tool, dreaming, or streaming work.

Gaps:

- The deploy script does not itself perform the required pre-deploy log check.
- The deploy script does not run behavior tests or feature tests.
- The final startup check is a shallow `tail -3 /tmp/aura.log | grep -v
  heartbeat`, which may miss degraded startup states.
- There is no rollback workflow doc.
- There is no deploy proof packet that records commit, tests, sync, build,
  restart, startup evidence, and residual warnings.

Impact:

- The documented deploy protocol is better than the script-enforced protocol.
- A deploy can still interrupt work if the operator forgets the pre-tail step.
- A successful deploy claim may not carry enough evidence for later audit.

Needed:

- Promote deploy proof to a mechanical script/report.
- Add pre-deploy in-flight work detection to `scripts/deploy.sh` or a wrapper.
- Add rollback instructions and launchd/env-var change workflow.

### D5. Mechanical Guardrails

Current state: partial.

What exists:

- `src/aura/validator.gleam` can validate TOML, JSONL, required fields, max
  sizes, must-contain rules, and no-pattern rules.
- `supervisor.gleam` loads `~/.config/aura/validations.toml` if present.
- `tools.gleam` uses validation rules for writes.
- `.githooks` enforce tests and fix+test pairing.
- `.claude/settings.json` checks man page freshness before commits and checks
  edited tests for tautologies.

Gaps:

- No default tracked `validations.toml` was found in the repo.
- Validation is aimed at runtime writes, not repo-wide architecture or workflow
  guardrails.
- Doc freshness is a local Claude hook, not a repo-native check.
- No proof-packet shape checker exists.
- No stale concern/work checker exists.
- No prompt-hygiene checker for production prompt leakage was found as a
  reusable script.
- No public-doc-comment checker was found.
- No doc/code ownership map exists to determine which docs must change with a
  given source change.

Impact:

- Aura has a validator engine, but not yet a harness policy pack.
- Many principles remain culturally enforced instead of mechanically enforced.

Needed:

- Add repo-native validation rules and scripts for the highest-risk principles.
- Treat proof packets, prompt hygiene, doc freshness, and public API comments as
  first candidates.

### D6. Proof Packet Standard For Aura Development

Current state: missing.

What exists:

- The product principles mention proof packets.
- Cognitive decision envelopes have `work.proof_required`.
- ACP result handback captures monitor summary, last tool names, and final agent
  text.

Gaps:

- There is no standard proof-packet format for Aura code changes.
- There is no distinction between a DEBUG smoke, behavior-test proof, contract
  proof, deploy proof, and production-flow proof.
- There is no structured final review checklist for "claiming complete."
- There is no parser/checker that verifies proof packets contain required
  fields.

Impact:

- The user still has to judge completion from narrative summaries and terminal
  output rather than a consistent proof artifact.

Needed:

- Define proof packet schema as text first.
- Require proof packets in flare handback and human/agent final messages for
  non-trivial Aura work.

### D7. Continuous Cleanup For The Aura Repo

Current state: partial.

What exists:

- Active memory review and skill review run after conversational work.
- Dreaming consolidates memory.
- The scheduler can run skills on intervals or cron.
- Cognitive replay and improvement reports exist for attention policy.

Gaps:

- No recurring cleanup flare scans the Aura repo for stale docs, weak tests,
  drifted architecture claims, or repeated ad hoc code.
- No quality scoring or entropy report exists for the repo.
- No stale active-plan cleanup exists.
- No route exists from cleanup finding to work objective to flare to PR/proof.

Impact:

- Aura improves memory and attention policy, but not yet its own engineering
  harness as a recurring operational loop.

Needed:

- Add a repo-cleanup skill or scheduled flare once work objectives exist.
- Start read-only: reports first, patches later.

## Aura Orchestration Capability Gap Analysis

### O1. Concern-Centered Work Units

Current state: partial.

What exists:

- `concern.gleam` writes ordinary markdown concern files under the XDG state
  concern directory.
- The concern format includes summary, why it matters, current state, watch
  signals, evidence, authority/preferences, open gaps, and recent notes.
- The `track` tool exposes concern creation/update/pause/close to the model.
- Cognitive context loads concern files and lets decisions cite them.

Gaps:

- A concern is broader than a work objective. It can represent care, watch,
  risk, or state, but it does not model a bounded objective with completion
  criteria.
- There is no work-objective file or table.
- Flares are not linked to concern refs or objective refs.
- Work units do not store source evidence, active flare refs, latest proof,
  blocker list, authority state, or verification requirement as first-class
  fields.
- The flares table stores `result_text`, but `StoredFlare` does not expose it
  through the regular loaded flare record, and it is not structured proof.

Impact:

- Aura can remember what matters and run flares, but cannot reliably manage a
  portfolio of objectives.
- `flare list` is a session roster, not a work roster.

Needed:

- Add a text-first work objective surface that links concern refs, evidence
  refs, flare refs, authority, gaps, and proof requirements.
- Keep it file-first initially; add schema only when replay/usage demands it.

### O2. Brain-Owned Management

Current state: partial.

What exists:

- The brain/channel actor owns the tool loop.
- Flares report back through `HandleHandback`, which creates a system message
  and re-enters the channel actor's LLM loop.
- The system prompt includes active/parked flare roster context.
- Flare destructive actions are guarded; rejection strings explicitly frame
  strategy/authority gaps and tell the model to ask the user.
- Cognitive decision envelopes separate attention, work, authority, delivery,
  gaps, and proposed patches.

Gaps:

- The brain does not have a durable manager state for an objective.
- Planning quality is not represented or checked.
- Verification quality is not represented or checked.
- Dependency sequencing between flares is not represented.
- The brain can see flares, but not objective-level "why this is active" beyond
  the original prompt and domain.
- There is no structured manager decision after handback that compares proof
  against `proof_required`.

Impact:

- Aura behaves like a manager in prompt and architecture, but lacks the durable
  state needed to be a reliable manager across multiple simultaneous objectives.

Needed:

- Route every non-trivial flare through a work objective.
- Require the brain to update objective state after handback: continue, verify,
  ask, defer, close, or mark blocked.

### O3. Flare Identity, Workspace, And Lifecycle

Current state: partial to solid.

What exists:

- `FlareRecord` has stable id, label, status, domain, thread id, original
  prompt, execution JSON, triggers JSON, tools JSON, workspace, session id,
  session name, handle, timestamps, and awaiting response.
- Flare statuses include active, parked, archived, and failed.
- Flares persist to SQLite and recover on boot.
- Parked flares can be rekindled.
- Scheduler supports delay and cron-style flare triggers.
- The `flare` tool supports ignite, status, list, prompt, park, rekindle, kill,
  and archive.
- Guardrails discourage kill+ignite for continuing the same work.

Gaps:

- There is no objective id or concern ref in `FlareRecord`.
- `TaskSpec.acceptance_criteria` exists but ignite passes an empty list.
- Workspace isolation is transport/provider-dependent and only represented as
  cwd plus `worktree` bool; it is not exposed as an auditable workspace record.
- Stdio session handles cannot be recovered after restart.
- Flare liveness/progress is not rolled up into objective-level status.
- There is no standard retry/backoff/replan policy per work objective.
- No distinction exists between speculative exploration and committed work.

Impact:

- Flares are good long-running sessions, but not yet fully managed work units.

Needed:

- Add objective linkage and acceptance/proof requirements at ignition.
- Store workspace and verification expectations in objective state.
- Make "speculative" versus "committed" an objective mode, not a hidden prompt
  convention.

### O4. Proof Packets And Handback

Current state: partial.

What exists:

- `types.AcpReport` includes outcome, files changed, decisions, tests,
  blockers, and anchor.
- `transport.format_result_text` combines monitor summary, last actions, and
  agent response.
- `brain.gleam` persists `result_text` and routes handback to the originating
  channel actor.
- `channel_actor.gleam` treats handback as a system message and continues the
  tool loop.
- Monitor progress summaries include Done, Current, Needs input, Next, Status,
  and Title.

Gaps:

- Proof packets are not required from flares.
- Proof packets are not parsed or validated.
- `AcpReport` is not the actual required handback schema for stdio turn
  completion.
- `result_text` is a free-form string.
- Files touched, commands run, command outcomes, residual risk, and human
  decisions are not consistently captured.
- Proof does not persist to concern history or a work log.
- The brain does not compare proof against `proof_required`.

Impact:

- Aura can hear back from agents, but cannot reliably know whether the work is
  done.
- The user still has to audit unstructured narrative.

Needed:

- Define a required proof packet text shape.
- Add a parser/validator that can fail open into a verification gap.
- Persist proof packets in objective history and conversation history.

### O5. Gap State Lifecycle

Current state: partial.

What exists:

- Product and engineering docs treat gaps as first-class.
- Cognitive decisions include `gaps`.
- Concern files include `Open Gaps`.
- Delivery ledger entries include gaps.
- Rejected file proposals and rejected shell approvals return explicit
  strategy/authority gap language.
- Flare destructive actions require explicit user request and point the model
  back to prompt/continue flows.

Gaps:

- Gaps are mostly strings, not lifecycle records.
- There is no gap id, owner, status, opened_at, resolved_at, or linked work
  objective.
- There is no deduplication or batching for work gaps beyond cognitive delivery
  batching.
- There is no unified gap viewer.
- There is no policy for when a verification gap should dispatch a verification
  flare versus ask the user.

Impact:

- Aura can express gaps, but cannot manage them as durable work state.

Needed:

- Represent gaps as sections in objective/concern text first.
- Add a minimum lifecycle: open, blocked-on-user, delegated, resolved,
  superseded.
- Promote to a table only if text/state replay becomes insufficient.

### O6. Source-Neutral Event And Evidence Handling

Current state: partial to solid.

What exists:

- `AuraEvent` has source, type, subject, time, tags, external id, and raw data.
- `cognitive_event.gleam` projects events into source-neutral observations and
  evidence atoms.
- `cognitive_context.gleam` builds a citable context packet from observation,
  evidence, policy files, user/domain context, concerns, delivery targets, and
  digest windows.
- `cognitive_decision.gleam` validates citations, policy refs, concern refs,
  attention actions, work actions, authority, delivery target, and patch paths.
- Event FTS exists.

Gaps:

- The evidence extractor still carries shallow source heuristics for resource
  type and selected JSON paths. That is acceptable as extraction, but it should
  remain minimal.
- Many possible source adapters are not implemented.
- Event ingestion does not create work objectives.
- Cognitive `work.action` can be `delegate` or `execute`, but no bridge turns
  that into an objective/flare workflow.
- There is no source-specific prompt framing where materially different sources
  require different interpretation surfaces.

Impact:

- Aura has a good source-neutral interpretation harness, but not a work
  orchestration bridge.

Needed:

- Keep adapters as evidence feeds.
- Add a common work-decision executor that can create/update work objectives
  after validation and authority checks.

### O7. Work Roster And User-Facing Visibility

Current state: partial.

What exists:

- `flare(action='list')` shows flare id, label, status, domain, thread, and
  session.
- `flare(action='status')` shows a single flare's status, elapsed time, domain,
  session/run id, and prompt.
- The system prompt includes active and parked flare roster sections.
- Cognitive delivery keeps a ledger of delivered attention outputs.

Gaps:

- There is no user-facing "what is Aura working on?" work roster.
- Flare list lacks objective, concern, blocker, proof status, next decision,
  and authority state.
- Roster state is not grouped by concern or source.
- There is no stale-work detection.
- There is no read-only operator command for active objectives because
  objectives do not exist yet.

Impact:

- Aura can show sessions, not managed work.

Needed:

- First read-only roster should summarize objective title, concern/source,
  active flares, blocker/gap, proof state, and next manager action.

### O8. Authority And Permission Management

Current state: partial.

What exists:

- File write tiers exist.
- Shell approvals exist and rejected commands return explicit authority-gap
  guidance.
- Cognitive decision envelopes include `authority.required` and `authority.reason`.
- Concern files include authority and preferences.
- Delivery decisions validate target consistency.

Gaps:

- Work objectives do not store authority state.
- There is no "authority granted for this objective" record.
- There is no object-level approval history.
- There is no standard authority handoff from cognitive decisions to flares.
- There is no durable distinction between missing credential, missing tool,
  missing permission, missing user judgment, and missing verification in active
  work state.

Impact:

- Authority checks exist locally, but not as portfolio management state.

Needed:

- Add authority state to work objective text.
- Require flare prompts to include authority boundary and proof requirements.

### O9. Scheduling, Triggers, And Continuous Work

Current state: partial.

What exists:

- Scheduler supports interval/cron skills.
- Dreaming runs on cron.
- Parked flares can carry delay or schedule triggers.
- Scheduler can rekindle due flares.

Gaps:

- There is no "every active task has an agent" guarantee.
- There is no objective-to-trigger relation.
- There is no dependency graph or sequencing policy.
- There is no stale objective check.
- There is no cleanup loop for work units that lack active flare, proof, blocker,
  or close reason.

Impact:

- Aura can run periodic tasks and rekindle flares, but not continuously operate
  a work board.

Needed:

- Add objective-level scheduled checks after objective files exist.
- Keep first version simple: stale objective report, not autonomous mutation.

### O10. Speculative Exploration

Current state: missing.

What exists:

- Flares can be ignited for arbitrary prompts.
- The brain can decide whether to continue, ask, or stop after handback.

Gaps:

- No objective mode distinguishes speculation from committed work.
- No discard/promote workflow exists.
- No proof standard exists for "this exploration is promising enough to turn
  into committed work."
- No cost/attention budget is tracked.

Impact:

- Aura can do speculative work only as informal agent tasks.

Needed:

- Add objective mode: `speculative|committed|maintenance`.
- Add promote/discard actions with proof requirements.

### O11. Runtime Observability

Current state: partial to solid.

What exists:

- Progress messages show status, done, current, needs input, and next.
- Domain logs receive progress summaries.
- Delivery ledgers and decisions are JSONL.
- Dead-letter retry exists for cognitive delivery.
- Test harness fakes make many behaviors observable.

Gaps:

- Progress summaries are LLM-generated and not tied to a structured event model
  for proof.
- Discord edit failures are ignored in one branch of progress message editing.
- There is no work-objective ledger.
- There is no end-to-end trace from source event to work objective to flare to
  proof to user-facing outcome.

Impact:

- Debugging individual subsystems is possible; auditing a whole work objective
  is not.

Needed:

- Add objective history entries as ordinary text or JSONL materialization.
- Record source refs, flare refs, proof refs, and user-facing output refs.

## Crosscutting Gaps

### C1. The PRD Itself Is Not Yet Part Of A Lifecycle

The PRD is tracked, but there is no index or workflow telling future agents how
to move it through:

```text
draft PRD -> approved design -> implementation plan -> ADR if needed -> slices -> proof
```

### C2. Work And Attention Are Still Better Modeled Than Work Execution

Aura's cognitive attention stack is more mature than its object-level work
execution stack. Attention decisions have evidence, validation, delivery,
labels, replay, and improvement reports. Work decisions currently stop at
`work.action` and `proof_required`.

The next architectural move should reuse the cognitive stack's discipline:

```text
work objective -> context -> model proposal -> validator -> ledger -> replay
```

but without creating a heavy typed ontology too early.

### C3. The Repo Harness And Runtime Harness Should Converge

The development workflow and Aura's orchestration runtime have the same missing
center: proof-backed work objectives.

For Aura itself:

```text
PRD/spec -> plan -> code/test/docs -> proof packet -> deploy proof
```

For Aura as product:

```text
concern/event/request -> objective -> flares -> proof packet -> user decision
```

These should share vocabulary and text shapes where possible. That reduces the
number of concepts Aura and its builders must maintain.

## Prioritized Gap List

### P0. Define The Text-First Work Objective Surface

Why:

- It unlocks concern-linked work, proof, gaps, roster, and cleanup.
- It is the smallest missing abstraction connecting concerns and flares.

Minimum content:

- Objective
- Mode: speculative, committed, maintenance
- Concern refs
- Source evidence refs
- Authority state
- Verification/proof requirement
- Active flare refs
- Open gaps/blockers
- Latest proof packet
- Recent manager decisions

Recommended storage:

- Start as markdown under `~/.local/state/aura/work/`.
- Link to concern files by source ref.
- Materialize JSONL later only if roster/query needs demand it.

### P0. Define Proof Packet Format

Why:

- Aura cannot safely claim completion without proof.
- The same format supports human agents, flares, deploys, and cleanup reports.

Minimum fields:

- Objective/result summary
- Evidence/resources touched
- Files changed or external resources affected
- Commands/checks run
- Outcome of each check
- What was not verified
- Residual risk
- Human decision required

First guardrail:

- A parser that can tell "valid enough", "missing verification", or "not a
  proof packet."

### P0. Add Aura Development Workflow Doc

Why:

- Harness engineering starts with making the repo legible.
- Future agents need a durable workflow before runtime orchestration work grows.

Content:

- Request intake and scope classification
- PRD/design/ADR/plan roles
- Implementation expectations
- Test expectations
- Proof packet expectations
- Review expectations
- Deploy proof and rollback
- How to handle rejected proposals and authority gaps

### P1. Link Flare Ignition To Objectives

Why:

- Flares without objective linkage are sessions, not managed work.

Minimal change:

- Add optional objective/work ref to flare prompt and persisted flare metadata.
- Populate `TaskSpec.acceptance_criteria` from objective proof requirement.
- Include objective context in active flare thread prompt.

### P1. Build Read-Only Work Roster

Why:

- Management requires visibility before mutation.

Minimal roster:

- Objective
- Mode/status
- Concern/source
- Active flare(s)
- Open gap/blocker
- Proof status
- Next manager action

### P1. Turn Cognitive Work Decisions Into Work Objective Proposals

Why:

- The cognitive loop already decides `work.action` and `proof_required`.
- Today those fields are logged, not operationalized.

Minimal behavior:

- For `work.action=prepare|delegate|execute`, create a reviewable work-objective
  proposal unless authority permits automatic creation.
- Do not dispatch flares automatically until objective and authority semantics
  are clear.

### P1. Make Deploy Proof Mechanical

Why:

- Current deploy docs exceed script enforcement.

Minimal behavior:

- `scripts/verify.sh` for local checks.
- `scripts/deploy.sh` or wrapper checks in-flight log conditions.
- Deploy emits a proof summary: checks, build, FFI compile, restart, startup
  evidence, residual warnings.

### P2. Repo Cleanup And Doc Gardening Flares

Why:

- High-throughput agent work creates entropy.

Start read-only:

- Weekly report of stale docs, ignored active specs, unverified claims,
  untracked plans, weak tests, and code/doc drift.

### P2. Mechanical Guardrail Pack

Candidate checks:

- Proof packet shape check.
- Prompt-hygiene leakage check.
- Public function doc-comment check.
- Architecture-doc freshness check.
- Bug-fix regression-test check beyond commit message.
- Feature-test coverage check for user-facing workflows.

### P2. Gap Lifecycle

Why:

- Current gaps are text, not managed state.

Start text-first:

- Add gap sections to work objective files.
- Add statuses: open, waiting-on-user, delegated, resolved, superseded.
- Only promote to structured tables if roster/replay needs demand it.

## Suggested First Slice

The first slice should be development-workflow-first, then runtime substrate:

1. Add `docs/WORKFLOW.md` with the Aura development workflow and proof packet
   format.
2. Add `docs/templates/proof-packet.md` and `docs/templates/work-objective.md`.
3. Add a text-first work objective format under `~/.local/state/aura/work/`.
4. Teach flare ignition/handback to reference the objective and produce a proof
   packet.
5. Add read-only work roster.

Reasoning:

- The repo harness is immediately useful and low runtime risk.
- The proof packet vocabulary should exist before runtime code enforces it.
- Work objectives are the missing center. Roster and cleanup should wait until
  the objective shape exists.

## Open Decisions To Resolve Before Implementation

1. Should work objectives live in separate `work/*.md` files or as sections
   inside concern files?
2. Should proof packets be markdown-only first, or should they have a small
   parseable header block from day one?
3. Should flare `TaskSpec.acceptance_criteria` become the first bridge from
   objective to agent prompt?
4. What user-facing phrase should request the roster: "what are you working
   on", "show active work", or both?
5. Should objective creation from ambient events require user ratification at
   first, even when authority says work can be prepared?
6. Which guardrails must be repo-native before Aura relies on them for runtime
   agent work?

## Bottom Line

Aura is close in primitives but not yet close in orchestration semantics.

The foundation is there:

- source-neutral evidence
- text-first concerns
- cognitive decisions
- replay
- persistent flares
- handback
- scheduler
- behavior tests
- hooks
- deploy script

The missing center is:

- work objectives
- proof packets
- explicit gap lifecycle
- objective-linked flare management
- read-only work roster
- repo-native workflow and quality guardrails

That is the bridge from "Aura can dispatch agents" to "Aura can manage agentic
work."
