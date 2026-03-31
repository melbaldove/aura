# ADR-006: SSE streaming with tool call accumulation

**Status:** Accepted
**Date:** 2026-03-31

## Context

LLM calls take 10-30 seconds. Without streaming, users stare at a typing indicator with no feedback. Claude Code and Claude Desktop both stream token-by-token.

The initial streaming attempt sent requests WITHOUT tool definitions, hoping to stream text and fall back to tools if needed. This failed — GLM-5.1 embedded tool calls as XML in its text response when no tools were available.

Additionally, GLM-5.1 sends `reasoning_content` tokens for 10-20 seconds before any `content` tokens, which caused the initial 3-second timeout to expire.

## Decision

Stream ALL LLM calls with tool definitions included. The Erlang FFI (`aura_stream_ffi.erl`) handles both content and tool call deltas:

- Content deltas → forwarded to brain process for progressive Discord edits (~every 150 chars)
- Tool call deltas → accumulated internally by index (id, name, argument pieces)
- Reasoning tokens → forwarded as keepalive signal (resets idle timeout)
- On `[DONE]` → sends `{stream_complete, Content, ToolCallsJson}` with the complete response

JSON parsing in the FFI is manual binary pattern matching (no JSON library in Erlang) to extract `delta.content`, `delta.reasoning_content`, and `delta.tool_calls` fields.

The idle timeout resets on any data (content, reasoning, or tool call deltas). Only genuine silence (no data for 500ms) counts toward the 120-second timeout.

## Consequences

- Users see text appearing progressively on Discord
- Tool calls work correctly (arguments fully accumulated before execution)
- Manual JSON parsing is fragile — works for OpenAI format but may break with non-standard APIs
- The Erlang FFI is ~200 lines of binary pattern matching — not trivial to maintain
- Discord rate limits message edits to ~5/5s — we edit every ~150 chars which stays within limits
- GLM-5.1's reasoning phase is invisible to the user (typing indicator covers it)
