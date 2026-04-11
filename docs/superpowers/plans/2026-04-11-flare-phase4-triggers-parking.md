# Flare Phase 4: Triggers, Parking, and Rekindling

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flares can be parked (with optional triggers) and rekindled later with full conversation context via Claude Code's `--resume` flag. The scheduler checks for due flare triggers on each tick.

**Architecture:** Three additions: (1) Park/Rekindle messages in flare_manager, (2) `--resume` support in the stdio dispatch path, (3) scheduler integration to check flare triggers. The brain's system prompt includes a roster summary so the LLM knows what flares exist.

**Tech Stack:** Gleam, OTP actors, Claude Code CLI `--resume` flag

**Codebase context:**
- Flare manager: `src/aura/acp/flare_manager.gleam`
- Stdio FFI: `src/aura_acp_stdio_ffi.erl` — `session_init` takes `CommandStr`
- Stdio Gleam: `src/aura/acp/stdio.gleam` — `start_session(command, cwd, prompt)`
- Transport: `src/aura/acp/transport.gleam` — `dispatch_stdio` builds command + calls `stdio.start_session`
- Scheduler: `src/aura/scheduler.gleam` — ticks every 60s, checks `is_due` per entry
- Brain system prompt: `src/aura/brain.gleam:build_system_prompt` and flare context injection

---

### Task 1: Add resume support to stdio dispatch

The transport layer needs to support starting a session with `--resume <session-id>`. Currently `stdio.start_session(command, cwd, prompt)` always starts fresh. For rekindling, we need `start_session_resume(command, cwd, session_id, prompt)` which passes `--resume <session-id>` to the command.

**Files:**
- Modify: `src/aura_acp_stdio_ffi.erl` — add `start_session_resume/5`
- Modify: `src/aura/acp/stdio.gleam` — add `start_session_resume` wrapper
- Modify: `src/aura/acp/transport.gleam` — add `dispatch_stdio_resume` variant
- Test: `test/aura/acp/stdio_ffi_test.gleam` (if there are pure functions to test)

- [ ] **Step 1: Add `start_session_resume` to the Erlang FFI**

In `src/aura_acp_stdio_ffi.erl`, add a new export `start_session_resume/5` and a new function:

```erlang
start_session_resume(Command, Cwd, ResumeSessionId, Prompt, EventPid) ->
    Self = self(),
    OwnerPid = spawn_link(fun() ->
        %% Build command with --resume flag
        ResumeCmd = binary_to_list(iolist_to_binary([Command, " --resume ", ResumeSessionId])),
        session_init(ResumeCmd, Cwd, Prompt, EventPid, Self)
    end),
    receive
        {handshake_ok, OwnerPid, SessionId} ->
            {ok, {OwnerPid, SessionId}};
        {handshake_error, OwnerPid, Reason} ->
            {error, Reason}
    after 30000 ->
        exit(OwnerPid, kill),
        {error, <<"Handshake timeout">>}
    end.
```

Note: `session_init` already handles the full handshake — `--resume` changes Claude Code's behavior internally but the JSON-RPC protocol stays the same. The `session/new` call will return the resumed session ID.

- [ ] **Step 2: Add Gleam wrapper**

In `src/aura/acp/stdio.gleam`:

```gleam
/// Start a stdio ACP session resuming a previous conversation.
/// The --resume flag tells Claude Code to load the previous session's context.
pub fn start_session_resume(
  command: String,
  cwd: String,
  resume_session_id: String,
  prompt: String,
) -> Result(#(SessionOwner, String), String) {
  let self_pid = process.self()
  start_session_resume_ffi(command, cwd, resume_session_id, prompt, self_pid)
}

@external(erlang, "aura_acp_stdio_ffi", "start_session_resume")
fn start_session_resume_ffi(
  command: String,
  cwd: String,
  resume_session_id: String,
  prompt: String,
  event_pid: process.Pid,
) -> Result(#(SessionOwner, String), String)
```

- [ ] **Step 3: Add dispatch_stdio_resume to transport**

In `src/aura/acp/transport.gleam`, add a public function:

