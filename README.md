# Aura

**Autonomous Unified Runtime Agent**

A local-first executive assistant framework built in Gleam on the BEAM VM. Runs on your hardware. Manages your domains. Communicates via Discord.

Aura is not a chatbot. It is an opinionated framework for building a personal EA that understands your projects, monitors your tools, and dispatches coding agents on your behalf.

## What It Does

- **Domains** — parallel knowledge partitions (jobs, projects, responsibilities) with isolated memory, state, and instructions
- **Discord interface** — one channel per domain, automatic threading, rich formatting
- **Schedules** — config-driven cron + interval tasks that monitor Jira, calendar, PRs, and Slack
- **ACP** — dispatch Claude Code sessions in tmux, monitor progress in real-time, get structured reports
- **Skills** — language-agnostic CLI tools. Drop a script in a directory, it becomes a skill
- **Active memory** — automatic post-response review persists state and knowledge every N turns
- **Runtime compression** — tiered context management: tool pruning at 50%, LLM summarization at 70%
- **Self-configuration** — create domains, update config, manage identity — all through Discord with propose/approve flow
- **SQLite-backed conversations** — full-text search, compression summaries, multi-platform ready

## Why BEAM

Every component is a supervised OTP actor. The Discord gateway crashing does not take down your ACP sessions. A domain context failing does not block the brain. The supervisor restarts failed actors in milliseconds. No watchdog cron jobs. The runtime is the watchdog.

## Requirements

- [Gleam](https://gleam.run) v1.14+
- Erlang/OTP 27+
- tmux
- A Discord bot token ([create one here](https://discord.com/developers/applications))
- An LLM API key (ZAI/GLM or Anthropic/Claude)
- A Brave Search API key (optional, for web search)

## Quick Start

```bash
git clone https://github.com/melbaldove/aura.git
cd aura
gleam build
gleam run -- init
```

The init command will:
1. Check dependencies
2. Create XDG-compliant directories
3. Prompt for Discord bot token and LLM API key
4. Generate identity files (SOUL.md, USER.md)
5. Generate config.toml

Then start Aura:

```bash
gleam run -- start
```

## Directory Structure

Aura follows the XDG Base Directory specification:

```
~/.config/aura/                    # Configuration
  config.toml                        # Global settings
  SOUL.md                            # Personality and boundaries
  USER.md                            # User profile
  schedules.toml                     # Scheduled tasks
  domains/
    <name>/config.toml               # Per-domain settings
    <name>/AGENTS.md                 # Domain instructions

~/.local/share/aura/               # Data
  aura.db                            # Conversations (SQLite)
  acp-sessions.json                  # ACP session persistence
  events.jsonl                       # Global event log
  skills/
    <name>/SKILL.md                  # Skill definition + optional CLI
  domains/
    <name>/MEMORY.md                 # Durable domain knowledge
    <name>/log.jsonl                 # Domain activity log
    <name>/repos/                    # Project repositories
    <name>/logs/                     # Session logs

~/.local/state/aura/               # Runtime state
  MEMORY.md                          # Global cross-domain memory
  domains/
    <name>/STATE.md                  # Current domain status
```

## Architecture

```
supervisor (OneForOne)
├── db            SQLite actor — serializes all DB reads/writes
├── poller        Discord gateway WebSocket
├── acp_manager   ACP session lifecycle actor — dispatch, monitor, persist
├── brain         Routes messages, LLM tool loop, streaming, memory review
└── scheduler     Config-driven cron + interval schedules
```

Messages flow: Discord → Gateway → Poller → Brain → Domain → LLM → Brain → Discord.

The brain routes by channel (no LLM call needed). Messages in domain channels auto-create threads. Each domain loads its own context (AGENTS.md, STATE.md, MEMORY.md) before reasoning.

## Configuration

See [docs/CONFIG.md](docs/CONFIG.md) for the full configuration reference.

### Global (`~/.config/aura/config.toml`)

```toml
[discord]
token = "${AURA_DISCORD_TOKEN}"
guild = "your-guild-id"
default_channel = "aura"

[models]
brain = "zai/glm-5.1"
domain = "zai/glm-5.1"
acp = "claude/opus"
heartbeat = "zai/glm-5-turbo"
monitor = "zai/glm-5-turbo"

[notifications]
digest_windows = ["07:35", "09:10", "11:10", "15:00"]
timezone = "Asia/Manila"
urgent_bypass = true

[acp]
global_max_concurrent = 4

[memory]
review_interval = 10
notify_on_review = true
```

### Domain (`~/.config/aura/domains/<name>/config.toml`)

```toml
name = "my-project"
description = "Backend API. Rust. Jira board MP."
cwd = "~/.local/share/aura/domains/my-project"
tools = ["jira", "google"]

[discord]
channel = "my-project"
```

Create a domain through Discord (Aura uses the `self-configure` skill and the propose flow) or manually create the config files.

## Skills

Skills are directories in `~/.local/share/aura/skills/<name>/` with a `SKILL.md` file and optional CLI entrypoint.

```bash
mkdir -p ~/.local/share/aura/skills/my-tool
# Write SKILL.md with instructions
# Optionally add a CLI script (referenced in SKILL.md frontmatter)
```

Aura can also create and update skills automatically through the skill review system.

## ACP (Autonomous Claude Protocol)

Tell Aura to fix a bug or implement a feature. It spawns Claude Code in a tmux session with worktree isolation, monitors progress, and reports structured updates back to Discord.

```
You (in #my-project): investigate and fix the login timeout bug HY-5339
Aura: ACP dispatched.
      ACP session started: acp-my-project-t1775618752766
      Attach with: tmux attach -t acp-my-project-t1775618752766

      📋 **Investigate login timeout HY-5339** · 8m elapsed
      `acp-my-project-t1775618752766`

      **Status:** Working
      **Done:** Found root cause in `AuthService.swift:142`
      **Current:** Implementing fix
      **Needs input:** none
      **Next:** Create PR
```

## License

MIT
