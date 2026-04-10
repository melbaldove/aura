# Flare Architecture

## Problem

ACP sessions are fire-and-forget. The brain dispatches work, the monitor shows progress, the session completes, and the results are trapped. The user never gets an answer to their original question. The brain doesn't read what the agent produced, doesn't summarize findings, and doesn't continue the conversation.

Beyond this immediate gap, ACP sessions have no persistent identity. Each dispatch is ephemeral — there's no way to resume a previous session, no way to schedule follow-ups, no way for the brain to reason about "what am I currently working on." The brain has no working memory of its delegated work.

## Vision

Aura is one mind. When it needs to act in the world — write code, research a topic, manage an email thread — it extends itself through **flares**. A flare is not a separate agent. It's Aura reaching out.

A flare has persistent identity and context. It can be ignited, run, parked, rekindled days later, and archived. The brain maintains a roster of its flares and reasons about them naturally: "I already have a flare investigating the exclusion feature — let me check its progress rather than starting over."

The brain is the sole orchestrator. Flares do work and report back. The brain absorbs results into the conversation and decides what's worth persisting to shared memory. One mind, many hands.

### Inspiration

The OpenPoke architecture (shloked.com/writing/openpoke) implements a similar pattern:
- An Interaction Agent (conductor) manages persistent Execution Agents
- Agents maintain full conversation history across activations
- Results are evaluated before surfacing to the user
- A roster tracks all agents for discovery and reuse

Aura adapts this with a key distinction: flares are not independent agents with their own goals. They are extensions of Aura — the brain's hands, not its colleagues.

## Data Model

### FlareStatus

```gleam
pub type FlareStatus {
  Active
  Parked
  Archived
  Failed(reason: String)
}
```

- **Active** — a process is running, doing work
- **Parked** — waiting for a trigger (schedule, delay, event, or manual)
- **Archived** — done for now, no triggers, but can be rekindled anytime
- **Failed** — something went wrong; can still be rekindled (retry)

There is no terminal state. Everything can be rekindled.

### FlareRecord

```gleam
pub type FlareRecord {
  FlareRecord(
    id: String,
    label: String,
    status: FlareStatus,
    domain: String,
    thread_id: String,
    original_prompt: String,
    execution: FlareExecution,
    triggers: List(FlareTrigger),
    tools: List(String),
    workspace: Option(String),
    session_id: Option(String),
    execution_ref: Option(ExecutionRef),
    created_at_ms: Int,
    updated_at_ms: Int,
  )
}
```

- `id` — stable UUID, survives across executions
- `label` — human-readable, brain-generated ("Alice email negotiation")
- `session_id` — Claude Code session ID for `--resume`; set after first execution
- `thread_id` — Discord channel/thread for notifications and handback
- `execution_ref` — runtime handle to the current execution (in-memory only, not persisted)

### FlareExecution

```gleam
pub type FlareExecution {
  Acp(transport: Transport, provider: AcpProvider, cwd: String, worktree: Bool)
  AuraInstance(domain: String, system_prompt: String)
}
```

The execution strategy is set at ignition time. The flare manager stores it but doesn't interpret it — the brain decides how to execute.

`AuraInstance` is a future execution type where a flare runs as a full Aura instance with its own system prompt, domain knowledge, and tools. Not implemented in the initial phases.

### FlareTrigger

```gleam
pub type FlareTrigger {
  Schedule(cron: String)
  Delay(rekindle_at_ms: Int)
  Event(pattern: String)
  Manual
}
```

- **Schedule** — cron expression, recurring ("0 9 * * 1" = every Monday 9am)
- **Delay** — one-shot, absolute timestamp
- **Event** — pattern matching on incoming events (deferred, not implemented initially)
- **Manual** — no auto-trigger; only user or brain initiated

Multiple triggers per flare allowed.

### ExecutionRef

```gleam
pub type ExecutionRef {
  AcpSession(session_name: String, handle: SessionHandle)
}
```

Runtime-only. Not persisted. Cleared when a flare is parked or archived.

### FlareProgress

```gleam
pub type FlareProgress {
  FlareProgress(
    title: String,
    status: String,
    summary: String,
    is_idle: Bool,
    updated_at_ms: Int,
  )
}
```

Live progress from the monitor. Held in memory by the flare manager for active flares only.

