# Per-tool deadline design

## Problem

Aura currently schedules one 10-minute deadline when a channel turn starts. The timer is not reset when the LLM completes, a tool finishes, another tool starts, or the tool loop returns to the LLM. A healthy turn that keeps making progress can therefore be terminated exactly 10 minutes after the original user message.

The deadline should detect one stuck tool call, not limit the total duration of an active turn.

## Decision

Replace the absolute turn deadline with a 10-minute watchdog scoped to the currently running tool call.

- Do not schedule a deadline when a user or handback turn starts.
- Schedule a deadline when a tool worker starts.
- Include the tool call ID in the deadline message.
- Cancel the current tool deadline when that tool returns.
- When another tool starts, arm a fresh 10-minute deadline for that call.
- Ignore a deadline message whose call ID does not match the current `ToolWorker`. This makes timer cancellation races harmless.
- If the matching deadline fires, kill that tool worker, fail the turn, advance queued work, and tell the user which tool exceeded the 10-minute limit.
- Keep existing LLM streaming, vision, shell, browser, and provider transport timeouts unchanged.
- Keep the existing maximum tool-iteration guard as protection against fast runaway loops.

## State-machine flow

1. A turn starts with no deadline timer.
2. The LLM may stream and select tools without consuming a turn-wide deadline.
3. `SpawnToolWorker(call)` starts the worker and arms `ToolDeadline(call.id)` for 600 seconds.
4. `ToolResult(call.id, ...)` cancels that timer before the state machine starts another tool or returns to the LLM.
5. `ToolDeadline(call.id)` fails the turn only when the active worker is `ToolWorker(_, call.id)`.
6. A late deadline for an older call is ignored.

## Error behavior

The user-facing message will identify the stuck operation, for example: `Tool read_file exceeded 10-minute deadline`. The normal failure path will stop typing, record the failed stream summary, clear the turn, and start the next queued item.

## Tests

Add state-machine regressions proving:

- starting a turn no longer schedules an absolute deadline;
- starting a tool schedules a 600-second call-ID-scoped deadline;
- a tool result cancels its deadline;
- a matching tool deadline kills the worker and fails the turn;
- a stale deadline for a prior tool call is ignored;
- a multi-tool turn can continue across tool results without an overall deadline;
- finalization and cancellation still cancel any active tool deadline.

Run focused channel-actor tests first, then the full behavior suite and BDD scenarios before deployment.

## Documentation impact

Update comments and tests that describe a 10-minute turn deadline. No configuration, schema, architecture diagram, environment variable, or tool-count changes are required.
