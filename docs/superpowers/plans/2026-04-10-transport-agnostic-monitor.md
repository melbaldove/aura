# Transport-Agnostic ACP Monitor v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace client-side event parsing with LLM-based summarization. The FFI forwards raw JSON lines, the monitor accumulates them, and every 15 seconds asks the LLM to produce a structured summary — same format as tmux monitor.

**Architecture:** FFI sends raw NDJSON → event loop pushes to monitor → monitor accumulates → tick fires → LLM summarizes → AcpProgress → brain → Discord. No fragile string parsing. The LLM reads the JSON natively.

**Tech Stack:** Gleam/OTP actors, LLM chat (existing `llm.chat`), Erlang FFI.

---

## File Structure

| File | Change |
|---|---|
| `src/aura_acp_stdio_ffi.erl` | Simplify handle_line to forward raw line, remove extract_content_text |
| `src/aura/acp/stdio.gleam` | Update receive_event to handle new FFI format |
| `src/aura/acp/monitor.gleam` | Replace ActivitySnapshot with raw lines, add LLM tick, remove format_snapshot |
| `src/aura/acp/transport.gleam` | Forward raw_line instead of event_type+content |
| `src/aura/brain.gleam` | Revert stdio-specific formatting branch |
| `test/aura/acp/monitor_test.gleam` | Update tests for new types |

---

### Task 1: Simplify FFI to forward raw lines

**Files:**
- Modify: `src/aura_acp_stdio_ffi.erl`

- [ ] **Step 1: Simplify handle_line**

In `src/aura_acp_stdio_ffi.erl`, replace the current `handle_line` function with:

```erlang
handle_line(Line, EventPid) ->
    case binary:match(Line, <<"\"method\":\"session/update\"">>) of
        {_, _} ->
            %% Forward the raw JSON line — the LLM will parse it
            EventType = extract_field(Line, <<"\"sessionUpdate\":\"">>),
            EventPid ! {stdio_event, EventType, Line};
        nomatch ->
            case binary:match(Line, <<"\"stopReason\"">>) of
                {_, _} ->
                    StopReason = extract_field(Line, <<"\"stopReason\":\"">>),
                    EventPid ! {stdio_complete, StopReason};
                nomatch ->
                    ok
            end
    end.
```

- [ ] **Step 2: Remove extract_content_text**

Delete the entire `extract_content_text` function from the file.

- [ ] **Step 3: Remove the debug logging line**

Remove the `io:format("[acp-stdio-ffi] eol: ~s~n"` line from `session_loop` — it was temporary for debugging.

- [ ] **Step 4: Build and test**

Run: `gleam build 2>&1 && gleam test 2>&1 | tail -3`

- [ ] **Step 5: Commit**

```bash
git add src/aura_acp_stdio_ffi.erl
git commit -m "refactor: FFI forwards raw JSON lines instead of parsing event content"
```

---

### Task 2: Update monitor to accumulate raw lines + LLM summarize

**Files:**
- Modify: `src/aura/acp/monitor.gleam`
- Modify: `test/aura/acp/monitor_test.gleam`

- [ ] **Step 1: Update StdioMonitorMsg**

Change `RawEvent(event_type: String, content: String)` to `RawLine(line: String)`.

- [ ] **Step 2: Update PushMonitorState**

Replace `acc: ActivitySnapshot` with:
```gleam
    raw_lines: List(String),
    last_summary: String,
    task_prompt: String,
    llm_config: Option(llm.LlmConfig),
```

- [ ] **Step 3: Update start_push_monitor signature**

Add `task_prompt: String` and `monitor_model: String` parameters:

```gleam
pub fn start_push_monitor(
  config: MonitorConfig,
  session_name: String,
  domain: String,
  task_prompt: String,
  monitor_model: String,
  on_event: fn(AcpEvent) -> Nil,
) -> process.Subject(StdioMonitorMsg) {
```

Build LlmConfig from `monitor_model` using existing `models.build_llm_config`.

- [ ] **Step 4: Update handle_push_msg for RawLine**

