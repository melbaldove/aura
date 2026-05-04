# Aura Configuration Reference

## Global Config

**Path:** `~/.config/aura/config.toml`

### [discord]

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `token` | string | yes | Discord bot token. Use `${AURA_DISCORD_TOKEN}` to read from env. |
| `guild` | string | yes | Discord server (guild) ID. |
| `default_channel` | string | yes | Existing Discord text channel name or numeric channel ID for cross-domain messages and digest delivery. Startup fails if this cannot be resolved. |

### [blather] (optional)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `url` | string | yes if section present | Blather API base URL. Include reverse-proxy prefixes, e.g. `http://10.0.0.2:18100/api`. |
| `api_key` | string | yes if section present | Blather agent API key. Use `${BLATHER_API_KEY}` to read from env. |

### [models]

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `brain` | string | yes | — | Main LLM for conversation. Format: `provider/model` (e.g., `zai/glm-5.1`, `openai-codex/gpt-5.5`). |
| `domain` | string | yes | — | LLM for domain-specific tasks. |
| `acp` | string | yes | — | LLM for ACP coding sessions (dispatched to Claude Code). |
| `heartbeat` | string | yes | — | LLM for scheduled task classification. |
| `monitor` | string | yes | — | LLM for ACP session monitoring and memory review. |
| `vision` | string | no | `""` | Vision model for image description. |
| `brain_context` | int | no | `0` | Override context window size (tokens). `0` = use built-in lookup table. |
| `codex_reasoning_effort` | string | no | `"medium"` | Reasoning effort for `openai-codex/*` Responses calls. Supported values: `"none"`, `"minimal"`, `"low"`, `"medium"`, `"high"`, `"xhigh"`. |

**Runtime providers:** `zai/`, `claude/`, `openai-codex/`

`openai-codex/*` is an experimental orchestrator route for using a ChatGPT/Codex subscription login instead of an API key. It sends Aura's LLM tool loop to the Codex Responses backend (`https://chatgpt.com/backend-api/codex/responses`) and reads credentials in this order:

1. `AURA_OPENAI_CODEX_ACCESS_TOKEN` plus optional `AURA_OPENAI_CODEX_ACCOUNT_ID`
2. `$CODEX_HOME/auth.json`
3. `~/.codex/auth.json`

Run `codex login` or `codex login --device-auth` first. For file-backed Codex CLI credentials, Aura refreshes expired access tokens through Codex's OAuth refresh flow and persists rotated tokens back to `auth.json`. If Codex is configured to store credentials only in the OS keychain, Aura cannot read or refresh them directly; use file storage or the Aura env override. The env override is treated as a fixed bearer token and is not auto-refreshed. This model route is separate from `[acp] command = "codex-acp"`, which controls dispatched flare agents.

### [vision]

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `prompt` | string | no | `""` | Custom prompt for image description. |

### [notifications]

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `digest_windows` | array of strings | yes | Local times to deliver queued digests, including cognitive `attention=digest` items (e.g., `["07:35", "09:10"]`). |
| `timezone` | string | yes | IANA timezone (e.g., `Asia/Manila`). |
| `urgent_bypass` | bool | yes | Whether urgent findings skip the digest schedule. |

### [acp]

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `global_max_concurrent` | int | yes | — | Max concurrent ACP sessions across all domains. |
| `transport` | string | no | `"stdio"` | ACP transport: `"stdio"`, `"http"`, or `"tmux"`. |
| `command` | string | no | `"codex-acp"` | Stdio ACP adapter command. Deploy bootstraps `codex-acp` and `claude-agent-acp`. |
| `server_url` | string | no | `""` | HTTP ACP server URL (e.g., `http://localhost:8000`). Used only when `transport = "http"`. |
| `agent_name` | string | no | `"claude-code"` | Agent name to dispatch to on the HTTP ACP server. |

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
| `channel` | string | yes | Existing Discord text channel name or numeric channel ID for this domain. |

### [blather] (optional)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `channel` | string | yes if section present | Blather channel ID for this domain. Messages from this channel use the same domain context as the Discord binding. |

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
| `BLATHER_API_KEY` | Blather agent API key. |
| `ZAI_API_KEY` | Zhipu/Z.AI API key. |
| `ANTHROPIC_API_KEY` | Anthropic API key (optional if using `CLAUDE_CODE_OAUTH_TOKEN`). |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code auth token for headless ACP sessions (from `claude setup-token`). |
| `AURA_OPENAI_CODEX_ACCESS_TOKEN` | Optional fixed bearer-token override for `openai-codex/*` model specs. Prefer Codex CLI login cache when possible so Aura can refresh OAuth tokens. |
| `AURA_OPENAI_CODEX_ACCOUNT_ID` | Optional ChatGPT workspace/account id header for `openai-codex/*`; used with `AURA_OPENAI_CODEX_ACCESS_TOKEN`. |
| `CODEX_HOME` | Optional Codex CLI config/cache directory. Defaults to `~/.codex` when unset. |
| `CODEX_API_KEY` | Codex API key for `codex-acp` if not using Codex login state. |
| `OPENAI_API_KEY` | OpenAI API key accepted by `codex-acp` as an alternative to `CODEX_API_KEY`. |
| `BRAVE_API_KEY` | Brave Search API key (optional, for web_search tool). |
