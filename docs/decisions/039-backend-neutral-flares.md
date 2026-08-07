# ADR 039: Backend-Neutral Flares

**Status:** Accepted
**Date:** 2026-08-07
**Refines:** ADR 018 (Flare Architecture for Background Agents)

## Context

ADR 018 defines a flare as a persistent extension of Aura. The current implementation binds flare execution to ACP sessions. This binding works for repository work. It does not support parallel browser workflows, attachment work, integrations, or other work that needs Aura tools.

A user request can contain several independent work items. Each item can require a multistep workflow. One parent tool loop cannot give each item an isolated lifecycle, browser session, recovery path, and proof record.

The product model must stay simple. The user must not choose between worker types or follow internal executor events.

## Decision

### A flare is the worker

Aura has one worker concept: the flare. Aura does not add a separate subagent product concept.

A flare has durable identity, a bounded objective, completion requirements, task-scoped context, task-scoped capabilities, state, and proof.

### The brain is the only manager

The brain is the only component that can create a flare. A flare can report a need for more work. It cannot create another flare.

The brain decomposes requests, selects executors, checks proof, decides completion, and communicates with the user.

### Execution is pluggable

A flare uses an executor for each execution attempt.

The first executors are:

- `acp` for repository, code, worktree, build, and test work.
- `aura` for built-in tools, browser workflows, attachments, integrations, and local non-coding work.

The brain selects the executor automatically. It records the selection and its reason. It does not normally show this detail to the user.

Mixed work uses sibling flares with the correct executor for each objective. It does not use a hybrid executor.

### Sibling work has a dispatch group

Flares from one user request can share a `dispatch_id`. This identifier supports concurrency, result collection, and one aggregate response. It is metadata and not a new worker type.

### Context and capabilities are task-scoped

Each flare gets a context manifest and a capability manifest. The flare does not inherit all Aura context and tools by default.

The executor enforces the manifests. A flare reports a typed gap when it cannot continue inside the boundary. The brain can expand the boundary, redirect the work, or ask the user.

### Identity and attempts are separate

Flare identity is durable. An execution attempt is transient.

The flare manager persists flare records, attempt records, and append-only lifecycle events. Runtime handles remain in actor memory.

The common executor contract is `start`, `resume`, `send_input`, `pause`, `cancel`, and `inspect`.

### The brain owns completion

An executor reports a result and proof. The brain checks the completion requirements. The brain marks the flare as complete only when the requirements are met.

User acceptance is required only when the objective needs human judgment or explicit approval. The user can reopen a completed flare.

This rule changes the ADR 018 implementation rule that completion is always declared by the user. The durable flare model from ADR 018 remains valid.

### Brain decisions pass a deterministic gate

The model makes semantic judgments. Code checks safety and evidence before a judgment produces an effect.

Executor selection and completion are brain decisions. Before either takes effect, a narrow deterministic gate checks executor compatibility, authority, blocking gaps, and proof presence. The gate does not judge work quality. A failed gate records the reason and opens a gap instead of failing the flare.

### External writes use an intent ledger

Each external write records `effect_intended` before the call and `effect_succeeded` or `effect_unknown` after it, in the existing `flare_events` store. No new table is required.

Aura never repeats an external write automatically. After interruption it retries only when absence is verified. Unknown outcomes create a verification or external gap and require a user decision.

### Recovery must prevent duplicate external writes

After a crash, Aura marks the active attempt as interrupted. It reconciles the action log with external state before retry.

Aura resumes automatically only when the next action is safe. Aura does not blindly repeat an external write when the first outcome is unknown. The intent ledger is the mechanism for this rule.

### Active attempts are supervised

The root supervisor owns the flare manager and an execution-attempt supervisor. The attempt supervisor owns active Aura executor processes and their monitors. The existing ACP runtime boundary continues to own ACP processes and monitors.

After a restart, the flare manager reconciles durable attempt state with executor runtime state before it reconnects or starts more work. An attempt failure must not stop the flare manager, the brain, or a sibling attempt.

### Audit data and user attention are separate

Aura records executor selection, lifecycle events, tool outcomes, retries, gaps, controls, and proof. It redacts secrets.

Aura shows an update only when the user must act, the plan changes, an early result is useful, a material failure or delay occurs, or the full request completes. Aura does not send one message for each routine sibling completion.

An immediate update or question must state why it is needed now, which user decision or authority is required, the cost of deferral, and why recording or digesting is insufficient.

## Consequences

### Benefits

- Aura can process independent browser and attachment workflows in parallel.
- Existing ACP repository work remains supported.
- Users have one worker model and do not have to know executor details.
- Each work item has isolated state, context, capabilities, recovery, and proof.
- Full audit data does not create conversation noise.

### Costs

- The flare manager must own more durable state and recovery logic.
- The channel tool loop must become a reusable agent-loop engine.
- Executor selection and manifest policy need behavior tests.
- External writes need reconciliation rules before automatic retry.
- Existing ACP execution data needs a safe attempt-record migration.

### Constraints

- The first delivery slice uses only `acp` and `aura` executors.
- Flares cannot create flares.
- Concern automation and durable work objectives are outside this decision.
- Existing flare identifiers, ACP sessions, workspace data, and readable history must remain valid.

## Alternatives considered

### Keep flares ACP-only

Rejected. This option does not support Aura tool and browser fan-out.

### Add a separate subagent concept

Rejected. This option creates two worker models and leaks execution architecture into the product model.

### Put all work in one parent tool loop

Rejected. This option does not give each work item an isolated lifecycle, capability boundary, recovery path, or proof record.

### Let flares create child flares

Rejected. This option divides orchestration authority and makes concurrency, recovery, and user communication harder to control.

## Related design

See `docs/architecture/2026-08-07-backend-neutral-flares-design.md` for the component model, data model, first delivery slice, and verification requirements.
