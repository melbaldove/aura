# ADR 016: Push-Based Stdio Monitor with LLM Summarization

## Status
Accepted

## Context
The ACP monitor was hardwired to tmux — polling `tmux capture-pane` on a 15-second heartbeat. Adding stdio transport required a different approach since stdio has a native push-based event stream (ACP protocol notifications).

Three designs were attempted:

**v1 (rejected):** Pull-based snapshot request/reply. Forced a polling pattern onto push-based data. Required a bridge process, poll_snapshot_request FFI, and a 2-second busy-wait. Wrong abstraction — generalized the mechanism (polling) instead of the interface (events in, progress out).

**v2 (rejected):** Push-based with client-side formatting. Transport pushed raw events to monitor, monitor formatted them with `format_snapshot` (tool call emoji lists). Failed because: (a) fragile string matching to extract tool names from JSON, (b) the output was either empty or bare tool names with no context.

**v3 (accepted):** Push-based with LLM summarization. Transport pushes raw NDJSON lines to monitor. Monitor accumulates lines, and every 15 seconds asks the LLM to produce a structured summary (Title/Status/Done/Current/Next) — same format as tmux monitor. No fragile parsing. The LLM reads the JSON natively.

## Decision
The monitor is a push-based OTP actor receiving `RawLine` messages from the transport and self-scheduling `Tick` messages. On each tick, it sends accumulated raw lines to the LLM for summarization. Progress is displayed by editing a single Discord message in place (not sending new messages).

Transports are dumb pipes — they forward raw data immediately. The monitor is the smart component — it owns accumulation, timing, idle detection, and formatting.

## Consequences
- Stdio sessions get structured 15-second progress updates with meaningful content
- Same LLM summarization pattern as tmux monitor — brain handles both identically
- No fragile JSON parsing in the FFI or Gleam code
- One LLM call per 15 seconds per active session (~$0.001/call at glm-5-turbo rates)
- Progress displayed as a single auto-updating Discord message (edit in place)
- Existing tmux monitor untouched — can be migrated to push pattern later

## Lessons Learned
- Engineering principle #10 violated initially: generalized the polling mechanism instead of questioning whether polling was right for stdio
- Engineering principle #11 violated: the 2-second busy-wait and bridge process were duck-tape signals
- Three iterations to get right — should have read the ACP spec (principle #13) and questioned the tmux assumptions (principle #10) before building
