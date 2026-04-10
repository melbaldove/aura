# ACP Result Handback

## Problem

When an ACP session finishes a turn, the brain posts a canned status card in Discord and stops. The user never gets an answer to their original question. The agent did the work — read files, analyzed code, drew conclusions — but the results are trapped in the session. The brain doesn't read them, doesn't summarize them, doesn't respond.

## Design

When the ACP agent finishes responding (`end_turn`), hand back structured results to the brain's conversation. The brain appends them as a system message, re-enters the tool loop, and answers the user naturally.

### Data flow

```
ACP agent finishes turn (stopReason: end_turn)
  → Event loop builds result payload (Done + last tool calls + agent response)
  → AcpCompleted event carries the payload
  → Brain resolves the thread for this session
  → Brain appends system message to conversation
  → Brain enters tool loop — LLM sees full history + results
  → LLM responds to the user (can also read_file for more detail)
```

### Result payload

Three layers of information, from high-level to detailed:

| Field | Source | Purpose |
|---|---|---|
| Done summary | Monitor's `last_summary` (cumulative Done from LLM) | High-level progress tracker |
| Last 5 tool calls | Event loop buffers tool_call names as they arrive | What the agent did at the end |
| Agent's final response | Event loop buffers `agent_message_chunk` text, resets on each `tool_call` | The agent's actual conclusion/output |

### System message format

```
[ACP agent finished responding]

Done: Read 8 exclusion files, grepped isExcluded (not in pipeline), checked Rust (none)

Last actions:
- Read `step-function/src/lib/exclusion.ts`
- Write `exclusion-analysis.md`

Agent's response:
The exclusion feature is fully implemented for CRUD and approval but isExcluded()
is NOT called from the transaction pipeline. The feature is built but not enforced...
```

### Brain handling

On `AcpCompleted` (specifically `end_turn`):

1. Resolve the thread channel from session metadata (already stored as `thread_id` in the session store)
2. Load the conversation for that channel (existing `conversation.get_or_load_db`)
3. Append the system message to the conversation buffer
4. Enter the tool loop (`handle_with_llm` or equivalent) — LLM sees full thread history + ACP results
5. LLM responds naturally — answers the user's original question, can use `read_file` for more detail
6. Response sent to Discord in the thread

### Session stays alive

`end_turn` means the agent finished its turn, not that the session is dead. The session stays in `running` state. If the user asks a follow-up, the brain can `send_input` to resume the same ACP session with full context.

### Event loop changes

The event loop (`stdio_event_loop` in transport.gleam) needs to buffer:

1. **Last 5 tool_call names** — a sliding window. Each `tool_call` event appends the tool name. Cap at 5, drop oldest.
2. **Agent's final message** — accumulate `agent_message_chunk` text. Reset when a new `tool_call` starts (agent is working again, not speaking). When `Complete("end_turn")` fires, this buffer has the agent's last response.

These are buffered in the event loop process, NOT in the monitor. The monitor handles progress display. The event loop handles completion payload.

### Monitor integration

The monitor's `last_summary` (the cumulative Done field) needs to be accessible when building the completion payload. Two options:

**A)** The event loop asks the monitor for its last_summary on completion.
**B)** The monitor pushes its last_summary to the event loop after each tick.

**Decision: A** — the event loop sends a message to the monitor asking for the latest summary. This is a one-time request at completion, not a polling pattern. The monitor already handles messages via its actor — add a `GetSummary` message type that returns the current `last_summary`.

### AcpCompleted event changes

Currently:
```gleam
AcpCompleted(session_name: String, domain: String, report: AcpReport)
```

The `AcpReport` type already has fields. Add the handback data there or alongside it:

```gleam
AcpCompleted(
  session_name: String,
  domain: String,
  report: AcpReport,
  result_text: String,  // formatted system message text
)
```

Or simpler: just put the entire formatted result in `report.anchor` (currently set to "Session completed"). The brain already reads `report` — it just needs to use the content.

**Decision:** Add `result_text: String` to `AcpCompleted`. Clean separation — `report` is structured data for the manager, `result_text` is the formatted handback for the brain.

### Failed sessions

For `AcpFailed` (cancelled, refused, process exit, timeout): no handback. The brain just posts the error message as today. No tool loop re-entry — there's nothing useful to process.

### What changes

| Component | Change |
|---|---|
| `transport.gleam` event loop | Buffer last 5 tool names + last agent message. On Complete, request monitor summary, build result text, include in AcpCompleted. |
| `monitor.gleam` | Add `GetSummary` message to stdio monitor actor. Returns `last_summary`. |
| `monitor.gleam` AcpCompleted type | Add `result_text: String` field. |
| `brain.gleam` AcpCompleted handler | Load thread conversation, append system message with result_text, enter tool loop, respond. |
| `manager.gleam` | Pass through the new AcpCompleted field. |

### What stays the same

- Monitor progress display (edit in place, 15s cadence, LLM summaries)
- AcpStarted / AcpFailed handling
- Session lifecycle in manager
- The acp_dispatch tool definition and execution
- The send_input flow for follow-ups

## Scope

This spec:
- Event loop completion buffering (tool names + agent text)
- Monitor GetSummary message
- AcpCompleted result_text field
- Brain handback → conversation → tool loop

NOT in scope:
- Multi-turn follow-up UX (send_input already works, just needs the brain to know it can)
- HTTP/tmux transport handback (same pattern, implement when needed)
- Streaming the agent's response to Discord in real-time
