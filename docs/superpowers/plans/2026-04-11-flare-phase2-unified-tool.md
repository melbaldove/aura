# Flare Phase 2: Unified Flare Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 5 ACP tools (`acp_dispatch`, `acp_status`, `acp_list`, `acp_prompt`, `acp_kill`) with a single `flare` tool that routes by action parameter. Same underlying dispatch machinery.

**Architecture:** One tool definition with an `action` enum parameter. The execution function dispatches on the action string to the existing manager functions. The system prompt's ACP context section is updated to reference the flare tool.

**Tech Stack:** Gleam

**Codebase context:**
- Tool definitions live in `src/aura/brain_tools.gleam:make_built_in_tools()` (~line 1048+)
- Tool execution lives in `src/aura/brain_tools.gleam:execute_tool()` (~line 502+)
- ACP system prompt context is in `src/aura/brain.gleam:1509-1519`
- Currently 16 built-in tools, 5 are ACP tools
- CLAUDE.md says "16 built-in tools" — will become 12 (remove 5, add 1)

---

### Task 1: Add the flare tool definition

Replace the 5 ACP tool definitions with one `flare` tool.

**Files:**
- Modify: `src/aura/brain_tools.gleam` (make_built_in_tools function)
- Test: `test/aura/brain_tools_test.gleam`

- [ ] **Step 1: Write the failing test**

Add to `test/aura/brain_tools_test.gleam`:

```gleam
pub fn built_in_tools_include_flare_test() {
  let tools = brain_tools.make_built_in_tools()
  let has_flare = list.any(tools, fn(t) {
    case t {
      llm.ToolDefinition(name: "flare", ..) -> True
      _ -> False
    }
  })
  has_flare |> should.be_true
}

pub fn built_in_tools_no_acp_dispatch_test() {
  let tools = brain_tools.make_built_in_tools()
  let has_acp = list.any(tools, fn(t) {
    case t {
      llm.ToolDefinition(name: "acp_dispatch", ..) -> True
      _ -> False
    }
  })
  has_acp |> should.be_false
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test 2>&1 | grep "built_in_tools_include_flare"`
Expected: FAIL — no `flare` tool exists yet.

- [ ] **Step 3: Replace 5 ACP tool definitions with one flare tool**

In `src/aura/brain_tools.gleam`, in `make_built_in_tools()`, remove the 5 ACP tool definitions (`acp_dispatch`, `acp_status`, `acp_list`, `acp_prompt`, `acp_kill`) and replace with:

```gleam
    llm.ToolDefinition(
      name: "flare",
      description: "Extend yourself to work on a task. Flares are persistent — they can be parked and rekindled later. Actions: ignite (start new), status (check progress), list (show all), prompt (send follow-up), kill (terminate).",
      parameters: [
        llm.ToolParam(
          name: "action",
          param_type: "string",
          description: "One of: ignite, status, list, prompt, kill",
          required: True,
        ),
        llm.ToolParam(
          name: "prompt",
          param_type: "string",
          description: "For ignite: the full task prompt. For prompt: the follow-up message.",
          required: False,
        ),
        llm.ToolParam(
          name: "repo",
          param_type: "string",
          description: "For ignite: repo path relative to domain root (e.g. 'repos/cm2'). Check AGENTS.md.",
          required: False,
        ),
        llm.ToolParam(
          name: "session_name",
          param_type: "string",
          description: "For status/prompt/kill: the session name.",
          required: False,
        ),
        llm.ToolParam(
          name: "timeout_minutes",
          param_type: "string",
          description: "For ignite: max duration in minutes (default 30).",
          required: False,
        ),
      ],
    ),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `gleam test`
Expected: All tests pass including the 2 new ones. Compilation may fail if execute_tool still references old names — that's Task 2.

- [ ] **Step 5: Commit**

```bash
git add src/aura/brain_tools.gleam test/aura/brain_tools_test.gleam
git commit -m "feat: replace 5 ACP tools with unified flare tool definition"
```

---

### Task 2: Route flare actions to existing manager functions

Replace the 5 ACP execution cases in `execute_tool` with one `flare` case that dispatches by action.

**Files:**
- Modify: `src/aura/brain_tools.gleam` (execute_tool function)

- [ ] **Step 1: Replace the 5 ACP cases with one flare case**

In `execute_tool`, remove the cases for `"acp_dispatch"`, `"acp_status"`, `"acp_list"`, `"acp_prompt"`, and `"acp_kill"`. Replace with:

```gleam
    "flare" -> {
      case get_arg(args, "action") {
        "ignite" -> {
          case require_arg(args, "prompt") {
            Error(e) -> TextResult(e)
            Ok(prompt) -> case require_arg(args, "repo") {
              Error(e) -> TextResult(e)
              Ok(repo) -> {
                let task_id = "t" <> int.to_string(time.now_ms())
                let cwd = ctx.domain_cwd <> "/" <> repo
                let timeout_ms = case int.parse(get_arg(args, "timeout_minutes")) {
                  Ok(m) -> m * 60_000
                  Error(_) -> 30 * 60_000
                }
                let task_spec = acp_types.TaskSpec(
                  id: task_id,
                  domain: ctx.domain_name,
                  prompt: prompt,
                  cwd: cwd,
                  timeout_ms: timeout_ms,
                  acceptance_criteria: [],
                  provider: provider.parse_provider(ctx.acp_provider, ctx.acp_binary),
                  worktree: ctx.acp_worktree,
                )
                let thread_id = ctx.channel_id
                case manager.dispatch(ctx.acp_subject, task_spec, thread_id) {
                  Ok(session_name) -> {
                    let details_msg =
                      "Flare ignited: " <> session_name
                      <> "\n\n**Prompt:**\n" <> prompt
                    TextResult("Flare ignited.\n" <> details_msg)
                  }
                  Error(e) -> TextResult("Error: " <> e)
                }
              }
            }
          }
        }
        "status" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(session_name) -> {
              case manager.get_session(ctx.acp_subject, session_name) {
                Ok(session) -> {
                  let elapsed_ms = time.now_ms() - session.started_at_ms
                  let elapsed_min = elapsed_ms / 60_000
                  let state_str = " [" <> manager.session_state_to_string(session.state) <> "] (started " <> int.to_string(elapsed_min) <> "m ago)"
                  case session.run_id {
                    "" -> {
                      case acp_tmux.capture_pane(session_name) {
                        Ok(output) -> {
                          let tail = case string.length(output) > 500 {
                            True -> "...\n" <> string.slice(output, string.length(output) - 500, 500)
                            False -> output
                          }
                          TextResult("Flare: " <> session_name <> state_str <> "\n\n" <> tail)
                        }
                        Error(_) -> TextResult("Flare: " <> session_name <> state_str <> "\n\n(output not available)")
                      }
                    }
                    run_id -> {
                      TextResult("Flare: " <> session_name <> state_str <> "\nRun: " <> run_id <> "\nDomain: " <> session.domain <> "\nPrompt: " <> string.slice(session.prompt, 0, 200))
                    }
                  }
                }
                Error(_) -> TextResult("Flare not found: " <> session_name)
              }
            }
          }
        }
        "list" -> {
          let sessions = manager.list_sessions(ctx.acp_subject)
          case sessions {
            [] -> TextResult("No active flares.")
            _ -> {
              list.map(sessions, fn(s) {
                let elapsed_ms = time.now_ms() - s.started_at_ms
                let elapsed_min = elapsed_ms / 60_000
                s.session_name
                <> " [" <> manager.session_state_to_string(s.state) <> "]"
                <> " domain=" <> s.domain
                <> " (started " <> int.to_string(elapsed_min) <> "m ago)"
              })
              |> string.join("\n")
              |> TextResult
            }
          }
        }
        "prompt" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(session_name) -> case require_arg(args, "prompt") {
              Error(e) -> TextResult(e)
              Ok(message) -> {
                case manager.send_input(ctx.acp_subject, session_name, message) {
                  Ok(_) -> TextResult("Sent to " <> session_name)
                  Error(e) -> TextResult("Error: " <> e)
                }
              }
            }
          }
        }
        "kill" -> {
          case require_arg(args, "session_name") {
            Error(e) -> TextResult(e)
            Ok(session_name) -> {
              case manager.kill(ctx.acp_subject, session_name) {
                Ok(_) -> TextResult("Flare killed: " <> session_name)
                Error(e) -> TextResult("Error: " <> e)
              }
            }
          }
        }
        unknown -> TextResult("Unknown flare action: " <> unknown <> ". Use: ignite, status, list, prompt, kill")
      }
    }