```gleam
/// Dispatch a stdio session that resumes a previous conversation.
pub fn dispatch_stdio_resume(
  command: String,
  session_name: String,
  task_spec: types.TaskSpec,
  resume_session_id: String,
  prompt: String,
  monitor_model: String,
  on_event: fn(acp_monitor.AcpEvent) -> Nil,
) -> Result(DispatchResult, String) {
  let reply_subject = process.new_subject()

  process.spawn_unlinked(fn() {
    case stdio.start_session_resume(command, task_spec.cwd, resume_session_id, prompt) {
      Error(e) -> {
        process.send(reply_subject, Error(e))
      }
      Ok(#(owner, session_id)) -> {
        process.send(reply_subject, Ok(#(owner, session_id)))
        on_event(acp_monitor.AcpStarted(session_name, task_spec.domain, task_spec.id))
        let monitor = acp_monitor.start_push_monitor(
          acp_monitor.default_monitor_config(task_spec.timeout_ms),
          session_name,
          task_spec.domain,
          prompt,
          monitor_model,
          on_event,
        )
        stdio_event_loop(session_name, task_spec.domain, on_event, monitor, new_completion_buffer())
      }
    }
  })

  case process.receive(reply_subject, 30_000) {
    Ok(Ok(#(owner, session_id))) ->
      Ok(DispatchResult(
        run_id: session_id,
        handle: StdioHandle(owner: owner, session_id: session_id),
      ))
    Ok(Error(err)) -> Error("Stdio resume failed: " <> err)
    Error(_) -> Error("Stdio resume handshake timed out")
  }
}
```

- [ ] **Step 4: Run tests, commit**

```bash
git add src/aura_acp_stdio_ffi.erl src/aura/acp/stdio.gleam src/aura/acp/transport.gleam
git commit -m "feat: add --resume support to stdio dispatch for flare rekindling"
```

---

### Task 2: Add Park and Rekindle messages to flare_manager

**Files:**
- Modify: `src/aura/acp/flare_manager.gleam`
- Test: `test/aura/acp/flare_manager_test.gleam`

- [ ] **Step 1: Add Park and Rekindle to FlareMsg**

```gleam
  Park(
    reply_to: process.Subject(Result(Nil, String)),
    flare_id: String,
    triggers_json: String,
  )
  Rekindle(
    reply_to: process.Subject(Result(String, String)),
    flare_id: String,
    input: String,
  )
```

- [ ] **Step 2: Add convenience functions**

```gleam
pub fn park(
  subject: process.Subject(FlareMsg),
  flare_id: String,
  triggers_json: String,
) -> Result(Nil, String) {
  process.call(subject, 10_000, fn(reply_to) {
    Park(reply_to:, flare_id:, triggers_json:)
  })
}

pub fn rekindle(
  subject: process.Subject(FlareMsg),
  flare_id: String,
  input: String,
) -> Result(String, String) {
  process.call(subject, 30_000, fn(reply_to) {
    Rekindle(reply_to:, flare_id:, input:)
  })
}
```

- [ ] **Step 3: Implement handle_park**

Park a flare:
1. Find the flare by ID
2. If active with a session, kill the session (let it save state)
3. Update status to Parked
4. Update triggers_json in DB
5. Clear execution ref and session-to-flare mapping

```gleam
fn handle_park(
  state: FlareManagerState,
  flare_id: String,
  triggers_json: String,
) -> #(FlareManagerState, Result(Nil, String)) {
  case dict.get(state.flares, flare_id) {
    Error(_) -> #(state, Error("Flare not found: " <> flare_id))
    Ok(flare) -> {
      // Kill active session if running
      case flare.session_name {
        "" -> Nil
        sn -> {
          let handle = option.unwrap(flare.handle, transport.TmuxHandle)
          let _ = transport.kill(state.transport, handle, sn)
          Nil
        }
      }
      let now = time.now_ms()
      let _ = db.update_flare_status(state.db_subject, flare_id, "parked", now)
      // Update triggers in DB (full upsert with new triggers)
      let updated = FlareRecord(
        ..flare,
        status: Parked,
        triggers_json: triggers_json,
        handle: None,
        updated_at_ms: now,
      )
      let stored = flare_to_stored(updated)
      let _ = db.upsert_flare(state.db_subject, stored)
      // Update in-memory state
      let new_flares = dict.insert(state.flares, flare_id, updated)
      let new_s2f = case flare.session_name {
        "" -> state.session_to_flare
        sn -> dict.delete(state.session_to_flare, sn)
      }
      #(FlareManagerState(..state, flares: new_flares, session_to_flare: new_s2f), Ok(Nil))
    }
  }
}
```

- [ ] **Step 4: Implement handle_rekindle**