## Flare Manager Actor

An OTP actor in the supervision tree. Owns the roster and persistence. Does not know how to execute flares — the brain makes execution decisions.

### Responsibilities

- CRUD operations on flare records
- Persist flare state to SQLite
- Hold live progress for active flares
- Load non-archived flares into memory on startup
- Recovery: check liveness of active flares on restart

### Messages

```gleam
pub type FlareMsg {
  Ignite(reply_to, label, domain, thread_id, prompt, execution, triggers, tools, workspace)
  Park(reply_to, flare_id, triggers: List(FlareTrigger))
  Rekindle(reply_to, flare_id, input: String)
  Archive(reply_to, flare_id)
  UpdateExecution(flare_id, execution_ref: Option(ExecutionRef), session_id: Option(String))
  UpdateStatus(flare_id, status: FlareStatus)
  UpdateProgress(flare_id, progress: FlareProgress)
  Get(reply_to, flare_id)
  GetByLabel(reply_to, label: String)
  GetProgress(reply_to, flare_id)
  List(reply_to)
  ListByDomain(reply_to, domain: String)
  ListByStatus(reply_to, status: FlareStatus)
}
```

### Concurrency

The flare manager enforces a `max_concurrent` limit on active flares. If the limit is reached, `Rekindle` returns an error. The brain decides whether to queue, park another flare, or inform the user.

Guard against concurrent rekindles of the same flare: if a flare is already Active, Rekindle is rejected.

### State

```gleam
pub type FlareManagerState {
  FlareManagerState(
    flares: Dict(String, FlareRecord),
    progress: Dict(String, FlareProgress),
    max_concurrent: Int,
    db: Subject(DbMessage),
  )
}
```

## Lifecycle

```
Ignite → Active → Park → (trigger) → Rekindle → Active → ... → Archive
                → Archive (short-lived, single session)
                → Failed → (rekindle) → Active
```

### Ignition

1. Brain decides to ignite a flare (LLM judgment call via `flare` tool)
2. Flare manager creates the record — UUID, label, status: Active
3. Brain starts execution — picks strategy from `FlareExecution`, gets back an `ExecutionRef`
4. Brain tells flare manager: `UpdateExecution(flare_id, ref, session_id)`

### Active

A process is running. The monitor tracks progress, pushes updates via the existing `on_event` callback. Progress routes through the flare manager (`UpdateProgress`). The brain queries `GetProgress` for live status.

### Reporting Back (Handback)

When execution produces a result (`end_turn` for stdio, `run.completed` for HTTP):

1. Event loop captures the result payload:
   - Monitor's cumulative summary (from `last_summary`)
   - Last N tool call names (buffered in event loop)
   - Agent's final message text (buffered in event loop)
2. Completion event carries the result payload to the brain
3. Brain loads the thread conversation for this flare
4. Brain appends a system message with the flare's findings
5. Brain re-enters the tool loop — LLM sees original question + flare results
6. Brain responds to the user naturally
7. Brain decides next action: park, archive, or keep active for follow-up

### System message format

```
[Flare reported back: "Investigate exclusion feature"]

Summary: Read 8 exclusion files, grepped isExcluded (not in pipeline), checked Rust (none)

Last actions: Read step-function/src/lib/exclusion.ts, Write exclusion-analysis.md

Agent's response:
The exclusion feature is fully implemented for CRUD and approval but isExcluded()
is NOT called from the transaction pipeline. The feature is built but not enforced...
```

### Parking

The brain decides to park a flare. Reasons:
- Execution finished its turn and there's nothing more to do right now
- The flare registered a trigger ("check back in 2 hours")
- The user said "park that"

The process exits. The flare manager:
1. Sets status to Parked
2. Clears the ExecutionRef
3. Stores the Claude Code session ID (for future `--resume`)
4. Registers triggers with the scheduler (if schedule/delay type)

Conversation history lives in Claude Code's own persistence.

### Rekindling

A trigger fires (scheduler tick, user message, future event). The brain:
1. Asks flare manager for the flare record
2. Starts a new execution with `--resume <session-id>` + new input
3. Updates the flare manager with new ExecutionRef and Active status
4. Monitor attaches, progress flows again

The flare picks up where it left off with full conversation context.

### Archiving