```gleam
fn handle_raw_line(
  state: PushMonitorState,
  line: String,
) -> actor.Next(PushMonitorState, StdioMonitorMsg) {
  actor.continue(PushMonitorState(
    ..state,
    raw_lines: list.append(state.raw_lines, [line]),
  ))
}
```

- [ ] **Step 5: Update handle_push_tick with LLM summarization**

Replace the current `handle_push_tick`. On tick:
- If `raw_lines` non-empty and `llm_config` is Some: call LLM
- Join raw_lines (cap at 3000 chars from tail), build prompt (reuse `generate_progress_update` pattern)
- Parse Title/Status from response
- Emit AcpProgress with title, status, summary
- Reset raw_lines, update last_summary

The LLM prompt should be the same as the existing tmux `generate_progress_update` system prompt. The user prompt changes to:

```
Task: {task_prompt}
Elapsed: {elapsed_min} minutes
{previous_section}
{idle_hint}

Latest ACP protocol events (JSON-RPC):
{raw_lines_tail}
```

- [ ] **Step 6: Remove format_snapshot**

Delete `format_snapshot` from monitor.gleam. The LLM does the formatting now.

- [ ] **Step 7: Simplify ActivitySnapshot**

Either remove it entirely or simplify to just be used by the `snapshot_is_active` check. Simplest: replace the active check inline:

```gleam
let is_active = state.raw_lines != []
```

Remove `ActivitySnapshot` type, `snapshot_is_active`, `format_snapshot`.

- [ ] **Step 8: Update tests**

Remove the format_snapshot tests (they test a deleted function). Remove the ActivitySnapshot construction tests. Replace with tests for the new monitor:

```gleam
pub fn monitor_accumulates_raw_lines_test() {
  let event_subject = process.new_subject()
  let on_event = fn(event) { process.send(event_subject, event) }

  let monitor = acp_monitor.start_push_monitor(
    acp_monitor.MonitorConfig(
      emit_interval_ms: 200,
      idle_interval_ms: 500,
      idle_surface_threshold: 3,
      timeout_ms: 60_000,
    ),
    "test-session",
    "test-domain",
    "Analyze the code",
    "",  // empty monitor_model = no LLM, just accumulate
    on_event,
  )

  process.send(monitor, acp_monitor.RawLine("{\"update\":{\"toolName\":\"Read\"}}"))
  process.send(monitor, acp_monitor.RawLine("{\"update\":{\"toolName\":\"Grep\"}}"))

  // With no LLM config, tick should still emit with raw line count info
  case process.receive(event_subject, 500) {
    Ok(acp_monitor.AcpProgress(_, _, _, _, summary, False)) -> {
      // Summary should indicate activity even without LLM
      { summary != "" } |> should.be_true
    }
    _ -> should.fail()
  }
}

pub fn monitor_idle_detection_raw_test() {
  let event_subject = process.new_subject()
  let on_event = fn(event) { process.send(event_subject, event) }

  let _monitor = acp_monitor.start_push_monitor(
    acp_monitor.MonitorConfig(
      emit_interval_ms: 50,
      idle_interval_ms: 50,
      idle_surface_threshold: 2,
      timeout_ms: 60_000,
    ),
    "test-idle",
    "test-domain",
    "Analyze the code",
    "",
    on_event,
  )

  process.sleep(250)
  let is_idle = drain_for_idle(event_subject)
  is_idle |> should.be_true
}
```

When LLM config is None (empty model string), the tick should emit a fallback summary like "[N events received]" so tests can verify the tick fires.

- [ ] **Step 9: Build and test**

Run: `gleam build 2>&1 && gleam test 2>&1 | tail -3`

- [ ] **Step 10: Commit**

```bash
git add src/aura/acp/monitor.gleam test/aura/acp/monitor_test.gleam
git commit -m "feat: monitor accumulates raw lines, LLM summarizes on tick"
```

---

### Task 3: Wire transport and revert brain

**Files:**
- Modify: `src/aura/acp/transport.gleam`
- Modify: `src/aura/brain.gleam`

