# Aura

**Autonomous Unified Runtime Agent**

A local-first executive assistant framework built in Gleam on the BEAM VM. Runs on your hardware. Manages your workstreams. Communicates via Discord.

Aura is not a chatbot. It is an opinionated framework for building a personal EA that understands your projects, monitors your tools, and dispatches coding agents on your behalf.

## What It Does

- **Workstreams** — parallel work contexts (jobs, projects, personal tasks) with isolated memory, tools, and LLM reasoning
- **Discord interface** — one channel per workstream, implicit routing, rich formatting
- **Heartbeat** — independent check actors monitor Jira, calendar, PRs, and Slack on configurable intervals
- **ACP** — dispatch Claude Code sessions in tmux, monitor them in real-time, get structured reports back
- **Skills** — language-agnostic CLI tools. Drop a script in a directory, it becomes a skill
- **File-based memory** — markdown, TOML, JSONL. Portable, human-readable, git-trackable. No database

## Why BEAM

Every component is a supervised OTP actor. The Discord poller crashing does not take down your heartbeat checks. A workstream hanging does not block the brain. The supervisor restarts failed actors in milliseconds. No watchdog cron jobs. The runtime is the watchdog.

## Requirements

- [Gleam](https://gleam.run) v1.14+
- Erlang/OTP 27+
- tmux
- A Discord bot token ([create one here](https://discord.com/developers/applications))
- An LLM API key (ZAI/GLM or Anthropic/Claude)
- A Brave Search API key (optional, for web search — [get one here](https://brave.com/search/api/))

## Quick Start

```bash
git clone https://github.com/yourusername/aura.git
cd aura
gleam build
gleam run -- init
```

The init command will:
1. Check your dependencies
2. Create the workspace directories (XDG-compliant)
3. Prompt for your Discord bot token and LLM API key
4. Generate identity files (SOUL.md, USER.md, META.md)
5. Create your first workstream
6. Validate the Discord connection

Then start Aura:

```bash
gleam run
```

## Workspace Structure

Aura follows the XDG Base Directory specification:

```
~/.config/aura/           # Configuration
  config.toml               # Global settings
  .env                      # Credentials (gitignored)
  SOUL.md                   # Personality and boundaries
  META.md                   # Document governance rules
  USER.md                   # Your profile
  workstreams/
    <name>/config.toml      # Per-workstream settings

~/.local/share/aura/      # Data
  events.jsonl              # Cross-workstream event index
  workstreams/
    <name>/
      anchors.jsonl         # Decisions that survive compression
      logs/YYYY-MM-DD.jsonl # Daily conversation logs
      summaries/            # Weekly summaries (generated on demand)
  skills/
    <name>/
      SKILL.md              # Skill definition (Claude Code format)
      entrypoint.sh         # CLI script
  acp/
    sessions/               # Active ACP task metadata
    completed/              # Finished task results

~/.local/state/aura/      # Runtime state
  MEMORY.md                 # Long-term cross-workstream memory
```

## Architecture

```
root_supervisor (OneForOne)
+-- poller            Discord gateway WebSocket
+-- brain             Routes messages, applies personality
+-- workstream_sup    One actor per workstream
+-- heartbeat_sup     One actor per check type
+-- acp_sup           One actor per running Claude Code session
+-- memory            File operations
```

Messages flow: Discord -> Poller -> Brain -> Workstream -> LLM -> Brain -> Discord.

The brain routes by channel (no LLM call needed). Messages in #aura get classified and routed. Each workstream loads its own context (anchors, logs, skills) before reasoning.

## Configuration

### Global (`~/.config/aura/config.toml`)

```toml
[discord]
token = "${AURA_DISCORD_TOKEN}"
guild = "aura"
default_channel = "aura"

[models]
brain = "zai/glm-5-turbo"
workstream = "claude/sonnet"
acp = "claude/opus"

[notifications]
digest_windows = ["07:35", "09:10", "11:10", "15:00"]
timezone = "Asia/Manila"

[acp]
global_max_concurrent = 4
```

### Workstream (`~/.config/aura/workstreams/<name>/config.toml`)

```toml
name = "my-project"
description = "Backend API. Rust. Jira board MP."
cwd = "~/repos/my-project"
tools = ["jira", "google"]

[discord]
channel = "my-project"
```

Adding a workstream: create the directory, write config.toml. No restart needed.

## Skills

Skills are CLI tools in `~/.local/share/aura/skills/<name>/`. Each has a `SKILL.md` (Claude Code format) and an entrypoint script.

```bash
mkdir -p ~/.local/share/aura/skills/my-tool
# Write SKILL.md and your script
# Add "my-tool" to a workstream's tools list
```

## ACP (Agent Code Projects)

Tell Aura to fix a bug or implement a feature. It spawns Claude Code in a tmux session, monitors progress, and reports back to Discord.

```
You (in #my-project): fix the login timeout bug in PROJ-123
Aura: ACP Started — PROJ-123
      tmux attach -t acp-my-project-proj123
```

Attach to watch or intervene. The monitor classifies session status and alerts you if the agent gets stuck.

## License

MIT