Brain or user decides the flare is done. Flare manager sets status to Archived. Record stays in SQLite for history. Not held in memory. Can be rekindled at any time — archiving is putting the notebook on a shelf, not burning it.

### Failure

Execution dies unexpectedly (process crash, timeout, refusal). Flare manager sets status to Failed(reason). Brain posts error to Discord. The flare can be rekindled to retry.

For recovery on Aura restart: active flares whose processes are dead are marked **Parked** (not Failed), since the work was interrupted, not inherently broken. They can be rekindled when needed.

## Brain Integration

### Roster Awareness

The brain's system prompt includes a roster summary:

```
Active flares:
- "Investigate exclusion feature" (work) — Working, 12m elapsed
- "Fix auth bug #1234" (work) — Idle, 3m elapsed

Parked flares:
- "Alice email negotiation" (personal) — parked, rekindled by schedule Mon 9am
```

This lets the LLM reason about existing flares before igniting new ones. Capped at a reasonable size — if there are many parked/archived flares, only show active + recently parked.

### Dispatch Decision

When the user asks for work, the brain decides (LLM judgment):
1. **Existing flare?** Check roster. If a relevant flare exists, rekindle it.
2. **No flare needed?** Quick questions are handled inline by the brain.
3. **Ignite new flare.** For substantive work that benefits from persistence or parallel execution.

### Tool Interface

Single `flare` tool replaces `acp_dispatch`, `acp_prompt`, `acp_status`, `acp_list`, `acp_kill`:

```
flare(action, ...)

Actions:
  ignite(label, prompt, domain, execution, triggers, tools, workspace)
  rekindle(flare_id, input)
  park(flare_id, triggers)
  archive(flare_id)
  status(flare_id)
  list()
```

### Memory

Brain is the sole writer to shared memory (STATE.md, MEMORY.md, USER.md). Flares do not write to memory directly. When a flare reports back, the brain's existing active memory review system decides what's worth persisting — same as for any other information the brain encounters.

## Triggers

### Time-based (implemented first)

**Schedule triggers** register with Aura's existing scheduler. On each scheduler tick, check for due flare triggers. When one fires, the scheduler tells the brain, the brain rekindles the flare with trigger context as input.

**Delay triggers** are one-shot. The scheduler checks `rekindle_at_ms` against current time. Once fired, the trigger is consumed.

### Manual (implemented first)

User says "check on the Alice flare" or asks a related question. Brain checks roster, finds the flare, rekindles it. No scheduler integration needed.

### Event-based (deferred)

Future integrations (email webhooks, GitHub events, etc.) will match incoming events against flare trigger patterns. The event router rekindles the matching flare. Not implemented until the integration infrastructure exists.

## Persistence

### SQLite Schema

```sql
CREATE TABLE IF NOT EXISTS flares (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  status TEXT NOT NULL,
  domain TEXT NOT NULL,
  thread_id TEXT NOT NULL,
  original_prompt TEXT NOT NULL,
  execution TEXT NOT NULL,
  triggers TEXT NOT NULL,
  tools TEXT NOT NULL,
  workspace TEXT,
  session_id TEXT,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_flares_status ON flares(status);
CREATE INDEX IF NOT EXISTS idx_flares_domain ON flares(domain);
```

`execution` and `triggers` are JSON-serialized. `status` is a string enum ("active", "parked", "archived", "failed:reason").

### Conversation Storage

For handback results that the brain receives, stored in the existing `conversations` table:
- `platform: "flare"`
- `platform_id: <flare_id>`

This is the brain's record of what the flare reported — not the agent's internal conversation history (which Claude Code owns via `--resume`).

### Recovery

On Aura startup:
1. Load all non-archived flares from SQLite
2. Active flares: check liveness via transport. Dead → mark Parked
3. Parked flares with schedule/delay triggers: re-register with scheduler
4. Archived/failed: stay in DB, not in memory

## Supervision Tree

```
supervisor (OneForOne)
├── db              SQLite actor
├── poller          Discord gateway
├── flare_manager   Flare lifecycle, roster, persistence
├── brain           Orchestrator, tool loop, streaming
├── scheduler       Cron + interval + flare triggers
```

The flare manager wraps the existing transport layer. Transport (stdio, HTTP, tmux), monitor (push-based, tmux polling), and Erlang FFI are unchanged.