```

Note: the `prompt` action uses `require_arg(args, "prompt")` for the message (not "message") — this reuses the same `prompt` parameter from the tool definition, which serves double duty for ignite (task prompt) and prompt (follow-up message).

- [ ] **Step 2: Run tests to verify compilation and all pass**

Run: `gleam test`
Expected: All 352 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/aura/brain_tools.gleam
git commit -m "feat: route flare actions to existing manager functions"
```

---

### Task 3: Update system prompt ACP context

Change the ACP context section in the brain's system prompt to reference the flare tool.

**Files:**
- Modify: `src/aura/brain.gleam` (~line 1509)

- [ ] **Step 1: Update the ACP context string**

In `src/aura/brain.gleam`, find the section that builds `acp_context` (around line 1509). Change:

```gleam
      "\n\n## Active ACP Session"
      <> "\nYou are in an ACP session thread."
      <> "\nSession: "
      <> session.session_name
      <> "\nState: "
      <> manager.session_state_to_string(session.state)
      <> "\nDomain: "
      <> session.domain
      <> "\nTask: "
      <> string.slice(session.prompt, 0, 300)
      <> "\n\nUse acp_status to check progress, acp_prompt to send instructions, acp_list to see all sessions."
```

To:

```gleam
      "\n\n## Active Flare"
      <> "\nYou are in a flare thread."
      <> "\nSession: "
      <> session.session_name
      <> "\nState: "
      <> manager.session_state_to_string(session.state)
      <> "\nDomain: "
      <> session.domain
      <> "\nTask: "
      <> string.slice(session.prompt, 0, 300)
      <> "\n\nUse flare(action='status', session_name='...') to check progress, flare(action='prompt', ...) to send instructions, flare(action='list') to see all flares."
```

- [ ] **Step 2: Run tests**

Run: `gleam test`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/aura/brain.gleam
git commit -m "feat: update system prompt to reference flare tool"
```

---

### Task 4: Update CLAUDE.md tool count

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update tool count**

In CLAUDE.md, find "16 built-in tools" and change to "12 built-in tools" (removed 5 ACP tools, added 1 flare tool).

Also update the tool system section description if it mentions ACP tools specifically.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update tool count — 5 ACP tools replaced by 1 flare tool"
```

---

### Task 5: Deploy and verify

- [ ] **Step 1: Deploy**

Run: `bash scripts/deploy.sh`

- [ ] **Step 2: Test flare tool**

In Discord, ask Aura to list flares, then ignite one. Verify the tool is being called correctly and the LLM uses the new `flare` tool name.

- [ ] **Step 3: Commit any fixes**
