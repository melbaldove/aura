# Aura Roadmap

Living document. Updated as we brainstorm and ship.

## Competitive Context

Hermes Agent (22K stars): 4-layer memory, periodic nudge every 10 turns, skill self-improvement, 6 platform gateway, headless via systemd + API keys.

OpenClaw (345K stars): 5,700+ skills, 30+ channels, Docker-first, orchestrator + subagent model, $59/mo managed cloud.

Claude Code: Best raw coding (80.8% SWE-bench), 30h autonomous tasks, but weakest native memory, OAuth headless issues.

Aura's edge: OTP fault tolerance, domain model (knowledge partitions), ACP dispatch (coding delegation with monitoring), local-first.

## Priority Fixes

### P0: Active Memory (closes biggest gap with Hermes)

**Status:** Shipped (April 9, 2026)

**Problem:** Aura's memory is passive — only saves when the LLM decides to call the memory tool. Hermes has a closed learning loop with a periodic nudge that spawns a background review agent every 10 turns.

**Hermes implementation (from code audit):**
- Turn counter fires every 10 turns
- Spawns a forked agent in background thread with same model + tools + conversation history
- Memory review prompt: "Review the conversation above. Has the user revealed things about themselves? Has the user expressed expectations about behavior? Save if appropriate, otherwise say 'Nothing to save.'"
- Skill review prompt: "Was a non-trivial approach used that required trial and error? If a relevant skill exists, update it. Otherwise create a new skill if reusable."
- Review agent has max_iterations=8, quiet_mode=True
- Results shown to user as "💾 {summary}"

**Our approach (hybrid, smarter than Hermes):**
- NOT a dumb turn counter — trigger on significant tool use (3+ tool calls, or specific tools: acp_dispatch, acp_kill, memory set, run_skill, ticket transitions)
- Spawn in `process.spawn_unlinked` after tool loop completes
- Separate state review (what changed?) from memory review (what was learned?)
- Tool-triggered auto-saves for mechanical state (ACP dispatch → STATE.md, no LLM needed)
- Skill auto-revision after run_skill encounters workarounds
- Results logged, NOT shown in Discord (user's cognitive load is high)
- Uses cheap monitor model, not the brain model

**Design decisions (finalized):**

1. **Full conversation history** — same as Hermes. The review agent needs the arc of the conversation to judge what's worth saving. "Fixed the bug" means nothing without context. Uses the cheap monitor model (glm-5-turbo) so cost is negligible.

2. **Max 8 iterations, memory tool only** — same cap as Hermes. Review agent only has access to the `memory` tool (set/remove/read on state and memory targets). No skill creation, no file writes, no ACP. `quiet_mode` equivalent: no Discord output. Nudges disabled on the review agent (no recursion).

3. **Two parallel spawns** — state review ("what changed?") and memory review ("what was learned?") run as independent processes via `process.spawn_unlinked`. Better isolation than Hermes's single-spawn sequential approach. No prompt caching benefit to preserve anyway (glm-5-turbo on z.ai doesn't cache prefixes). BEAM makes parallel spawns trivial.

4. **Structured log to domain log.jsonl, no retry** — entries: `{"type": "review_completed", "domain": "hy", "review_type": "state", "entries_written": 2, "ts": ...}` and `{"type": "review_failed", "domain": "hy", "review_type": "memory", "error": "...", "ts": ...}`. Queryable trail of success rates per domain. Better than Hermes which silently swallows with `except: pass`.

---

### P1: Runtime Conversation Compression

**Status:** Not started

**Problem:** Compressor exists but only runs on load. If conversations grow past context limits mid-session, the LLM degrades silently. No auto-cleanup or notification.

**Fix:** After each turn, check total token estimate. If >50% of context window, trigger compression. The compressor already exists — just needs a runtime trigger in the tool loop.

---

### P2: Cross-Domain Routing

**Status:** Not started

**Problem:** Can't say "@hy check ticket status" from #aura. Each channel is a silo. No explicit domain override.

**Fix:** Parse `@domain` prefix from user messages before routing. If present, override the channel-based route. Simple string check before `route_message`.

---

### P3: Better Monitor UX

**Status:** Shipped (April 9, 2026)

**Problem:** Idle sessions take 6 minutes to surface. No structured progress. No proactive user nudges. Progress summaries are unreadable.

**Fix:**
- Structured progress format: files changed, current step, % estimate
- Faster idle detection (3 checks not 6)
- Proactive "session appears stuck, want me to check?" after 2 idle surfaces
- Markdown formatting for Discord readability

---

### P4: Second Gateway (Telegram)

**Status:** Not started

**Problem:** Discord only. Schema supports multi-platform but no second gateway exists.

**Hermes approach:** Single gateway process with platform adapters. Each adapter implements send/receive. Message handler is platform-agnostic. Session key includes platform prefix.

**Fix:** Add Telegram adapter. The conversation DB already supports `platform: "telegram"`. Need: Telegram bot API client, message adapter, gateway routing.

---

## Friction Points (from code audit)

### Architectural
- Brain monolith (20 fields in BrainState) — no clean separation of concerns
- Streaming JSON parsing is manual and fragile (brain.gleam:907)
- Memory writes block the brain actor (synchronous file I/O)

### Operational
- Discord message edits are fire-and-forget (no error logging on 400s) — PARTIALLY FIXED (truncation added)
- Tool argument parse errors are generic ("failed to parse") with no schema hints
- Monitor "idle" is a progress event, not a state transition — no escalation path

### User Experience
- No conversation compression notification — user doesn't know context is degrading
- Vision preprocessing is all-or-nothing with no timeout indication
- GLM-5.1 still invents tool names when batching — FIXED (skill name redirect)

## Shipped (this session, April 8-9, 2026)

- [x] Skill name redirect — GLM-5.1 batching bug auto-redirects unknown tool names to run_skill
- [x] Discord 2000 char truncation — no more 400 errors from oversized messages
- [x] Max tool iterations — 20 → 40
- [x] Keyed memory entries — upsert by key, no old_text guessing, parallel-safe
- [x] list_directory domains fix — resolves against config domains dir
- [x] XDG path separation — config/data/state properly separated, ~/domains/ eliminated
- [x] workspace.gleam → scaffold.gleam rename
- [x] AcpManager actor refactor — single owner of session lifecycle, no stale copies
- [x] Dead code cleanup — removed monitor.start/start_recovery
- [x] Principle #12 fixes — logged silent errors in tool call parsing, session store, kill
- [x] Linked spawn fix — Discord sends use spawn_unlinked to avoid brain crashes
- [x] Claude Code auth — setup-token in launchd plist, no more daily logouts
- [x] scaffold_domain XDG fix — STATE.md in state dir, MEMORY.md in data dir, repos/ dir
- [x] META.md template updated to reflect current XDG layout
- [x] Active memory review (P0) — post-response review spawns parallel state + memory processes every 10 turns
- [x] chat_with_tools added to llm.gleam — non-streaming LLM call with tool definitions
- [x] MemoryConfig — configurable review_interval and notify_on_review in [memory] section
- [x] Domain path helpers — domain_state_path, domain_memory_path, domain_log_dir centralized in xdg.gleam
- [x] LLM HTTP boilerplate extracted to shared post_chat helper
- [x] structured_memory parse_lines O(n²) → O(n) with reverse accumulation
- [x] Hermes Agent code audit — documented learning loop, memory architecture, skill self-improvement
- [x] ROADMAP.md created — competitive analysis, priority fixes, friction points
