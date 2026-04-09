# ADR 012: Keyed Memory Entries

## Status
Accepted (2026-04-09)

## Context
The original memory system used `§`-delimited entries with `add`/`replace`/`remove` operations. `replace` required an `old_text` substring match, which the LLM frequently guessed wrong (tried to replace text from the system prompt instead of the actual file content). `add` was append-only with no way to update existing entries. Parallel agents writing to the same file could clobber each other.

## Decision
Switch to keyed entries: `§ key\ncontent` format. Operations are `set` (upsert by key), `remove` (by key), and `read`. The LLM doesn't need to read before writing — `set` creates or replaces by key. Each key is independent, so parallel agents writing different keys don't conflict.

## Consequences
- No more `old_text` guessing — the key is the identifier
- Parallel-agent safe — each agent writes its own keys
- Simpler mental model — the tool is self-evident from its interface
- Existing files migrated to keyed format on Eisenhower
- The `§` delimiter is preserved but now prefixes a key name instead of being a bare separator
