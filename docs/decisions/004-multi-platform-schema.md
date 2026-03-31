# ADR-004: Multi-platform conversation schema

**Status:** Accepted
**Date:** 2026-03-31

## Context

Aura currently only supports Discord, but the goal is to support Telegram, Slack, and other platforms (like OpenClaw supports 30+ platforms and Hermes supports 6).

Using Discord's `channel_id` as the primary key would tie the data model to one platform. Telegram has `chat_id`, Slack has `channel` + `thread_ts`, Matrix has `room_id` — these could collide across platforms.

## Decision

Key conversations by `(platform, platform_id)` instead of raw channel_id.

```sql
conversations (
  id TEXT PRIMARY KEY,          -- "discord:123456"
  platform TEXT NOT NULL,       -- "discord", "telegram", "slack"
  platform_id TEXT NOT NULL,    -- native ID from that platform
  UNIQUE(platform, platform_id)
)
```

All downstream code uses `conversation_id` (the composite key), never raw platform IDs. The `get_or_load_db` function takes `platform` and `platform_id` separately and resolves to the conversation_id.

## Consequences

- Adding a new platform requires no schema changes
- Cross-platform search works out of the box (FTS5 searches all messages)
- Slightly more verbose than using channel_id directly
- Current code hardcodes `"discord"` as the platform — will need parameterizing when adding platforms
- Thread support via `parent_id` column works across platforms