## Failure Modes

| Failure | Behavior |
|---|---|
| Execution process dies unexpectedly | Flare → Failed(reason). Brain posts error to Discord. Rekindlable. |
| `--resume` fails (stale session ID) | Start fresh execution with original prompt + summary of previous work. Log warning. |
| Handback fails (thread gone, context full) | Brain posts result to the domain's main channel as fallback. Log error. |
| Concurrent rekindle of same flare | Second rekindle rejected. Flare manager guards: Active flares can't be rekindled. |
| Aura restarts with active flares | Active → Parked (interrupted, not broken). Rekindlable. |
| Scheduler fires trigger but flare manager down | Scheduler retries on next tick. Flare manager is supervised — restarts automatically. |
| Max concurrent flares reached | Ignite/rekindle returns error. Brain decides: queue, park another, or inform user. |

## What Changes

### New
- `flare_manager.gleam` — new actor
- `flares` table in SQLite
- `flare` built-in tool
- Roster summary in brain system prompt
- Scheduler integration for flare triggers
- Handback: result → brain conversation → tool loop

### Modified
- `brain.gleam` — flare event handlers, handback logic, roster in system prompt, new tool
- `db_schema.gleam` — flares table, schema version bump
- `scheduler.gleam` — flare trigger checking

### Deprecated
- `acp_manager.gleam` — responsibilities absorbed by flare_manager
- `session_store.gleam` — replaced by SQLite flares table
- `acp_dispatch` tool — replaced by `flare:ignite`
- `send_input` / `acp_prompt` tool — replaced by `flare:rekindle`
- `acp_kill` tool — replaced by `flare:archive` or explicit kill
- `acp_status` / `acp_list` tools — replaced by `flare:status` / `flare:list`

### Unchanged
- Transport layer (stdio, HTTP, tmux)
- Monitor (push-based stdio, tmux polling)
- Erlang FFI
- Conversation infrastructure
- Domain model
- Discord gateway

## Implementation Phases

The full architecture is implemented incrementally. Each phase delivers working software and is deployed and verified before the next begins.

### Phase 1: Result Handback

The core value delivery. Agent results flow back to the brain's conversation.

- Capture result payload in event loop (monitor summary + last tool calls + agent's final message)
- Extend `AcpCompleted` event to carry result text
- Brain: on completion, append system message to thread conversation, re-enter tool loop, respond naturally
- No new actors, no new tools, no persistence changes

This uses the existing `acp_manager` as-is. The only changes are in the event loop (buffering), monitor (GetSummary message), brain (handback handler), and types (result_text field).

### Phase 2: Unified Flare Tool

Replace 5 ACP tools with one `flare` tool. Same underlying dispatch machinery, better abstraction.

- New `flare` tool definition with action parameter
- Routes to existing manager functions
- Update system prompt
- Deprecate old tools

### Phase 3: Flare Manager + SQLite Persistence

Introduce the flare_manager actor and move persistence to SQLite.

- `flare_manager.gleam` — wraps transport layer, owns roster
- `flares` table in SQLite
- Migrate from JSON file store
- Recovery from SQLite on restart
- Absorb acp_manager responsibilities

### Phase 4: Triggers, Parking, and Rekindling

Deferred execution and persistent flare lifecycle.

- Park/rekindle with `--resume`
- Schedule and delay triggers integrated with scheduler
- Roster summary in brain system prompt
- Archived state

### Future: AuraInstance Execution, Event Triggers

- Flares that run as full Aura instances with own system prompt and domain knowledge
- Event-based triggers when integration infrastructure exists (email, GitHub, etc.)

## System Invariants (Updated)

The existing ACP invariants (ENGINEERING.md) evolve for flares:

1. **A flare is always in exactly one state.** States: Active, Parked, Archived, Failed. Every transition persists and notifies.
2. **An active flare that stops is always accounted for.** If a process disappears, the flare manager detects it and transitions the flare (to Parked on restart, to Failed on unexpected death).
3. **One execution per flare at a time.** A flare cannot have two concurrent processes. Rekindle of an Active flare is rejected.
4. **Handback is never silent.** When a flare's execution completes, the brain always processes the result — either through the tool loop (success) or by posting an error (failure).
