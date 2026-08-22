# Deferred Compression Items

Track implementation of the 4 deferred items from the runtime compression spec review.

## Items

### 1. API Token Usage Tracking
**Status:** DONE

**Problem:** `CompressorState.last_prompt_tokens` exists but is never populated from LLM API responses. All threshold checks use rough `chars/4` estimation.

**What to do:**
- Streaming path (brain tool loop): modify `aura_stream_ffi.erl` to extract `usage.prompt_tokens` from the final SSE `data: [DONE]` or the last chunk's `usage` field. Return it alongside content and tool_calls.
- Non-streaming path (`chat_with_tools`): extract `usage.prompt_tokens` from the JSON response.
- Feed the value back to `CompressorState.last_prompt_tokens` via the `StoreExchange` / `CompressionComplete` message path.
- Use `last_prompt_tokens` in `needs_tool_pruning` and `needs_full_compression` when available (> 0), fall back to rough estimate when 0.

**Files to change:**
- `src/aura_stream_ffi.erl` — extract usage from final SSE event
- `src/aura/llm.gleam` — update `LlmResponse` to include `prompt_tokens: Int`, parse from response JSON
- `src/aura/brain.gleam` — pass prompt_tokens through to compressor state
- `src/aura/conversation.gleam` — use last_prompt_tokens when > 0

### 2. Expand Known Models List
**Status:** DONE

**Problem:** Current lookup table has 6 models. Should cover all major providers.

**Research results (verified):**
```
zai/glm-5.1          → 204,800
zai/glm-5-turbo      → 202,752
zai/glm-5v-turbo     → 202,752
claude/opus-4-6      → 1,000,000
claude/sonnet-4-6    → 1,000,000
claude/opus-4-5      → 200,000
claude/sonnet-4-5    → 200,000
claude/opus          → 200,000
claude/sonnet        → 200,000
claude/haiku         → 200,000
openai/gpt-4o        → 128,000
openai/gpt-4o-mini   → 128,000
google/gemini-2.0-flash → 1,048,576
google/gemini-2.5-pro   → 1,048,576
deepseek/deepseek-v3    → 128,000
deepseek/deepseek-r1    → 128,000
meta/llama-4-scout      → 1,048,576
meta/llama-4-maverick   → 1,048,576
```

Note: Also need prefix matching for unknown variants (e.g., "claude/" → 200,000 as fallback).

**Files to change:**
- `src/aura/models.gleam` — expand `context_length` function

### 3. Token-Budget Tail Protection
**Status:** DONE

**Problem:** Tail is fixed 20 messages instead of walking backward by token budget (~20% of context window).

**What to do:**
- In `compress_history`, replace `protect_tail_count = 20` with a token-budget walk.
- Walk backward from end, accumulating tokens. Stop when budget (~20% of context window) is reached.
- Never cut inside tool_call/tool_result pairs.
- Fall back to 20 messages minimum if budget protects fewer.

**Files to change:**
- `src/aura/conversation.gleam` — replace fixed tail with token-budget tail
- `src/aura/compressor.gleam` — add `find_tail_cut_by_tokens` helper

### 4. Pre-flight Check + Auto-probe
**Status:** DONE

**Problem:** No token estimation before sending to LLM API. No context length adjustment on overflow.

**What to do:**
- Before each `chat_streaming_with_tools` call in `tool_loop_progressive`, estimate tokens.
- If over context length, run synchronous tool pruning first (instant).
- If still over after pruning, log warning and proceed (API will reject, next turn triggers compression).
- On context overflow error from API, halve `brain_context` for this session and log.

**Files to change:**
- `src/aura/brain.gleam` — pre-flight check in tool loop, auto-probe on error
