# Backend-Neutral Flare Design

**Date:** 2026-08-07
**Status:** Approved design
**Decision:** ADR 039

## Purpose

Aura must process independent work items in parallel. Each item can require a multistep browser workflow. Repository work must continue to use ACP when ACP is the correct executor.

This design makes a flare the one worker concept in Aura. It separates the durable worker from the process that executes one attempt.

## Product model

A **flare** is a durable worker that Aura creates for one bounded objective. A flare has its own identity, context, capability boundary, state, and proof.

The user communicates with Aura. The user does not have to select an executor or communicate with an executor process.

The brain is the only manager. It creates flares, selects executors, checks results, and reports to the user. A flare can report that it needs more work. A flare cannot create another flare.

Aura does not add a separate subagent product concept. In this model, workers are flares.

## User experience

Aura records detailed execution data. It shows only information that needs user attention.

Aura shows an update when one of these conditions is true:

- The user must act or give authority.
- The plan changes in a material way.
- An early result is useful before the other work completes.
- A failure or delay changes the expected outcome.
- The full request is complete.

Aura does not send a message for each routine sibling completion. The brain collects sibling results and gives one useful response. This rule prevents execution structure from becoming user interface noise.

The user can inspect, pause, cancel, resume, or reopen a flare through Aura. Executor details remain in the audit record unless they help the user make a decision.

## Orchestration model

The brain converts the user request into one or more bounded objectives. It creates one flare for each independent objective.

Sibling flares from the same request have one internal `dispatch_id`. The identifier supports collection, concurrency control, and result aggregation. It is metadata. It is not a new worker type.

For each flare, the brain does these actions:

1. Define the objective and completion requirements.
2. Define the context manifest and capability manifest.
3. Select an executor.
4. Ask the flare manager to start the flare.
5. Review progress, gaps, results, and proof.
6. Decide if the completion requirements are met.
7. Complete, redirect, retry, or ask the user.

Mixed requests use sibling flares. Aura does not put incompatible execution needs into one hybrid executor.

## Executor selection

A flare has one executor for each execution attempt.

The first executor types are:

- `acp`: Use for repository work. This includes code changes, worktrees, builds, tests, and other work that needs an ACP coding session.
- `aura`: Use for Aura tools. This includes browser workflows, attachments, integrations, and local non-coding work.

The brain selects the executor automatically from the objective and required capabilities. Aura logs the selection and its reason. Aura does not normally show the selection to the user.

An executor implements this common contract:

- `start`
- `resume`
- `send_input`
- `pause`
- `cancel`
- `inspect`

The first implementations are `acp_executor` and `aura_executor`.

## Context and capability boundaries

Each flare gets task-scoped context. It does not get all parent context by default.

The context manifest contains:

- The objective.
- The completion requirements.
- The relevant part of the user request.
- The required artifacts.
- The required domain context.
- The applicable skill instructions.
- The constraints and available evidence.

The capability manifest contains:

- The allowed tools and resources.
- The allowed browser session.
- The authority boundary.
- The concurrency and time limits.

The executor enforces the manifest. A flare reports a gap when it cannot continue inside the boundary. The brain can expand the boundary, redirect the work, or ask the user.

Gap types are:

- `context`
- `tool`
- `credential`
- `permission`
- `verification`
- `authority`
- `confidence`
- `strategy`
- `preference`
- `external`

## Shared agent loop

The Aura executor must not copy the channel tool loop.

The implementation will extract a reusable agent-loop engine from `channel_actor`. The engine owns model and tool sequencing, iteration limits, capability checks, context limits, retries, and structured progress.

`channel_actor` adds conversation and Discord behavior. `aura_executor` adds flare lifecycle events, scoped manifests, checkpoints, and proof.

This boundary keeps one tool-loop implementation and two consumers.

## State model

A flare uses this work state model:

```text
queued -> running -> waiting | paused | interrupted
                    waiting | paused | interrupted -> running
                    running -> completed | failed | cancelled
```

`archived` controls roster visibility. It is not a work state.

An execution attempt can fail without failing the flare. The brain can start a new attempt when the objective can still be completed safely.

The brain owns completion. A worker returns a result and proof. The brain checks the completion requirements and marks the flare as `completed` only when the requirements are met.

User acceptance is a completion requirement only when the objective needs human judgment or explicit approval. The user can reopen completed work.

## Persistence model

Flare identity is durable. An execution attempt is transient.

The `flares` record contains:

- `id`
- `dispatch_id`
- `thread_id`
- `domain`
- `objective`
- `completion_requirements`
- `executor_kind`
- `capability_manifest`
- `context_manifest`
- `authority_boundary`
- `state`
- `active_attempt_id`
- `final_result`
- `final_proof`
- `archived`
- creation and update timestamps

The `flare_attempts` record contains:

- `id`
- `flare_id`
- `executor_kind`
- `status`
- `runtime_reference`
- `checkpoint`
- start and end timestamps
- failure data

The `flare_events` record is append-only. It contains:

- `id`
- `flare_id`
- `attempt_id`
- `sequence`
- `event_type`
- `payload`
- timestamp

Runtime handles stay in actor memory. Durable records contain references that support inspection and recovery.

