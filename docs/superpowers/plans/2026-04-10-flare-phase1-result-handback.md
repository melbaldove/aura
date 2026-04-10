# Flare Phase 1: Result Handback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an ACP agent finishes, its results flow back to the brain's conversation and the brain re-enters the tool loop to respond naturally — instead of posting a canned "ACP Complete" message.

**Architecture:** The stdio event loop buffers the agent's final message text and last N tool call names. On completion, it requests the monitor's cumulative summary, builds a formatted result payload, and includes it in the AcpCompleted event. The brain receives this, appends a system message to the thread conversation, and re-enters the tool loop so the LLM can answer the user.

**Tech Stack:** Gleam, OTP actors, Erlang FFI (aura_acp_stdio_ffi.erl)

**Codebase context:**
- Tests live in `test/aura/acp/` and `test/aura/`
- Test runner: `gleam test`
- Assertions: `gleeunit` + `should`
- FFI pure functions tested via `test/aura/acp/stdio_ffi_test.gleam`
- The push monitor actor is in `src/aura/acp/monitor.gleam`
- The stdio event loop is in `src/aura/acp/transport.gleam:177-215`
- Brain ACP handlers are in `src/aura/brain.gleam:879-906`
- Conversation loading: `conversation.get_or_load_db(buffers, db_subject, "discord", channel_id, timestamp)`

---

### Task 1: Add GetLastSummary message to the push monitor

The event loop needs to ask the monitor for its cumulative summary at completion time. The monitor already holds `last_summary` in its state — we just need a message to retrieve it.

**Files:**
- Modify: `src/aura/acp/monitor.gleam:58-62` (StdioMonitorMsg type)
- Modify: `src/aura/acp/monitor.gleam:148-164` (handle_push_msg)
- Test: `test/aura/acp/monitor_test.gleam`

- [ ] **Step 1: Write the failing test**

Add to `test/aura/acp/monitor_test.gleam`:

```gleam
pub fn monitor_get_last_summary_test() {
  let event_subject = process.new_subject()
  let on_event = fn(event) { process.send(event_subject, event) }

  let monitor = acp_monitor.start_push_monitor(
    acp_monitor.MonitorConfig(
      emit_interval_ms: 100,
      idle_interval_ms: 500,
      idle_surface_threshold: 3,
      timeout_ms: 60_000,
    ),
    "test-summary",
    "test-domain",
    "Analyze the code",
    "",
    on_event,
  )

  // Send some data and wait for a tick to generate a summary
  process.send(monitor, acp_monitor.RawLine("{\"update\":true}"))
  process.sleep(300)
  // Drain the progress event
  let _ = process.receive(event_subject, 500)

  // Now ask for the summary
  let summary = process.call(monitor, 1000, fn(reply_to) {
    acp_monitor.GetLastSummary(reply_to)
  })
  { summary != "" } |> should.be_true
}

pub fn monitor_get_last_summary_empty_test() {
  let event_subject = process.new_subject()
  let on_event = fn(_event) { process.send(event_subject, Nil) }

  let monitor = acp_monitor.start_push_monitor(
    acp_monitor.MonitorConfig(
      emit_interval_ms: 5000,
      idle_interval_ms: 5000,
      idle_surface_threshold: 3,
      timeout_ms: 60_000,
    ),
    "test-summary-empty",
    "test-domain",
    "Analyze the code",
    "",
    fn(_) { Nil },
  )

  // No data sent, no tick fired — summary should be empty
  let summary = process.call(monitor, 1000, fn(reply_to) {
    acp_monitor.GetLastSummary(reply_to)
  })
  summary |> should.equal("")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test 2>&1 | grep -A2 "monitor_get_last_summary"`
Expected: Compilation error — `GetLastSummary` is not a variant of `StdioMonitorMsg`

- [ ] **Step 3: Add GetLastSummary to StdioMonitorMsg**

In `src/aura/acp/monitor.gleam`, change the `StdioMonitorMsg` type:

