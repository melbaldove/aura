# A.U.R.A.

**Autonomous Unified Runtime Agent**

A.U.R.A. is an always-on personal AI. It lives on your laptop, talks to you on Discord, and runs in the background for as long as the BEAM is up. It partitions your work into domains (job, project, personal), tracks state across all of them, dispatches coding agents when there's code to write, and consolidates what it learned while you sleep.

Built on the BEAM. Supervised OTP actors crash and recover independently. Every Discord channel is its own actor — conversations across domains run in parallel, and one stuck turn can't block another.

> *Inspired by [Hermes Agent](https://github.com/nousresearch/hermes-agent) (learning loops) and [OpenClaw](https://github.com/openclaw/openclaw) (autonomous coding). Hermes learns skills inside a single workflow; OpenClaw ships coding agents. A.U.R.A. is the always-on layer above them — the assistant that knows you, owns your domains, and dispatches those agents as one capability among many.*

## What It Does

- **Domains** — isolated knowledge partitions, one per area of your life. Each has its own instructions, memory, state, and Discord channel. The brain sees across all of them.
- **Flares** — long-running coding-agent sessions dispatched via ACP. Active / parked / failed lifecycle with SQLite persistence, recovery on restart, and rekindle on schedule.
- **Memory** — active review persists state and knowledge every N turns; nightly dreaming consolidates the archive offline, promotes durable facts, and enforces a token budget.
- **Skills** — language-agnostic CLI tools. Drop a script in a directory, it becomes a capability the LLM can call.
- **Self-diagnosis** — ships with man pages. The brain reads them via the shell tool when it needs to understand its own behavior.
- **Shell approvals** — dangerous shell commands require Discord button approval; unresolved approvals are invalidated visibly after actor restart.
- **Pluggable gateways and ACP transports** — Discord first; multi-platform conversation schema from day one.

## Requirements

- [Gleam](https://gleam.run) v1.14+
- Erlang/OTP 27+
- tmux
- A Discord bot token ([create one here](https://discord.com/developers/applications))
- An LLM API key (ZAI/GLM or Anthropic/Claude)
- agent-browser (npm) for the browser tool: `npm install -g agent-browser && agent-browser install`

### Nix Dev Shell

Aura includes a flake for a reproducible contributor toolchain:

```bash
nix develop
gleam test
```

The shell provides Gleam, Erlang/OTP 27, rebar3, a C toolchain, tmux, SQLite,
and Node.js. If `esqlite` reports `corrupt atom table` after `gleam clean`, run:

```bash
aura-fix-esqlite-nif
```

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
├── db                   SQLite actor — serializes all DB reads/writes
├── poller               Gateway WebSocket (Discord first, pluggable)
├── flare_manager        Flare lifecycle — roster, dispatch, monitor, persist
├── channel_supervisor   Hosts one actor per Discord channel
├── brain                Routes messages to channel actors; global concerns
└── scheduler            Cron + interval schedules + nightly dreaming
```

Each `channel_actor` owns the LLM tool loop, streaming, typing, and compression for its channel — work across channels runs in parallel.

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
vision = "zai/glm-5v-turbo"
dream = "zai/glm-5.1"
heartbeat = "zai/glm-5-turbo"
monitor = "zai/glm-5-turbo"

[acp]
global_max_concurrent = 4

[memory]
review_interval = 10
notify_on_review = true

[dreaming]
cron = "0 4 * * *"
budget_percent = 10
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

## Flares ([Agent Communication Protocol](https://agentcommunicationprotocol.dev))

A flare is a long-running agent session. A.U.R.A. is an ACP client — it dispatches flares via the open standard, subscribes to their SSE event stream, and reports structured progress updates. Any ACP-compatible agent works (Claude Code, Codex, Gemini CLI), and multiple transports are pluggable (stdio, tmux).

Flares persist across restarts: the roster is written to SQLite and recovered on boot. Parked flares can be rekindled on a schedule.

You can interact with the same flare from multiple interfaces:
- **Discord** — structured progress updates via A.U.R.A.
- **Zed** — direct editor integration
- **`acpx`** — terminal CLI access

```
You (in #my-project): investigate and fix the login timeout bug PROJ-123
A.U.R.A.: Flare dispatched.

         📋 **Investigate login timeout PROJ-123** · 8m elapsed
         `f-1775618752766`

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