Rekindle a parked/archived/failed flare:
1. Find the flare by ID
2. Must not be Active (guard)
3. If session_id exists, dispatch with `--resume`
4. If no session_id, dispatch fresh with original prompt + input appended
5. Update status to Active

```gleam
fn handle_rekindle(
  state: FlareManagerState,
  flare_id: String,
  input: String,
) -> #(FlareManagerState, Result(String, String)) {
  case dict.get(state.flares, flare_id) {
    Error(_) -> #(state, Error("Flare not found: " <> flare_id))
    Ok(flare) -> {
      case flare.status {
        Active -> #(state, Error("Flare is already active: " <> flare_id))
        _ -> {
          // Check concurrency
          let active_count = dict.values(state.flares)
            |> list.filter(fn(f) { f.status == Active })
            |> list.length
          case active_count >= state.max_concurrent {
            True -> #(state, Error("Max concurrent flares reached"))
            False -> {
              // Build task spec from stored flare data
              let task_spec = acp_types.TaskSpec(
                id: flare_id,
                domain: flare.domain,
                prompt: input,
                cwd: flare.workspace,
                timeout_ms: 30 * 60_000,
                acceptance_criteria: [],
                provider: provider.ClaudeCode,
                worktree: False,
              )
              let session_name = tmux.build_session_name(flare.domain, flare_id)
              let on_event = fn(event) {
                process.send(state.self_subject, MonitorEvent(event))
              }

              // Dispatch with resume if we have a session_id, otherwise fresh
              let dispatch_result = case flare.session_id {
                "" -> transport.dispatch(state.transport, session_name, task_spec, state.monitor_model, on_event)
                sid -> case state.transport {
                  transport.Stdio(command) ->
                    transport.dispatch_stdio_resume(command, session_name, task_spec, sid, input, state.monitor_model, on_event)
                  _ -> transport.dispatch(state.transport, session_name, task_spec, state.monitor_model, on_event)
                }
              }

              case dispatch_result {
                Ok(result) -> {
                  let now = time.now_ms()
                  let updated = FlareRecord(
                    ..flare,
                    status: Active,
                    session_name: session_name,
                    session_id: case result.run_id { "" -> flare.session_id _ -> result.run_id },
                    handle: Some(result.handle),
                    updated_at_ms: now,
                  )
                  let _ = db.update_flare_status(state.db_subject, flare_id, "active", now)
                  let _ = db.update_flare_session_id(state.db_subject, flare_id, updated.session_id, now)
                  let new_flares = dict.insert(state.flares, flare_id, updated)
                  let new_s2f = dict.insert(state.session_to_flare, session_name, flare_id)
                  #(FlareManagerState(..state, flares: new_flares, session_to_flare: new_s2f), Ok(session_name))
                }
                Error(e) -> #(state, Error("Rekindle dispatch failed: " <> e))
              }
            }
          }
        }
      }
    }
  }
}
```

- [ ] **Step 5: Wire into message handler**

Add Park and Rekindle cases to the main `handle_message` function.

- [ ] **Step 6: Add flare_to_stored helper if not present**

A helper to convert `FlareRecord` to `db.StoredFlare` for upsert.

- [ ] **Step 7: Add park/rekindle actions to the flare tool**

In `src/aura/brain_tools.gleam`, add `"park"` and `"rekindle"` cases to the flare tool:

```gleam
        "park" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(session_name) -> {
              case flare_manager.get_session(ctx.acp_subject, session_name) {
                Ok(flare) -> {
                  let triggers = get_arg(args, "triggers")
                  case flare_manager.park(ctx.acp_subject, flare.id, triggers) {
                    Ok(_) -> TextResult("Flare parked: " <> flare.label)
                    Error(e) -> TextResult("Error: " <> e)
                  }
                }
                Error(_) -> TextResult("Flare not found: " <> session_name)
              }
            }
          }
        }
        "rekindle" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(session_name) -> {
              case flare_manager.get_session(ctx.acp_subject, session_name) {
                Ok(flare) -> {
                  let input = get_arg(args, "prompt")
                  case flare_manager.rekindle(ctx.acp_subject, flare.id, input) {
                    Ok(new_session) -> TextResult("Flare rekindled: " <> new_session)
                    Error(e) -> TextResult("Error: " <> e)
                  }
                }
                Error(_) -> TextResult("Flare not found: " <> session_name)
              }
            }
          }
        }
```