```gleam
/// Messages the push-based monitor receives.
pub type StdioMonitorMsg {
  RawLine(line: String)
  Tick
  UpdateStdioSummary(summary: String)
  GetLastSummary(reply_to: process.Subject(String))
}
```

- [ ] **Step 4: Handle GetLastSummary in the message handler**

In `src/aura/acp/monitor.gleam`, update `handle_push_msg`:

```gleam
fn handle_push_msg(
  state: PushMonitorState,
  msg: StdioMonitorMsg,
) -> actor.Next(PushMonitorState, StdioMonitorMsg) {
  case msg {
    RawLine(line) -> {
      actor.continue(PushMonitorState(
        ..state,
        raw_lines: list.append(state.raw_lines, [line]),
      ))
    }
    Tick -> handle_push_tick(state)
    UpdateStdioSummary(summary) -> {
      actor.continue(PushMonitorState(..state, last_summary: summary))
    }
    GetLastSummary(reply_to) -> {
      process.send(reply_to, state.last_summary)
      actor.continue(state)
    }
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `gleam test`
Expected: All 341+ tests pass, including the two new ones.

- [ ] **Step 6: Commit**

```bash
git add src/aura/acp/monitor.gleam test/aura/acp/monitor_test.gleam
git commit -m "feat: add GetLastSummary message to push monitor actor"
```

---

### Task 2: Add result_text field to AcpCompleted event

The completion event needs to carry the formatted result payload so the brain can use it.

**Files:**
- Modify: `src/aura/acp/monitor.gleam:20-30` (AcpEvent type)
- Modify: `src/aura/acp/manager.gleam:378` (handle_monitor_event pattern match)
- Modify: `src/aura/acp/manager.gleam:700-706` (http_recovery_event_loop)
- Modify: `src/aura/acp/transport.gleam:191-194` (stdio_event_loop Complete handler)
- Modify: `src/aura/acp/transport.gleam:276-286` (http_event_loop)
- Test: `test/aura/acp/types_test.gleam`

- [ ] **Step 1: Add result_text to AcpCompleted**

In `src/aura/acp/monitor.gleam`, update the `AcpEvent` type:

```gleam
pub type AcpEvent {
  AcpStarted(session_name: String, domain: String, task_id: String)
  AcpAlert(
    session_name: String,
    domain: String,
    status: types.SessionStatus,
    summary: String,
  )
  AcpCompleted(
    session_name: String,
    domain: String,
    report: types.AcpReport,
    result_text: String,
  )
  AcpTimedOut(session_name: String, domain: String)
  AcpFailed(session_name: String, domain: String, error: String)
  AcpProgress(
    session_name: String,
    domain: String,
    title: String,
    status: String,
    summary: String,
    is_idle: Bool,
  )
}
```

- [ ] **Step 2: Fix all compilation errors from the new field**

Every place that constructs or pattern-matches `AcpCompleted` needs updating. Update each one:

In `src/aura/acp/transport.gleam` stdio_event_loop `Complete("end_turn")` case (~line 191):

```gleam
        "end_turn" ->
          on_event(acp_monitor.AcpCompleted(session_name, domain, types.AcpReport(
            outcome: types.Clean, files_changed: [], decisions: "",
            tests: "", blockers: "", anchor: "Session completed",
          ), ""))
```

In `src/aura/acp/transport.gleam` http_event_loop `"run.completed"` case (~line 276):

```gleam
        "run.completed" ->
          on_event(
            acp_monitor.AcpCompleted(
              session_name,
              domain,
              types.AcpReport(
                outcome: types.Clean,
                files_changed: [],
                decisions: "",
                tests: "",
                blockers: "",
                anchor: data,
              ),
              data,
            ),
          )
```

In `src/aura/acp/manager.gleam` http_recovery_event_loop `"run.completed"` case (~line 700):

```gleam
        "run.completed" ->
          on_event(
            acp_monitor.AcpCompleted(
              session_name,
              domain,
              types.AcpReport(
                outcome: types.Clean,
                files_changed: [],
                decisions: "",
                tests: "",
                blockers: "",
                anchor: data,
              ),
              data,
            ),
          )
