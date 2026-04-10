# Transport-Agnostic ACP Monitor

## Problem

The ACP monitor is hardwired to tmux — it polls `tmux capture-pane`, feeds the output to an LLM for classification, and emits structured progress updates to Discord on a 15-second heartbeat. When we added stdio transport, there was no equivalent: every raw `session/update` notification was forwarded directly to Discord, causing 20+ messages per minute of empty status headers.

The stdio transport has richer signal than tmux (typed events from the ACP protocol vs. raw terminal text), but no mechanism to aggregate and present it on a sensible cadence.

## Design

### Core abstraction

The monitor becomes transport-agnostic. It owns the heartbeat timer, idle detection, and Discord delivery. Each transport provides a **data source** that the monitor queries on each tick.

The data source is a process that responds to a `GetSnapshot` message with an `ActivitySnapshot` — a structured summary of events since the last check.

### ActivitySnapshot

```
ActivitySnapshot {
  tool_calls: List(String)      // titles of tools invoked since last check
  message_chunks: String        // concatenated agent text since last check
  event_count: Int              // total events since last check
  last_event_type: String       // most recent sessionUpdate type
}
```

This is ACP-native. The monitor reasons about protocol-level event types, not raw text.

### Data source interface

The monitor holds a `Subject(SnapshotRequest)` pointing to the data source process. On each heartbeat tick, the monitor sends a `GetSnapshot` request and receives an `ActivitySnapshot` reply.

```
monitor tick
  → send GetSnapshot to data source subject
  → receive ActivitySnapshot
  → format for Discord
  → emit AcpProgress (or idle detection)
```

### Data source per transport

| Transport | Data source process | How it works |
|---|---|---|
| **Tmux** | Dedicated process that calls `tmux capture-pane` on demand | Same as today but behind the interface. LLM classification of tmux output produces the snapshot. `tool_calls` and `message_chunks` extracted from the LLM's structured output. |
| **Stdio** | The stdio event loop process itself | Already alive for the session lifetime. Accumulates events into a buffer. On `GetSnapshot`, reads and clears the buffer, returns structured snapshot. |
| **HTTP** | The SSE event loop process | Same pattern as stdio — accumulates SSE events, flushes on request. |

### Stdio event accumulation

The stdio event loop (`stdio_event_loop_inner` in `transport.gleam`) maintains an accumulator:

```
StdioAccumulator {
  tool_calls: List(String)       // tool_call titles, appended as they arrive
  message_text: String           // agent_message_chunk text, concatenated
  event_count: Int               // total events received
  last_event_type: String        // most recent sessionUpdate discriminator
}
```

When a `GetSnapshot` message arrives (via a Gleam `Subject`), the loop:
1. Builds an `ActivitySnapshot` from the accumulator
2. Resets the accumulator to empty
3. Replies with the snapshot
4. Continues the event loop

This requires the stdio event loop to select on both port messages (from the FFI) and Gleam messages (from the monitor). This is achieved by using `process.new_selector()` with both a port message handler and a Gleam subject handler, or by using `process.receive` with a timeout and checking for snapshot requests in between.

**Implementation note:** Since the FFI sends events to the process mailbox as `{stdio_event, Type, Data}` tuples, and Gleam subjects also deliver to the mailbox, we can use an Erlang receive that handles both. Alternatively, the stdio event loop can check for snapshot requests on each iteration using `process.receive` with a 0ms timeout before blocking on `stdio.receive_event`.

### Discord formatting

The monitor formats the snapshot into a single Discord message:

**Active session with tool calls:**
```
📋 acp-cm2-t123 · 2m elapsed
🔧 Read src/lib/exclusion.ts
🔧 Search "isExcluded" in codebase
🔧 Read __tests__/exception/isExcluded.unit.test.ts
💬 Analyzing scope resolution logic...
```

**Active session with only text output:**
```
📋 acp-cm2-t123 · 5m elapsed
💬 The exclusion feature provides a mechanism for PCHC administrators to...
```

**Idle session (no tool_calls or message_chunks):**
```
⏸️ acp-cm2-t123 · 8m elapsed · idle
Last activity: tool_call
```

### Idle detection

ACP-native idle detection based on event types:

- **Active:** `tool_calls` non-empty OR `message_chunks` non-empty
- **Idle:** both empty (no meaningful work events since last check)
- Idle counter increments on consecutive idle checks (same as tmux monitor today)
- Idle surfacing threshold and timeout remain configurable

Events like `config_option_update`, `session_info_update`, `available_commands_update` do NOT count as activity — they're metadata, not work.

### Heartbeat cadence

Same as existing monitor:
- Active sessions: check every 15 seconds
- Idle sessions: check every 60 seconds
- Idle surface threshold: 3 consecutive idle checks (45 seconds)

### Monitor startup changes

Currently `start_monitor_only` creates a monitor actor that's tmux-specific. The refactored version:

1. Monitor actor receives a data source `Subject` at startup (instead of assuming tmux)
2. Transport creates the appropriate data source process and passes its subject to the monitor
3. Monitor logic is identical regardless of transport — it just calls `GetSnapshot` on the subject

### What stays the same

- `AcpEvent` types (`AcpProgress`, `AcpStarted`, `AcpCompleted`, etc.)
- Brain's handling of `AcpProgress` (formatting, Discord send)
- Manager's session lifecycle (dispatch, persist, state transitions)
- Terminal events (`Complete`, `Exit`, `Error`) still go directly from the event loop to the manager — they don't wait for the heartbeat

### What changes

| Component | Change |
|---|---|
| `monitor.gleam` | Remove tmux-specific code. Accept data source subject at startup. Query it on each tick. |
| `transport.gleam` (stdio) | Event loop accumulates events + handles `GetSnapshot` messages. Starts monitor with its own subject as data source. |
| `transport.gleam` (tmux) | Wraps existing `tmux capture-pane` + LLM classification behind the data source interface. Starts monitor with tmux data source subject. |
| `transport.gleam` (http) | SSE loop accumulates events + handles `GetSnapshot`. Same pattern as stdio. |
| `brain.gleam` | Minor formatting changes — render tool_calls list and message_chunks instead of parsing "Done:/Current:" structured text. Or: keep the structured format and have the data source produce it. |

### Brain formatting approach

Two options for how the brain renders stdio progress:

**Option 1: New stdio-specific format.** The brain checks transport type and renders tool call lists + message snippets differently from tmux structured output.

**Option 2: Data source produces the structured format.** The stdio data source formats the snapshot into "Done:/Current:/Next:" text, matching what the brain already expects. The brain doesn't change.

**Decision: Option 1.** The structured "Done:/Current:" format was designed for LLM-summarized tmux output. Tool call lists are a better native representation for stdio. The brain already switches on `is_idle` — adding a check for content format is minimal.

## Scope

This spec covers:
- Abstracting the monitor data source interface
- Stdio event accumulation and snapshot
- ACP-native idle detection
- Discord formatting for stdio progress

This spec does NOT cover:
- HTTP/SSE transport data source (same pattern, implement when needed)
- Tmux monitor refactor (can be done incrementally — wrap existing code behind the interface)
- Changes to the manager actor

## Migration path

1. Define the `ActivitySnapshot` type and `GetSnapshot` message
2. Implement stdio accumulator + snapshot handler in the stdio event loop
3. Add stdio-aware formatting to the brain
4. Start the monitor for stdio sessions with the stdio data source
5. (Later) Refactor tmux monitor behind the same interface
6. (Later) Add HTTP/SSE data source