## Ownership

The `flare_manager` owns flare records, states, dispatch groups, attempts, concurrency, control operations, recovery, and lifecycle events.

The brain owns decomposition, executor selection, manifest policy, completion checks, and user communication.

Executors own the mechanics of one execution attempt. They do not own product policy or final completion.

## Deterministic validation

The model makes semantic judgments. Code checks safety and evidence before a judgment produces an effect.

Executor selection and completion are brain decisions. Each decision passes a narrow deterministic gate before it takes effect:

- Executor compatibility: the selected executor supports every capability the objective requires.
- Authority: the action stays inside the flare's authority boundary.
- Blocking gaps: no open gap prevents the transition.
- Proof presence: the referenced evidence exists and matches the completion requirements.

The gate does not judge whether the work is good. Quality remains model judgment. The gate stops the decision when a required condition is false.

A failed gate does not fail the flare. It records the reason, opens a gap, and returns the decision to the brain with a deterministic explanation.

## Supervision

The root supervisor owns the flare manager and an execution-attempt supervisor.

The execution-attempt supervisor owns each active Aura executor process and its monitor. An ACP attempt remains under the existing ACP runtime and monitor boundary. The flare manager owns durable attempt state. It does not own an unsupervised worker process.

A process crash does not directly create a new attempt. After restart, the flare manager first reconciles durable attempt state with the executor runtime. It then reconnects, marks the attempt as interrupted, or records a gap.

One failed attempt must not stop the flare manager, the brain, or a sibling attempt.

## Recovery and safe retry

Aura persists the flare identity, objective, executor choice, manifests, transcript, action log, and checkpoint.

After a process crash, Aura marks the active attempt as `interrupted`. It then reconciles recorded actions with external state.

External effects use an intent ledger in the existing `flare_events` store. There is no new table.

For each external write, such as a message, submission, upload, or payment:

1. Before the call, record `effect_intended` with a stable operation ID.
2. Execute the write once.
3. After the call, record `effect_succeeded` with the receipt, or `effect_unknown` when the outcome is not known.

Aura never repeats an external write automatically. After interruption, it uses the ledger:

- Success recorded: do not repeat. Report the recorded outcome.
- Absence verified: the write did not take effect, so retry is safe.
- Unknown: create a `verification` or `external` gap. Do not retry automatically. Ask the user when only the user can resolve the uncertainty.

## Audit and attention

Aura uses two output planes.

The audit plane records:

- Executor selection and reason.
- State transitions.
- Tool calls and outcomes.
- Checkpoints and retries.
- Capability and context changes.
- Gaps and their resolution.
- Completion checks and proof.
- Pause, resume, cancel, reopen, and archive actions.

The audit plane redacts secrets.

The attention plane contains only information that the user needs. This separation gives complete observability without making the conversation follow internal execution events.

An immediate update or question must explain:

- Why the user needs the information now.
- Which user decision or authority is required.
- What happens if Aura defers the update.
- Why recording or digesting the information is insufficient.

If Aura cannot provide these explanations, it records or digests the event instead of interrupting the user.

## Existing ACP flare migration

Existing ACP flares remain valid.

The migration preserves flare identifiers, session references, workspace data, and readable history. Existing execution data becomes attempt data. ACP remains the executor for existing repository work.

ADR 039 refines ADR 018. It does not replace the core ADR 018 model that a flare is a persistent extension of Aura.

## First delivery slice

The first slice is a source-neutral multi-item browser workflow.

The user supplies multiple files or items. Aura creates one Aura flare for each independent item. The sibling flares share one `dispatch_id`. Each flare gets an isolated browser session. The flare manager applies a concurrency limit. The brain collects the results and sends one useful response.

The slice includes:

- Automatic executor selection.
- Task-scoped context and capability manifests.
- Sibling fan-out and result aggregation.
- Isolated browser sessions.
- Audit events and attention rules.
- Gap reporting.
- Interruption recovery and safe retry checks.
- Compatibility with existing ACP flares.

The slice does not include:

- Concern lifecycle changes.
- Durable work-objective infrastructure.
- Nested flare creation.
- More executor types.
- Automatic policy learning.
- A new user interface.

## Verification

Behavior tests must cover:

- Executor selection.
- Manifest construction and enforcement.
- Fan-out, grouping, concurrency, and event order.
- Gap creation and resolution.
- Brain-owned completion.
- Partial sibling failure.
- Pause, cancel, resume, and reopen controls.
- Existing ACP flare compatibility.

Fault-injection tests must cover:

- A crash during a browser action.
- An executor crash.
- A lost tool result.
- An external action with an unknown outcome.
- A retry that can cause a duplicate write.
- A database failure.
- A stalled sibling flare.

Optional contract tests must check live ACP execution, live Aura browser execution, browser-session isolation, handback, and resume.

The slice is complete when all behavior tests pass, existing ACP tests pass, and a live multi-item browser run proves these results:

- Independent items run as independent flares.
- Each flare can be inspected.
- Aura returns one aggregate result.
- A forced interruption does not cause a duplicate external write.

## Deferred questions

This design does not define concern automation or a durable work-objective layer. Those subjects need a separate design after this slice gives real execution evidence.