```

In `src/aura/acp/manager.gleam` handle_monitor_event pattern match (~line 378):

```gleam
    acp_monitor.AcpCompleted(session_name, _, _, _) ->
      unregister(state, session_name, Complete)
```

In `src/aura/brain.gleam` AcpCompleted handler (~line 879):

```gleam
    acp_monitor.AcpCompleted(session_name, domain, report, _result_text) -> {
      let outcome = acp_types.outcome_to_string(report.outcome)
      let msg = "**ACP Complete** [" <> outcome <> "] -- " <> report.anchor
      let channel = resolve_acp_channel(state, session_name, domain)
      process.spawn_unlinked(fn() {
        send_discord_response(state.discord_token, channel, msg)
      })
      actor.continue(state)
    }
```

- [ ] **Step 3: Run tests to verify compilation and all pass**

Run: `gleam test`
Expected: All tests pass. No behavioral change yet — result_text is `""` everywhere.

- [ ] **Step 4: Commit**

```bash
git add src/aura/acp/monitor.gleam src/aura/acp/transport.gleam src/aura/acp/manager.gleam src/aura/brain.gleam
git commit -m "feat: add result_text field to AcpCompleted event"
```

---

### Task 3: Buffer agent text and tool calls in the stdio event loop

The event loop needs to accumulate data for the handback payload. It buffers: (1) the last 5 tool call names from `tool_call` events, and (2) the agent's final message text from `agent_message_chunk` events (reset on each `tool_call`).

**Files:**
- Modify: `src/aura/acp/transport.gleam:177-215` (stdio_event_loop)
- Test: `test/aura/acp/transport_test.gleam` (new file)

- [ ] **Step 1: Write tests for the pure buffering logic**

Create `test/aura/acp/transport_test.gleam`:

```gleam
import aura/acp/transport
import gleeunit/should

pub fn buffer_tool_call_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Read\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Grep\"}")
  transport.tool_names(buf) |> should.equal(["Read", "Grep"])
}

pub fn buffer_tool_call_caps_at_5_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"A\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"B\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"C\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"D\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"E\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"F\"}")
  transport.tool_names(buf) |> should.equal(["B", "C", "D", "E", "F"])
}

pub fn buffer_agent_text_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "agent_message_chunk", "Hello ")
  let buf = transport.buffer_event(buf, "agent_message_chunk", "world")
  transport.agent_text(buf) |> should.equal("Hello world")
}

pub fn buffer_agent_text_resets_on_tool_call_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "agent_message_chunk", "First message")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Read\"}")
  let buf = transport.buffer_event(buf, "agent_message_chunk", "Second message")
  transport.agent_text(buf) |> should.equal("Second message")
  transport.tool_names(buf) |> should.equal(["Read"])
}

pub fn format_result_text_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Read\"}")
  let buf = transport.buffer_event(buf, "tool_call", "{\"toolName\":\"Write\"}")
  let buf = transport.buffer_event(buf, "agent_message_chunk", "The feature is built but not enforced.")

  let result = transport.format_result_text(buf, "Read 8 files, checked pipeline")
  { result != "" } |> should.be_true
  // Should contain all three sections
  result |> should.not_equal("")
}

pub fn format_result_text_empty_summary_test() {
  let buf = transport.new_completion_buffer()
  let buf = transport.buffer_event(buf, "agent_message_chunk", "Done.")

  let result = transport.format_result_text(buf, "")
  // Should still include agent response even without summary
  result |> should.not_equal("")
}

