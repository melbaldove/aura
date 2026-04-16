# AURA(1) — Operations Manual

> This document describes how Aura operates. It is read by humans to understand
> Aura's behavior, and by Aura's brain to understand itself. If this document
> contradicts observed behavior, the document is wrong — update it.

## NAME

Aura — autonomous assistant on BEAM that orchestrates work through persistent
flares, scheduled tasks, and domain-partitioned knowledge.

## SYNOPSIS

```
gleam run -- start       # Run the agent
gleam run -- init        # First-run setup
bash scripts/deploy.sh   # Deploy to Eisenhower
```

## DESCRIPTION

Aura is an OTP application. Every component is a supervised actor. The brain
receives Discord messages, routes them to domains, runs an LLM tool loop, and
dispatches flares for work that requires a coding agent. Memory, state, and
conversation history persist across restarts via SQLite and structured markdown
files.

Aura runs on Eisenhower (192.168.50.140) as a launchd service
(`com.aura.agent`). It communicates via Discord.

### Supervision tree

```
supervisor (OneForOne)
├── db               SQLite actor — serialized reads/writes
├── poller           Discord gateway WebSocket
├── flare_manager    Flare lifecycle — roster, dispatch, monitor, persist
├── brain            Message routing, LLM tool loop, streaming, handback
└── scheduler        Config-driven cron + interval schedules
```

All actors restart independently. A crash in one does not affect the others.

## SUBSYSTEMS

### Flares

A flare is a persistent extension of Aura — a coding agent session dispatched
to do work. Flares have identity that survives beyond any single process.

**States:** `Active` → `Parked` | `Archived` | `Failed(reason)`

**Lifecycle:**

| Event | What happens |
|-------|-------------|
| Ignite | New flare record created in SQLite. Fresh ACP session. |
| Dispatch | ACP process spawned. Session linked to flare. |
| Turn complete (`end_turn`) | Handback fires. Flare stays Active. Session stays alive. Brain may send follow-up prompts. |
| Process exit (code 0) | `AcpCompleted`. Flare archived. |
| Process exit (non-zero) | `AcpFailed`. Flare marked failed. |
| Park | Session killed. Flare persists with optional triggers. Can be rekindled. |
| Rekindle | New session dispatched with `--resume` to load prior conversation. Flare stays same ID. |
| Kill | Session killed. Flare marked `Failed(killed)`. |
| Timeout | Monitor timeout fires. Flare marked `Failed(timed_out)`. |

**What kills a flare's session:**
- Deploy/restart — the BEAM process stops, all Erlang ports (child processes) die with it
- Explicit kill via flare tool
- Park command
- Timeout

**What survives a deploy:**
- Flare records in SQLite (id, label, status, session_id, prompt, domain)
- Claude Code session history on disk (`~/.claude/projects/.../<session_id>.jsonl`)
- Nothing else. The ACP process, event loop, monitors — all gone.

**Recovery on restart:**
- `load_flares` reads non-archived flares from SQLite
- Active flares with dead sessions → auto-rekindle with `--resume <session_id>`, staggered at 3s + idx*2s
- Parked flares → loaded into memory, no session started
- The `--resume` flag tells Claude Code to load the prior conversation from the JSONL file

**Rekindle vs Ignite:**
- **Rekindle** preserves conversation history via `--resume`. Use when continuing the same work.
- **Ignite** starts a fresh session with no prior context. Use for new work only.
- Never kill + ignite when the work is the same. Rekindle instead.