Update the tool definition to include `park` and `rekindle` in the action enum description.

- [ ] **Step 8: Run tests, commit**

```bash
git add src/aura/acp/flare_manager.gleam src/aura/brain_tools.gleam test/aura/acp/flare_manager_test.gleam
git commit -m "feat: park and rekindle flares with --resume support"
```

---

### Task 3: Scheduler integration for flare triggers

When a flare is parked with schedule/delay triggers, the scheduler should check them on each tick.

**Files:**
- Modify: `src/aura/scheduler.gleam`
- Modify: `src/aura/supervisor.gleam`

- [ ] **Step 1: Add flare trigger checking to the scheduler**

The scheduler needs access to the flare_manager subject. Add it to `SchedulerState`:

```gleam
pub type SchedulerState {
  SchedulerState(
    entries: List(ScheduleEntry),
    skills: List(skill.SkillInfo),
    on_finding: fn(notification.Finding) -> Nil,
    on_rekindle: fn(String, String) -> Nil,  // fn(flare_id, trigger_context) -> Nil
    config_path: String,
    self_subject: process.Subject(SchedulerMessage),
  )
}
```

Add a `CheckFlareTriggers` message that the flare_manager can respond to, OR have the scheduler call the flare_manager directly. Simpler: give the scheduler a callback `on_rekindle(flare_id, trigger_context)` that the supervisor wires to the brain (which then rekindles the flare).

On each Tick, after checking schedule entries, the scheduler also checks flare triggers:
1. Get all parked flares with non-empty triggers from flare_manager
2. For each, parse the trigger JSON
3. Check if any schedule/delay trigger is due
4. If due, call `on_rekindle(flare_id, "Scheduled trigger fired")`

- [ ] **Step 2: Add ListParkedWithTriggers to flare_manager**

A message that returns parked flares with non-empty trigger JSON:

```gleam
  ListParkedWithTriggers(
    reply_to: process.Subject(List(FlareRecord)),
  )
```

- [ ] **Step 3: Wire in supervisor**

Pass the flare_subject to the scheduler (or a callback that calls flare_manager.rekindle through the brain).

- [ ] **Step 4: Run tests, commit**

```bash
git add src/aura/scheduler.gleam src/aura/supervisor.gleam src/aura/acp/flare_manager.gleam
git commit -m "feat: scheduler checks flare triggers on each tick"
```

---

### Task 4: Roster summary in brain system prompt

**Files:**
- Modify: `src/aura/brain.gleam`

- [ ] **Step 1: Build roster summary**

In `build_llm_context` or `handle_with_llm`, after building the system prompt, add a roster section:

```gleam
  let flares = flare_manager.list_flares(state.acp_subject)
  let active_flares = list.filter(flares, fn(f) { f.status == flare_manager.Active })
  let parked_flares = list.filter(flares, fn(f) { f.status == flare_manager.Parked })
  let roster_section = case list.length(active_flares) + list.length(parked_flares) {
    0 -> ""
    _ -> {
      let active_lines = list.map(active_flares, fn(f) {
        "- \"" <> f.label <> "\" (" <> f.domain <> ") — active, session: " <> f.session_name
      })
      let parked_lines = list.map(parked_flares, fn(f) {
        "- \"" <> f.label <> "\" (" <> f.domain <> ") — parked"
      })
      "\n\n## Flare Roster"
      <> case active_lines { [] -> "" lines -> "\nActive:\n" <> string.join(lines, "\n") }
      <> case parked_lines { [] -> "" lines -> "\nParked:\n" <> string.join(lines, "\n") }
      <> "\n\nUse flare(action='rekindle', ...) to resume a parked flare. Use flare(action='ignite', ...) to start new work."
    }
  }
```

- [ ] **Step 2: Run tests, commit**

```bash
git add src/aura/brain.gleam
git commit -m "feat: roster summary in brain system prompt"
```

---

### Task 5: Deploy and verify

- [ ] **Step 1: Deploy**

Run: `bash scripts/deploy.sh`

- [ ] **Step 2: Test park/rekindle**

1. Ignite a flare
2. Park it after completion
3. Rekindle it with new input
4. Verify the agent has context from the previous session

- [ ] **Step 3: Test trigger**

1. Park a flare with a delay trigger (rekindle in 2 minutes)
2. Wait for the scheduler to fire it
3. Verify the flare is rekindled automatically
