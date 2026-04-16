# A.U.R.A.

**Autonomous Unified Runtime Agent**

Managing work across multiple projects is fragmented. You context-switch between tools, your AI assistant forgets everything between sessions, and your coding agent can fix a bug but can't connect it to the ticket you're behind on.

A.U.R.A. is an executive assistant and orchestrator. Each area of your life gets an isolated domain with its own instructions, memory, and state — but A.U.R.A. sees across all of them. When there's work to do, it dispatches coding agents via ACP, monitors progress, and persists what it learns. Think Jarvis, not Copilot.

Built on the BEAM. Supervised OTP actors crash and recover independently. Gateways, providers, and skills are all pluggable.

> *Inspired by [Hermes Agent](https://github.com/nousresearch/hermes-agent) and [OpenClaw](https://github.com/openclaw/openclaw). A.U.R.A. is the orchestrator layer above the coding agent, not the agent itself.*

## What It Does

- **Domains** — isolated knowledge partitions per project/responsibility, with cross-domain awareness
- **ACP** — dispatch coding agents (provider-agnostic) into isolated worktrees, monitor in real-time, get structured reports
- **Active memory** — automatic post-response review persists state and knowledge. Domain-aware compression preserves what matters.
- **Skills** — language-agnostic CLI tools. Drop a script in a directory, it becomes a capability. A.U.R.A. auto-creates skills from learned workflows.
- **Schedules** — config-driven cron + interval tasks that monitor Linear, calendar, PRs, and Slack
- **Self-configuration** — create domains, update config, manage identity — all through conversation with propose/approve flow
- **Pluggable gateways** — Discord ships first. Multi-platform conversation schema from day one.

## Requirements

- [Gleam](https://gleam.run) v1.14+
- Erlang/OTP 27+
- tmux
- A Discord bot token ([create one here](https://discord.com/developers/applications))
- An LLM API key (ZAI/GLM or Anthropic/Claude)

## Quick Start

```bash
git clone https://github.com/melbaldove/aura.git
cd aura
gleam build
gleam run -- init
```

The init command checks dependencies, creates XDG-compliant directories, prompts for credentials, and generates identity files.

```bash
gleam run -- start
```

## Architecture

```
supervisor (OneForOne)
├── db            SQLite actor — serializes all DB reads/writes
├── poller        Gateway WebSocket (Discord first, pluggable)
├── acp_manager   ACP session lifecycle — dispatch, monitor, persist
├── brain         Routes messages, LLM tool loop, streaming, memory review
└── scheduler     Config-driven cron + interval schedules
```

## Directory Structure

A.U.R.A. follows the XDG Base Directory specification:

```
~/.config/aura/                    # Configuration
  config.toml                        # Global settings
  SOUL.md                            # Personality and boundaries
  USER.md                            # User profile
  schedules.toml                     # Scheduled tasks
  domains/<name>/config.toml         # Per-domain settings
  domains/<name>/AGENTS.md           # Domain instructions

~/.local/share/aura/               # Data
  aura.db                            # Conversations (SQLite)
  skills/<name>/SKILL.md             # Skills
  domains/<name>/MEMORY.md           # Durable domain knowledge
  domains/<name>/repos/              # Project repositories

~/.local/state/aura/               # Runtime state
  MEMORY.md                          # Global cross-domain memory
  domains/<name>/STATE.md            # Current domain status
```

## Configuration

See [docs/CONFIG.md](docs/CONFIG.md) for the full reference.

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

[acp]
global_max_concurrent = 4

[memory]
review_interval = 10
notify_on_review = true
```

### Domain (`~/.config/aura/domains/<name>/config.toml`)

```toml
name = "my-project"
description = "Backend API. Rust."
cwd = "~/.local/share/aura/domains/my-project"
tools = ["linear", "google"]

[discord]
channel = "my-project"
```

## ACP ([Agent Communication Protocol](https://agentcommunicationprotocol.dev))

A.U.R.A. is an ACP client. It dispatches coding agents via the open standard, monitors progress through SSE event streams, and reports structured updates. Any ACP-compatible agent works — Claude Code, Codex, Gemini CLI.

You can interact with the same session from multiple interfaces:
- **Discord** — structured progress updates via A.U.R.A.
- **Zed** — direct editor integration
- **`acpx`** — terminal CLI access
- **tmux** — legacy fallback when no ACP server is configured

```
You (in #my-project): investigate and fix the login timeout bug PROJ-123
A.U.R.A.: ACP dispatched.

         📋 **Investigate login timeout PROJ-123** · 8m elapsed
         `acp-my-project-t1775618752766`

         **Status:** Working
         **Done:** Found root cause in `AuthService.swift:142`
         **Current:** Implementing fix
         **Needs input:** none
         **Next:** Create PR
```

## Documentation

A.U.R.A. ships with Unix man pages:

```bash
man aura                # Overview, architecture, limitations
man aura-flares         # Flare lifecycle, states, diagnostics
man aura-config         # Configuration files, env vars, deploy
man aura-diagnostics    # Troubleshooting, maintenance rules
```

The brain reads these same man pages via the shell tool for self-diagnosis.

See also: [Engineering Practice](docs/ENGINEERING.md) and [Architecture Decision Records](docs/decisions/).

## License

MIT
