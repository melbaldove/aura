# Transport-Agnostic ACP Monitor (v3)

> Supersedes v1 (pull-based snapshot request/reply) and v2 (push-based with client-side formatting). v1 forced a pull pattern onto push data. v2 tried to parse event metadata with string matching instead of using the LLM.

## Problem

The ACP monitor needs to show human-readable progress for stdio sessions in Discord. Previous attempts tried to extract and format event metadata (tool names, file paths) with fragile string matching in the Erlang FFI. This produced either empty content or bare tool names ("Read", "Grep") with no context.

The tmux monitor already solves this correctly: it feeds raw output to an LLM every 15 seconds and gets structured summaries back. The stdio monitor should do the same.

## Design Principle

**Transports are dumb pipes. The monitor is the smart component. The LLM does the understanding.**

Transports forward raw event data. The monitor accumulates it and periodically asks the LLM to summarize. No fragile parsing, no format-specific extraction. The LLM reads the raw JSON natively.

## Architecture

```
Stdio event loop → push raw JSON line → Monitor actor (accumulate lines)
                                              ↓ (every 15s)
                                         LLM summarize → structured summary
                                              ↓
                                         AcpProgress → brain → Discord
```

## Monitor Actor

### Messages

```
StdioMonitorMsg {
  RawLine(line: String)   // raw JSON-RPC line from adapter
  Tick                    // self-scheduled timer
}
```

- `RawLine` — transport pushes the raw NDJSON line for every `session/update` notification.
- `Tick` — self-scheduled. On tick: if lines accumulated, LLM summarize, emit, reset.

### Configuration

```
MonitorConfig {
  emit_interval_ms: Int        // default 15_000, configurable
  idle_interval_ms: Int        // default 60_000
  idle_surface_threshold: Int  // default 3
  timeout_ms: Int              // session timeout
}
```

### State

```
PushMonitorState {
  config: MonitorConfig
  session_name: String
  domain: String
  task_prompt: String          // original task prompt for LLM context
  raw_lines: List(String)      // accumulated since last tick
  last_summary: String         // previous LLM summary for continuity
  idle_checks: Int
  idle_surfaced: Bool
  started_at_ms: Int
  llm_config: Option(LlmConfig)
  on_event: fn(AcpEvent) -> Nil
  self_subject: Subject(StdioMonitorMsg)
}
```

### Tick logic

1. If `raw_lines` is non-empty:
   - Join lines (cap at ~3000 chars from the tail)
   - Send to LLM with system prompt asking for structured summary (same format as tmux: Title/Status/Done/Current/Needs input/Next)
   - Include `last_summary` for continuity ("Previous update: ...")
   - Include `task_prompt` for context
   - Emit `AcpProgress` with title, status, summary from LLM
   - Reset `raw_lines`, update `last_summary`
   - Reset idle counters
   - Schedule next tick at `emit_interval_ms`

2. If `raw_lines` is empty:
   - Increment `idle_checks`
   - If threshold reached and not surfaced: emit idle progress (one LLM call with idle hint)
   - Schedule next tick at `idle_interval_ms`

3. Check session timeout.

### RawLine logic

Just append to `raw_lines`. No parsing.

### LLM prompt

Reuse the existing tmux monitor prompt pattern from `generate_progress_update`. Same system prompt (Title/Status/Done/Current/Needs input/Next), same continuity pattern. The user prompt changes: instead of "Latest output:\n{tmux_pane}", it's "Latest ACP events (JSON-RPC):\n{raw_lines}".

The LLM can read the JSON-RPC events natively — it understands `toolName`, `content.text`, file paths, grep patterns, etc. without us parsing them.

## FFI changes

### handle_line

Stop extracting content. For `session/update` notifications, forward the raw line:

```erlang
handle_line(Line, EventPid) ->
    case binary:match(Line, <<"\"method\":\"session/update\"">>) of
        {_, _} ->
            EventPid ! {stdio_event, Line};
        nomatch ->
            case binary:match(Line, <<"\"stopReason\"">>) of
                {_, _} ->
                    StopReason = extract_field(Line, <<"\"stopReason\":\"">>),
                    EventPid ! {stdio_complete, StopReason};
                nomatch -> ok
            end
    end.
```

Note: `{stdio_event, Line}` — single element, just the raw line. No event type extraction needed.

### Remove

- `extract_content_text` function
- The `"title"` and `"toolName"` extraction fallbacks

### Keep

- `extract_field` (still used for stopReason, sessionId)
- `extract_session_id`
- `jsx_encode`, `json_escape`
- `parse_jsonrpc_id`, `is_error_response`
- All test-exported functions

## stdio.gleam changes

`receive_event` currently returns `Event(event_type, data)`. Change to `Event(raw_line)` — single string, the raw JSON line.

Or simpler: keep the existing FFI return format but change what's sent. The FFI sends `{stdio_event, <<"session/update">>, RawLine}` so the Gleam side gets `Event("session/update", raw_line)`. The event_type is always "session/update" for these. The transport just forwards `raw_line` to the monitor.

Actually even simpler: keep the FFI sending `{stdio_event, EventType, Content}` but change Content to be the raw line for session/update events. EventType is still extracted for the transport to know it's an update vs something else. This minimizes changes.

**Decision:** Keep `{stdio_event, EventType, RawLine}` where EventType is extracted from `sessionUpdate` and RawLine is the full JSON line. The transport ignores EventType (just forwards RawLine to monitor). EventType is preserved for future use if needed.

## Transport changes

The event loop forwards raw lines to the monitor:

```gleam
stdio.Event(_event_type, raw_line) -> {
  process.send(monitor, acp_monitor.RawLine(raw_line))
  stdio_event_loop(...)
}
```

## Brain changes

**Revert the stdio-specific formatting branch** from v1 Task 5. Since the LLM now produces the same structured format (Title/Status/Done/Current/Next) for both stdio and tmux, the brain handles both identically. The `title == ""` branch is no longer needed.

## What to remove from v1/v2

- `extract_content_text` in FFI
- `format_snapshot` in monitor.gleam
- `ActivitySnapshot.tool_calls` and `ActivitySnapshot.message_chunks` fields
- Stdio-specific brain formatting branch
- `StdioMonitorMsg.RawEvent(event_type, content)` → replaced with `RawLine(line)`

## What to keep

- `MonitorConfig`, `default_monitor_config`
- Push-based actor pattern (start_push_monitor, Tick self-scheduling)
- `snapshot_is_active` concept (now: `raw_lines != []`)
- Idle detection logic
- Existing tmux monitor (untouched)
- `AcpEvent` types
- Deploy script

## Scope

This implementation:
- Modify FFI to forward raw lines
- Simplify monitor state to raw line accumulation
- Add LLM summarization on tick (reuse tmux prompt pattern)
- Revert brain to unified formatting
- Update tests

NOT in scope:
- Tmux migration
- HTTP transport
