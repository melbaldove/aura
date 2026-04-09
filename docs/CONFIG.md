# Aura Configuration Reference

## Global Config

**Path:** `~/.config/aura/config.toml`

### [discord]

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `token` | string | yes | Discord bot token. Use `${AURA_DISCORD_TOKEN}` to read from env. |
| `guild` | string | yes | Discord server (guild) ID. |
| `default_channel` | string | yes | Default channel name for #aura. |

### [models]

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `brain` | string | yes | — | Main LLM for conversation. Format: `provider/model` (e.g., `zai/glm-5.1`). |
| `domain` | string | yes | — | LLM for domain-specific tasks. |
| `acp` | string | yes | — | LLM for ACP coding sessions (dispatched to Claude Code). |
| `heartbeat` | string | yes | — | LLM for scheduled task classification. |
| `monitor` | string | yes | — | LLM for ACP session monitoring and memory review. |
| `vision` | string | no | `""` | Vision model for image description. |
| `brain_context` | int | no | `0` | Override context window size (tokens). `0` = use built-in lookup table. |

**Supported providers:** `zai/`, `claude/`, `openai/`, `google/`, `deepseek/`, `meta/`

### [vision]

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `prompt` | string | no | `""` | Custom prompt for image description. |

### [notifications]

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `digest_windows` | array of strings | yes | Times to deliver digest (e.g., `["07:35", "09:10"]`). |
| `timezone` | string | yes | IANA timezone (e.g., `Asia/Manila`). |
| `urgent_bypass` | bool | yes | Whether urgent findings skip the digest schedule. |

### [acp]

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `global_max_concurrent` | int | yes | — | Max concurrent ACP sessions across all domains. |

### [memory]

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `review_interval` | int | no | `10` | Turns between automatic memory review. `0` = disabled. |
| `notify_on_review` | bool | no | `true` | Post Discord notification when review writes entries. |

---

## Domain Config

**Path:** `~/.config/aura/domains/<name>/config.toml`

### Top-level

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | yes | — | Domain identifier (lowercase, hyphens). |
| `description` | string | yes | — | One-line description of the domain. |
| `cwd` | string | yes | — | Working directory for the domain (used for relative paths and ACP sessions). |
| `tools` | array of strings | yes | — | Enabled tools/skills (e.g., `["jira", "google", "discord"]`). |

### [discord]

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `channel` | string | yes | Discord channel name for this domain. |

### [model] (optional overrides)

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `domain` | string | no | global `models.domain` | Override the domain-specific LLM model. |
| `vision` | string | no | global `models.vision` | Override the vision model for this domain. |

### [vision] (optional override)

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `prompt` | string | no | global `vision.prompt` | Override the vision prompt for this domain. |

### [acp] (optional overrides)

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `timeout` | int | no | `1800` | ACP session timeout in seconds. |
| `max_concurrent` | int | no | `2` | Max concurrent ACP sessions for this domain. |
| `provider` | string | no | `"claude-code"` | ACP provider: `"claude-code"` or `"generic"`. |
| `binary` | string | no | `""` | Custom binary for generic provider. |
| `worktree` | bool | no | `true` | Use git worktrees for ACP sessions. |

### [context] (optional, domain-specific)

Free-form key-value pairs for domain context. Common fields:

| Field | Type | Description |
|-------|------|-------------|
| `jira_instance` | string | Jira instance key (e.g., `"PROJ"`, `"TEAM"`). |
| `jira_url` | string | Jira base URL. |
| `github_org` | string | GitHub organization name. |

---

## Schedules

**Path:** `~/.config/aura/schedules.toml`

Each schedule is a `[[schedule]]` entry:

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | yes | — | Unique schedule identifier. |
| `type` | string | yes | — | `"interval"` or `"cron"`. |
| `skill` | string | yes | — | Skill to invoke (e.g., `"jira"`, `"google"`). |
| `args` | string | yes | — | JSON array of arguments (e.g., `'["--instance", "PROJ", "tickets", "assigned"]'`). |
| `domains` | array of strings | yes | — | Which domains this schedule reports to. Empty = global. |
| `model` | string | yes | — | LLM model for classifying findings. |
| `enabled` | bool | yes | — | Whether the schedule is active. |
| `every` | string | if interval | — | Interval duration (e.g., `"15m"`, `"1h"`). |
| `cron` | string | if cron | — | Cron expression (e.g., `"0 9 * * *"`). |

---

## Identity Files

| File | Path | Description |
|------|------|-------------|
| `SOUL.md` | `~/.config/aura/SOUL.md` | Agent personality, role, principles. Tier 3 (propose + preview). |
| `USER.md` | `~/.config/aura/USER.md` | User profile (name, timezone, preferences). Tier 2 (propose). |
| `META.md` | `~/.config/aura/META.md` | Meta-information about the instance. |

## Domain Files

| File | Path | Description |
|------|------|-------------|
| `AGENTS.md` | `~/.config/aura/domains/<name>/AGENTS.md` | Domain instructions, expertise, repo index. Tier 2 (propose). |
| `MEMORY.md` | `~/.local/share/aura/domains/<name>/MEMORY.md` | Durable domain knowledge. Tier 1 (autonomous). |
| `STATE.md` | `~/.local/state/aura/domains/<name>/STATE.md` | Current domain status. Tier 1 (autonomous). |
| `log.jsonl` | `~/.local/share/aura/domains/<name>/log.jsonl` | Domain activity log. Tier 1 (autonomous). |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `AURA_DISCORD_TOKEN` | Discord bot token. |
| `ZAI_API_KEY` | Zhipu/Z.AI API key. |
| `ANTHROPIC_API_KEY` | Anthropic API key (optional if using `CLAUDE_CODE_OAUTH_TOKEN`). |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code auth token for headless ACP sessions (from `claude setup-token`). |
| `BRAVE_API_KEY` | Brave Search API key (optional, for web_search tool). |