pub fn extract_tool_name_test() {
  transport.extract_tool_name("{\"toolName\":\"Read\"}") |> should.equal("Read")
  transport.extract_tool_name("{\"toolName\":\"Write\"}") |> should.equal("Write")
  transport.extract_tool_name("no tool here") |> should.equal("")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `gleam test 2>&1 | grep -A2 "buffer_tool_call"`
Expected: Compilation errors — `CompletionBuffer` and related functions don't exist yet.

- [ ] **Step 3: Implement CompletionBuffer and pure functions**

Add to `src/aura/acp/transport.gleam` above the dispatch section:

```gleam
import gleam/list
import gleam/string

// ---------------------------------------------------------------------------
// Completion buffer — accumulates data for handback payload
// ---------------------------------------------------------------------------

pub type CompletionBuffer {
  CompletionBuffer(
    tool_names: List(String),
    agent_text: String,
  )
}

pub fn new_completion_buffer() -> CompletionBuffer {
  CompletionBuffer(tool_names: [], agent_text: "")
}

/// Buffer an event. Returns updated buffer.
/// - tool_call: appends tool name (capped at 5), resets agent_text
/// - agent_message_chunk: appends to agent_text
/// - anything else: no-op
pub fn buffer_event(buf: CompletionBuffer, event_type: String, data: String) -> CompletionBuffer {
  case event_type {
    "tool_call" -> {
      let name = extract_tool_name(data)
      let names = list.append(buf.tool_names, [name])
      let capped = case list.length(names) > 5 {
        True -> list.drop(names, list.length(names) - 5)
        False -> names
      }
      CompletionBuffer(tool_names: capped, agent_text: "")
    }
    "agent_message_chunk" -> {
      CompletionBuffer(..buf, agent_text: buf.agent_text <> data)
    }
    _ -> buf
  }
}

/// Get the buffered tool names.
pub fn tool_names(buf: CompletionBuffer) -> List(String) {
  buf.tool_names
}

/// Get the buffered agent text.
pub fn agent_text(buf: CompletionBuffer) -> String {
  buf.agent_text
}

/// Extract tool name from a raw JSON line containing "toolName":"X".
pub fn extract_tool_name(data: String) -> String {
  case string.split(data, "\"toolName\":\"") {
    [_, rest] ->
      case string.split(rest, "\"") {
        [name, ..] -> name
        _ -> ""
      }
    _ -> ""
  }
}

/// Format the result text for handback from buffer + monitor summary.
pub fn format_result_text(buf: CompletionBuffer, monitor_summary: String) -> String {
  let summary_section = case monitor_summary {
    "" -> ""
    s -> "Summary: " <> s
  }

  let tools_section = case buf.tool_names {
    [] -> ""
    names -> "Last actions: " <> string.join(names, ", ")
  }

  let agent_section = case string.trim(buf.agent_text) {
    "" -> ""
    text -> "Agent's response:\n" <> text
  }

  let sections = list.filter([summary_section, tools_section, agent_section], fn(s) { s != "" })
  string.join(sections, "\n\n")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `gleam test`
Expected: All tests pass including the new transport buffer tests.

- [ ] **Step 5: Commit**

```bash
git add src/aura/acp/transport.gleam test/aura/acp/transport_test.gleam
git commit -m "feat: completion buffer for handback payload — tool names + agent text"
```

---

### Task 4: Wire the completion buffer into the stdio event loop

Now connect the buffer to the live event loop. On each event, buffer it. On completion, request the monitor summary, format the result, and include it in `AcpCompleted`.

**Files:**
- Modify: `src/aura/acp/transport.gleam:177-215` (stdio_event_loop)

- [ ] **Step 1: Add buffer parameter to stdio_event_loop**

Change the function signature and all call sites. The event loop now carries a `CompletionBuffer`:

```gleam
fn stdio_event_loop(
  session_name: String,
  domain: String,
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
  monitor: process.Subject(acp_monitor.StdioMonitorMsg),
  buf: CompletionBuffer,
) -> Nil {
  case stdio.receive_event(5000) {
    stdio.Event(event_type, content) -> {
      process.send(monitor, acp_monitor.RawLine(content))
      let new_buf = buffer_event(buf, event_type, content)
      stdio_event_loop(session_name, domain, on_event, monitor, new_buf)
    }
    stdio.Complete(stop_reason) -> {
      case stop_reason {
        "end_turn" -> {
          // Request monitor's cumulative summary
          let monitor_summary = case
            process.call(monitor, 5000, fn(reply_to) {
              acp_monitor.GetLastSummary(reply_to)
            })
          {
            summary -> summary
          }
          let result_text = format_result_text(buf, monitor_summary)
          on_event(acp_monitor.AcpCompleted(session_name, domain, types.AcpReport(
            outcome: types.Clean, files_changed: [], decisions: "",
            tests: "", blockers: "", anchor: "Session completed",
          ), result_text))
        }
        "cancelled" ->
          on_event(acp_monitor.AcpFailed(session_name, domain, "cancelled"))
        "refusal" ->
          on_event(acp_monitor.AcpFailed(session_name, domain, "refused"))
        other ->
          on_event(acp_monitor.AcpFailed(session_name, domain, "stopped: " <> other))
      }
    }
    stdio.Exit(code) -> {
      io.println("[acp-stdio] Process exited with code " <> code <> " for " <> session_name)
      on_event(acp_monitor.AcpFailed(session_name, domain, "process exited (code " <> code <> ")"))
    }
    stdio.Error(reason) -> {
      io.println("[acp-stdio] Error for " <> session_name <> ": " <> reason)
      on_event(acp_monitor.AcpFailed(session_name, domain, reason))
    }
    stdio.Timeout -> {
      stdio_event_loop(session_name, domain, on_event, monitor, buf)
    }
  }
}
```

- [ ] **Step 2: Update the call site in dispatch_stdio**

In `dispatch_stdio` (~line 161), update the call:

```gleam
        stdio_event_loop(session_name, task_spec.domain, on_event, monitor, new_completion_buffer())
```

- [ ] **Step 3: Run tests to verify compilation and all pass**

Run: `gleam test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/aura/acp/transport.gleam
git commit -m "feat: wire completion buffer into stdio event loop"
```

---

### Task 5: Brain handback — re-enter tool loop on AcpCompleted

The core behavior change. When the brain receives `AcpCompleted` with a non-empty `result_text`, it loads the thread conversation, appends a system message with the flare's findings, re-enters the tool loop, and responds naturally.

**Files:**
- Modify: `src/aura/brain.gleam:879-887` (AcpCompleted handler)

- [ ] **Step 1: Implement the handback handler**

Replace the existing `AcpCompleted` handler in `src/aura/brain.gleam` (~line 879):

```gleam
    acp_monitor.AcpCompleted(session_name, domain, report, result_text) -> {
      let channel = resolve_acp_channel(state, session_name, domain)
      case result_text {
        "" -> {
          // No result payload — fall back to existing behavior
          let outcome = acp_types.outcome_to_string(report.outcome)
          let msg = "**ACP Complete** [" <> outcome <> "] -- " <> report.anchor
          process.spawn_unlinked(fn() {
            send_discord_response(state.discord_token, channel, msg)
          })
          actor.continue(state)
        }
        text -> {
          // Handback — re-enter tool loop with results
          let domain_name = case list.find(state.domains, fn(d) {
            resolve_domain_channel(state, d.name) == channel
              || d.name == domain
          }) {
            Ok(d) -> Some(d.name)
            Error(_) -> None
          }
          process.spawn_unlinked(fn() {
            handle_handback(state, channel, domain_name, session_name, text)
          })
          // Clear progress message for this session
          let new_msgs = dict.delete(state.acp_progress_msgs, session_name)
          actor.continue(BrainState(..state, acp_progress_msgs: new_msgs))
        }
      }
    }
```

- [ ] **Step 2: Implement handle_handback function**

Add to `src/aura/brain.gleam`, after `resolve_acp_channel`:

```gleam
/// Handle a flare reporting back — load thread conversation, append result
/// as system message, and re-enter the tool loop so the LLM responds naturally.
fn handle_handback(
  state: BrainState,
  channel: String,
  domain_name: Option(String),
  session_name: String,
  result_text: String,
) -> Nil {
  io.println("[brain] Handback from " <> session_name <> " to channel " <> channel)

  let system_msg = "[Flare reported back: \"" <> session_name <> "\"]\n\n" <> result_text

  // Start typing indicator
  let typing_stop = start_typing_loop(state.discord_token, channel)

  // Build system prompt (same as handle_with_llm)
  let domain_names = list.map(state.domains, fn(d) { d.name })
  let memory_content = case
    structured_memory.format_for_display(xdg.memory_path(state.paths))
  {
    Ok(c) -> c
    Error(_) -> ""
  }
  let user_content = case
    structured_memory.format_for_display(xdg.user_path(state.paths))
  {
    Ok(c) -> c
    Error(_) -> ""
  }
  let system_prompt =
    build_system_prompt(
      state.soul,
      domain_names,
      state.skill_infos,
      memory_content,
      user_content,
    )

  let domain_prompt = case domain_name {
    Some(name) -> {
      let config_dir = xdg.domain_config_dir(state.paths, name)
      let data_dir = xdg.domain_data_dir(state.paths, name)
      let state_dir = xdg.domain_state_dir(state.paths, name)
      let ctx =
        domain.load_context(config_dir, data_dir, state_dir, state.skill_infos)
      "\n\n" <> domain.build_domain_prompt(ctx)
    }
    None -> ""
  }
  let system_prompt = system_prompt <> domain_prompt

  // Load conversation history
  let now_ts = time.now_ms()
  let #(_, _, history) =
    conversation.get_or_load_db(
      state.conversations,
      state.db_subject,
      "discord",
      channel,
      now_ts,
    )

  // Append the handback result as a system message
  let initial_messages =
    list.flatten([
      [llm.SystemMessage(system_prompt)],
      history,
      [llm.SystemMessage(system_msg)],
    ])

  // Look up domain config for tool context
  let #(domain_cwd, acp_provider, acp_binary, acp_worktree, acp_server_url, acp_agent_name) = case domain_name {
    Some(name) ->
      case list.find(state.domain_configs, fn(dc) { dc.0 == name }) {
        Ok(#(_, cfg)) -> #(
          cfg.cwd,
          cfg.acp_provider,
          cfg.acp_binary,
          cfg.acp_worktree,
          cfg.acp_server_url,
          cfg.acp_agent_name,
        )
        Error(_) -> #(".", "claude-code", "", True, "", "")
      }
    None -> #(".", "claude-code", "", True, "", "")
  }

  let base_dir = case domain_name {
    Some(_) -> domain_cwd
    None -> state.paths.data
  }

  let tool_ctx =
    brain_tools.ToolContext(
      base_dir: base_dir,
      discord_token: state.discord_token,
      guild_id: state.guild_id,
      message_id: "",
      channel_id: channel,
      paths: state.paths,
      skill_infos: state.skill_infos,
      skills_dir: state.skills_dir,
      validation_rules: state.validation_rules,
      db_subject: state.db_subject,
      scheduler_subject: state.scheduler_subject,
      acp_subject: state.acp_subject,
      domain_name: option.unwrap(domain_name, "aura"),
      domain_cwd: domain_cwd,
      acp_provider: acp_provider,
      acp_binary: acp_binary,
      acp_worktree: acp_worktree,
      acp_server_url: acp_server_url,
      acp_agent_name: acp_agent_name,
      on_propose: fn(_) { Nil },
    )

  let result =
    tool_loop_with_retry(state, tool_ctx, channel, initial_messages, 3)

  stop_typing_loop(typing_stop)

  case result {
    Ok(#(response_text, traces, msg_id, new_messages, _prompt_tokens)) -> {
      // Save the handback system message + LLM response to conversation DB
      let handback_msg = llm.SystemMessage(system_msg)
      let all_turn_messages = [handback_msg, ..new_messages]

      let now = time.now_ms()
      case db.resolve_conversation(state.db_subject, "discord", channel, now) {
        Ok(convo_id) -> {
          case
            conversation.save_exchange_to_db(
              state.db_subject,
              convo_id,
              all_turn_messages,
              "aura",
              "Aura",
              now,
            )
          {
            Ok(_) -> Nil
            Error(e) ->
              io.println("[brain] Handback DB save failed: " <> e)
          }
        }
        Error(e) ->
          io.println("[brain] Handback conversation resolve failed: " <> e)
      }

      let full = conversation.format_full_message(traces, response_text)
      let _ = send_or_edit(state.discord_token, channel, msg_id, full)

      // Update in-memory cache
      case state.self_subject {
        Some(subj) -> {
          let dn = option.unwrap(domain_name, "aura")
          process.send(
            subj,
            StoreExchange(channel, all_turn_messages, dn, 0),
          )
        }
        None -> Nil
      }
    }
    Error(e) -> {
      // Fallback — post the raw result text
      io.println("[brain] Handback tool loop failed: " <> e)
      let fallback_msg =
        "**Flare reported back** (" <> session_name <> ")\n\n" <> result_text
      send_discord_response(state.discord_token, channel, fallback_msg)
    }
  }
}
```

- [ ] **Step 3: Run tests to verify compilation and all pass**

Run: `gleam test`
Expected: All tests pass. The behavioral change is in the runtime path — integration testing happens at deploy.

- [ ] **Step 4: Commit**

```bash
git add src/aura/brain.gleam
git commit -m "feat: brain re-enters tool loop on flare handback"
```

---

### Task 6: Deploy and verify end-to-end

Deploy to production and test the full handback flow.

**Files:**
- No code changes — deploy and integration test

- [ ] **Step 1: Deploy**

Run: `bash scripts/deploy.sh`

- [ ] **Step 2: Clear any stale sessions**

Via Discord, ask Aura to list and kill any stale sessions.

- [ ] **Step 3: Test handback**

In a domain channel, send Aura a task that requires investigation — something the agent can analyze and report on. For example:

> "Understand the current exclusion feature. Spawn a flare to do this for you."

Expected behavior:
1. ACP session starts — progress card appears (existing behavior)
2. Progress updates edit the card in place (existing behavior)
3. **NEW:** When the agent finishes, instead of "ACP Complete [clean] -- Session completed", the brain receives the agent's findings, re-enters the tool loop, and posts a natural-language response summarizing what the agent found.

- [ ] **Step 4: Test fallback (no result text)**

Test with HTTP transport or a scenario where result_text is empty. Should fall back to existing "ACP Complete" message.

- [ ] **Step 5: Commit any fixes**

If issues are found during verification, fix, test, and commit.

---

### Task 7: Update documentation

Update CLAUDE.md and ENGINEERING.md to reflect the handback behavior.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/ENGINEERING.md`

- [ ] **Step 1: Update CLAUDE.md**

In the ACP section of CLAUDE.md, update to reflect that ACP completions now hand back results to the brain. Add to the architecture section:

After the supervision tree, add a note about the ACP completion flow:

```
### ACP Handback

When an ACP session completes (`end_turn`), the event loop captures three layers of results:
- Monitor's cumulative summary (Done field from LLM progress)
- Last 5 tool call names (what the agent did at the end)
- Agent's final message text (the actual conclusion)

These are formatted as a system message, appended to the thread conversation, and the brain re-enters its tool loop — responding to the user naturally with the agent's findings.
```

- [ ] **Step 2: Update system invariants in ENGINEERING.md**

Add invariant to the system invariants section:

```
7. **Handback is never silent.** When an ACP session completes with `end_turn`, the brain always processes the result through the tool loop. If the tool loop fails, the raw result is posted to Discord as a fallback. No completion goes unacknowledged.
```

- [ ] **Step 3: Run tests**

Run: `gleam test`
Expected: All tests pass (docs-only change, sanity check).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/ENGINEERING.md
git commit -m "docs: ACP handback flow and invariant #7"
```
