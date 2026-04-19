# Aura test fakes

Shared fake clients for feature tests. Each fake returns `#(Handle, Client)`
from `new()`: the handle is for assertions, the client is for DI into
production code under test.

Full guide: `man aura-testing` → FAKES.

## Inventory

| Fake | Intercepts | Key API |
|---|---|---|
| `fake_discord.gleam` | `DiscordClient` | `all_sent_to`, `assert_sent_to`, `assert_latest_contains`, `seed_channel_parent` |
| `fake_llm.gleam` | `LLMClient` | `script_text_response`, `script_tool_call`, `script_error`, `script_hang`, `script_reasoning_forever`, `script_chat_text_response` |
| `fake_skill_runner.gleam` | `SkillRunner` | `script_for`, `invocations` |

More fakes (fake_browser, fake_acp, fake_scheduler) land in Plan B.