**Handback:**
When an ACP session completes a turn (`end_turn`), the brain receives the agent's
results (last 5 tool names + agent's final text + monitor summary), appends them
as a system message to the thread conversation, and re-enters the tool loop.
The brain responds naturally with the findings. If the tool loop fails, the raw
result is posted as a fallback. Handback is never silent.

**Diagnostics:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Flare not found" | Looking up by old session name. Session names change on rekindle. | Use flare ID (`f-...`) or label instead. |
| "refused by user" / writes blocked | ACP permissions not configured. | Ensure `~/.claude/settings.json` has `permissions.defaultMode: "bypassPermissions"` and tool allow list. |
| Flare idle after restart | Recovery rekindled with generic prompt. Agent didn't understand task. | The `--resume` loads prior conversation. Brain should send specific follow-up if needed. |
| "event for unknown session" | Event arrived after flare was archived. Race between archival and late events. | Harmless warning. Lookup fallback handles it. |
| Context lost on rekindle | Brain killed and re-ignited instead of rekindling. | Rekindle preserves context. Ignite does not. |
| Multiple "ACP Started" messages | Same flare dispatched twice (original + rekindle). | Normal after restart. Could be improved with message cleanup. |

### Domains

A domain is a knowledge partition — an area of the user's work. Each domain
has its own config, context, memory, state, and Discord channel. Domains are
context selectors, not capability boundaries. All tools are available in all
channels.

**Directory layout (XDG):**
```
~/.config/aura/domains/<name>/     Config: AGENTS.md, config.toml
~/.local/share/aura/domains/<name>/  Data: MEMORY.md, log.jsonl, repos/
~/.local/state/aura/domains/<name>/  State: STATE.md
```

**Routing:** Brain routes by `channel_id` → domain name. Messages in a domain's
channel load that domain's context. Messages in #aura get global context only.

### Memory

Three structured memory targets, all keyed by topic (`§ key\ncontent`):

| Target | Scope | Path | Purpose |
|--------|-------|------|---------|
| `state` | Per-domain | `~/.local/state/aura/domains/<name>/STATE.md` | Current status. Active tickets, PRs, blockers. |
| `memory` | Per-domain | `~/.local/share/aura/domains/<name>/MEMORY.md` | Durable knowledge. Decisions, patterns, conventions. |
| `user` | Global | `~/.config/aura/USER.md` | User profile. Preferences, role, communication style. |

**Invariant:** Only the brain writes memory. Flares report findings back.
The brain decides what to persist after reviewing results. Flare prompts must
never instruct the agent to write to MEMORY.md, STATE.md, or USER.md.

**Active review:** Every 10 conversation turns, background processes auto-persist
state and knowledge observations.

### Conversations

Per-channel message history. In-memory buffer (hot cache) backed by SQLite.
Keyed by `(platform, platform_id)` — multi-platform ready.

**Compression:** Tiered auto-compression approaching context limits:
- 50% of context window: tool output pruning (free)
- 70% of context window: full LLM summarization

Summaries persist in the DB `compaction_summary` column, restored on session reload.

### Skills

A skill is a directory with `SKILL.md` (instructions) and optional CLI
entrypoint. Instruction-only skills teach the LLM; external skills are invoked
as subprocesses.

**Location:** `~/.local/share/aura/skills/`

**Usage:** Brain calls `view_skill` to read instructions before `run_skill`.
Skills can be created/updated by brain via `create_skill`.

### Schedules

Config-driven periodic tasks in `~/.config/aura/schedules.toml`. Each schedule
invokes a skill on an interval or cron expression, classifies urgency via LLM,
and emits findings to the domain's Discord channel.

**Supported formats:**
- Fixed interval: `"15m"`, `"1h"`
- Cron expression: `"0 9 * * *"`

Scheduler also checks parked flares with triggers on each 60s tick.

### Vision

Two-model pipeline: vision model describes the image, orchestrator model runs
the tool loop with the enriched message.

Config is tiered: domain `config.toml` overrides global overrides built-in
defaults. `[models] vision` sets the model, `[vision] prompt` sets the
description prompt.

### Shell

General-purpose shell execution tool (`/bin/sh -c`). Supports pipes, redirects,
and full shell syntax. Used for: man pages, git operations, process inspection,
file search, system diagnostics.

**Security pipeline:**

```
command → normalize → fast regex reject → content scan → [approval] → execute
```

1. **Normalize:** Strip ANSI escapes, null bytes, NFKC normalization.
2. **Fast reject:** 41 pre-compiled dangerous command patterns checked via single
   union regex. Categories: destructive ops, SQL, system commands, remote code
   execution, filesystem writes, git history rewriting, Aura self-protection.
3. **Content scan:** Homograph detection for URLs in curl/wget commands.
4. **Approval:** Flagged commands posted to Discord with approve/reject buttons.
   Blocks until user responds (15 min timeout).
5. **Execute:** `/bin/sh -c` with cwd from domain context. Output truncated at
   50K chars (40% head, 60% tail). Timeout default 180s, max 600s.

**Self-protection patterns:**

Commands that could kill the BEAM VM, delete the SQLite database, remove XDG
directories, modify the launchd service, or kill tmux sessions with active
flares are always flagged.

**Diagnostics:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Command rejected by user" | User clicked reject on approval | Normal — command was flagged as dangerous |
| "Approval timed out" | No user response within 15 minutes | User wasn't watching Discord |
| Safe command flagged | False positive in pattern list | Review pattern in `shell.gleam:dangerous_patterns()` |
| Shell output truncated | Output exceeded 50K chars | Normal — head and tail preserved |

## CONFIGURATION

### config.toml

Location: `~/.config/aura/config.toml`

```toml
[discord]
token = "${AURA_DISCORD_TOKEN}"    # Discord bot token
guild = "916608356586778655"       # Discord server ID
default_channel = "aura"          # Fallback channel name

[models]
brain = "zai/glm-5.1"             # Orchestrator model
acp = "claude/opus"               # Flare coding model (unused for stdio)
monitor = "zai/glm-5-turbo"       # Progress summarizer
vision = "zai/glm-4.6v"           # Image description model

[acp]
global_max_concurrent = 4         # Max simultaneous flares
transport = "stdio"               # "stdio" | "http" | "tmux"
command = "claude-agent-acp"      # Binary for stdio transport

[memory]
review_interval = 10              # Turns between auto-review
notify_on_review = true           # Post review findings to Discord

[notifications]
digest_windows = ["07:35", "09:10", "11:10", "15:00"]
timezone = "Asia/Manila"
urgent_bypass = true
```

### Claude Code permissions

Location: `~/.claude/settings.json` on the host running `claude-agent-acp`.

Required for headless ACP sessions (flares) to write files:

```json
{
  "permissions": {
    "allow": ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "WebFetch", "WebSearch"],
    "defaultMode": "bypassPermissions"
  }
}
```

**Why:** `claude-agent-acp` does not support `--permission-mode` CLI flags.
Permissions are controlled exclusively through settings files. Without
`bypassPermissions`, the agent auto-denies file writes in headless mode —
the `session/request_permission` JSON-RPC auto-approve in the FFI only handles
the UI prompt layer, not the internal permission evaluation.

**Symptom if missing:** Monitor reports "refused by user" or "write blocked".
The agent is not being refused by any user — the permission system is denying
the tool before it reaches the ACP protocol layer.

### Domain config

Location: `~/.config/aura/domains/<name>/config.toml`

```toml
name = "cm2"
description = "CM2 project"
cwd = "/path/to/repos"
channel = "1234567890"

[acp]
provider = "claude-code"    # "claude-code" | "generic"
worktree = true             # Use git worktrees for flares
```

### Environment variables

| Variable | Purpose |
|----------|---------|
| `AURA_DISCORD_TOKEN` | Discord bot token |
| `ZAI_API_KEY` | z.ai/GLM API key |
| `ANTHROPIC_API_KEY` | Anthropic API key (for ACP) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code auth (from `claude setup-token`) |
| `BRAVE_API_KEY` | Brave Search API key (optional) |
| `HOME` | XDG path resolution |

Configured in launchd plist: `~/Library/LaunchAgents/com.aura.agent.plist`

### Deploy

**Always use `bash scripts/deploy.sh`.** Never manual scp+build.

The script:
1. rsync source `.gleam` and `.erl` files to Eisenhower
2. `gleam clean && gleam build` — no stale beams
3. Fix esqlite NIF — `gleam clean` wipes it, OTP 27+ needs `erlc` recompile
4. Recompile Erlang FFI beams — `gleam build` doesn't compile `.erl` files
5. `launchctl kickstart -k` restarts the service
6. Wait 5s, tail log to verify

**What a deploy does to flares:**
- All stdio ACP processes die (they're child processes of Erlang ports)
- On restart, active flares auto-rekindle with `--resume` (staggered)
- Parked flares reload from SQLite unchanged
- The deploy script never kills tmux sessions — tmux flares survive

## FILES

| Path | Purpose |
|------|---------|
| `~/.config/aura/config.toml` | Global configuration |
| `~/.config/aura/SOUL.md` | Aura's identity and role |
| `~/.config/aura/USER.md` | User profile (global) |
| `~/.config/aura/domains/<name>/` | Domain config directories |
| `~/.config/aura/schedules.toml` | Scheduled task definitions |
| `~/.local/share/aura/aura.db` | SQLite database (conversations, flares, FTS) |
| `~/.local/share/aura/skills/` | Skill directories |
| `~/.local/share/aura/domains/<name>/MEMORY.md` | Domain knowledge |
| `~/.local/state/aura/domains/<name>/STATE.md` | Domain current status |
| `~/.claude/settings.json` | Claude Code permissions (on host) |
| `~/.claude/projects/.../<session_id>.jsonl` | Claude Code session history |
| `/tmp/aura.log` | Runtime log (on Eisenhower) |
| `~/Library/LaunchAgents/com.aura.agent.plist` | launchd service config |

## DIAGNOSTICS

Cross-cutting symptoms that span subsystems.

| Symptom | Cause | Investigation |
|---------|-------|---------------|
| Bot not responding | Gateway disconnected, brain crashed, or service down | Check `/tmp/aura.log` for crash or heartbeat timeout |
| "Sorry, I crashed while processing" | Tool loop exception in brain | Check log for the stack trace. Brain restarts automatically. |
| Flare writes blocked | `~/.claude/settings.json` missing permission config | See Configuration → Claude Code permissions |
| Flare loses context after restart | Normal — stdio sessions die with BEAM. `--resume` reloads conversation. | Not a "model switch". Check if session_id was persisted. |
| Scheduled task failing | Skill exited non-zero, or API token expired | Log shows `[scheduler] <name> failed:` with error |
| "Token has been expired or revoked" | Google OAuth refresh token expired | Re-authenticate: `! google auth` in Aura CLI |
| Orphan `claude-agent-acp` processes | Sessions from killed/archived flares not cleaned up | `ps aux \| grep claude-agent-acp` — kill stale processes |
| "Actor discarding unexpected message" | Message sent to wrong process or after process restarted | Harmless. Usually a stale reply_to subject from recovery. |
| Conversation context missing | Compression pruned it, or conversation not loaded from DB | Check if channel has conversation in SQLite |
| Discord typing indicator stuck | Typing loop process not killed after response | Brain should kill typing process. If stuck, it clears after ~10s. |

## LIMITATIONS

- Stdio ACP sessions die on deploy. Conversation is preserved via `--resume`
  but the process and all in-flight work is lost.
- No graceful shutdown — process stops on SIGTERM. SQLite WAL handles crash recovery.
- Brain is single-threaded — one message at a time. Flares run in parallel
  but handback processing is sequential.
- Streaming tool call parsing is manual JSON extraction — fragile for non-standard APIs.
- Discord only — Telegram/Slack gateway modules not yet built (schema ready).
- `claude-agent-acp` does not support CLI permission flags. Permissions
  must be configured via `~/.claude/settings.json`.
- Orphan `claude-agent-acp` processes accumulate. No automated cleanup.

## MAINTENANCE

This document must stay accurate. It is loaded by the brain for self-diagnosis.
Stale documentation is worse than no documentation — the brain will confidently
act on wrong information.

Rules:
1. Update on change, same commit. Not retroactively.
2. Diagnostics come from bugs. Every new failure mode gets a row.
3. Delete before you add. Don't append "NOTE: no longer true."
4. Configuration is verified, not assumed. Test before documenting.
5. A pre-commit hook (Haiku agent) checks if this document needs updating.

## SEE ALSO

- `docs/ENGINEERING.md` — Design principles and system invariants
- `docs/decisions/` — Architecture Decision Records
- `CLAUDE.md` — Developer guide for working on the codebase
- `ARCHITECTURE.md` — Code-level architecture (may be stale — this document is authoritative)