- [ ] **Step 1: Update event loop to forward RawLine**

In `transport.gleam`, the event loop currently sends `RawEvent(event_type, content)`. Change to `RawLine(raw_line)`:

```gleam
    stdio.Event(_event_type, raw_line) -> {
      process.send(monitor, acp_monitor.RawLine(raw_line))
      stdio_event_loop(session_name, domain, on_event, monitor)
    }
```

Note: `stdio.Event` now carries `(event_type, raw_line)` where raw_line is the full JSON. The transport ignores event_type and forwards raw_line.

- [ ] **Step 2: Update dispatch_stdio to pass task_prompt and monitor_model**

```gleam
      let monitor = acp_monitor.start_push_monitor(
        acp_monitor.default_monitor_config(task_spec.timeout_ms),
        session_name,
        task_spec.domain,
        task_spec.prompt,
        "glm-5-turbo",  // or from config — same as tmux monitor
        on_event,
      )
```

Note: The monitor_model should come from config. For now hardcode "glm-5-turbo" to match the existing tmux monitor. Can be made configurable later.

- [ ] **Step 3: Revert brain stdio formatting branch**

In `brain.gleam`, find the `let body = case title {` block (around line 953). Revert it back to the original `let body = case is_idle {` — remove the `title == ""` stdio branch since the LLM now produces the same structured format for both transports.

The original code (before our v1 changes):
```gleam
      let body = case is_idle {
        True -> {
          let done = extract_summary_field(summary, "Done:")
          let needs = extract_summary_field(summary, "Needs input:")
          let parts = [
            case done {
              "" -> ""
              _ -> "**Done:** " <> done
            },
            case needs {
              "" | "none" | "None" -> ""
              _ -> "**Needs input:** " <> needs
            },
          ]
          let body_text =
            list.filter(parts, fn(p) { p != "" }) |> string.join("\n")
          body_text <> "\n\nWant me to check on this? Reply in this thread."
        }
        False -> {
          let status_line = case status {
            "" -> ""
            _ -> "**Status:** " <> status
          }
          let done = extract_summary_field(summary, "Done:")
          let current = extract_summary_field(summary, "Current:")
          let needs = extract_summary_field(summary, "Needs input:")
          let next = extract_summary_field(summary, "Next:")
          let parts = [
            status_line,
            case done {
              "" -> ""
              _ -> "**Done:** " <> done
            },
            case current {
              "" -> ""
              _ -> "**Current:** " <> current
            },
            case needs {
              "" | "none" | "None" -> ""
              _ -> "**Needs input:** " <> needs
            },
            case next {
              "" -> ""
              _ -> "**Next:** " <> next
            },
          ]
          list.filter(parts, fn(p) { p != "" }) |> string.join("\n")
        }
      }
```

- [ ] **Step 4: Build and test**

Run: `gleam build 2>&1 && gleam test 2>&1 | tail -3`

- [ ] **Step 5: Commit**

```bash
git add src/aura/acp/transport.gleam src/aura/brain.gleam
git commit -m "feat: transport forwards raw lines, brain uses unified LLM-summarized format"
```

---

### Task 4: Deploy and verify

- [ ] **Step 1: Run full test suite**
- [ ] **Step 2: Deploy via `bash scripts/deploy.sh`**
- [ ] **Step 3: Clear sessions**
- [ ] **Step 4: Trigger ACP dispatch, verify:**
  - "ACP Started" message
  - After ~15s, one progress message with structured Title/Status/Done/Current/Next
  - Updates every 15s, not per-event
  - No spam
  - Content is meaningful (file names, tool descriptions, not just "Read")
- [ ] **Step 5: Commit fixes if needed, push**

---

### Task 5: Documentation

- [ ] **Step 1: Write ADR 016** covering v1→v2→v3 evolution and why LLM summarization won
- [ ] **Step 2: Update CLAUDE.md test count**
- [ ] **Step 3: Update principle #10** with assumption verification addition
- [ ] **Step 4: Remove debug logging if still present**
- [ ] **Step 5: Commit and push**
