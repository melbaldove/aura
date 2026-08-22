# ACP Stdio Transport Implementation

## Context

The ACP protocol supports two transports:
- **HTTP REST** — implemented in `acp/client.gleam` (done)
- **Stdio JSON-RPC** — NOT yet implemented (this task)

The existing Claude Code ACP adapter (`@agentclientprotocol/claude-agent-acp`) uses **stdio**, not HTTP.
The HTTP client we built works but has no server to connect to yet.
Stdio is the priority because it works with the existing adapter today.

## ACP Stdio Protocol

Reference: https://agentclientprotocol.com

### Transport
- NDJSON (newline-delimited JSON) over stdin/stdout
- Spawn `claude-agent-acp` as a child process via Erlang `open_port`

### JSON-RPC 2.0 Methods

**Initialize:**
```json
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"aura","title":"A.U.R.A.","version":"0.1.0"}}}
```

**New Session:**
```json
{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/path/to/repo"}}
```

**Prompt (send input):**
```json
{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"sess_abc","prompt":[{"type":"text","text":"fix the bug"}]}}
```

**Cancel:**
```json
{"jsonrpc":"2.0","method":"cancel","params":{}}
```

### Streaming (Agent → Client notifications)

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_abc","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Working on..."}}}}
```

Event types in `sessionUpdate`:
- `plan` — agent's intended approach
- `agent_message_chunk` — text response chunks
- `tool_call` — tool invocation
- `tool_call_update` — tool status (in_progress, completed, cancelled)

### Completion

The original `session/prompt` request gets a response:
```json
{"jsonrpc":"2.0","id":2,"result":{"stopReason":"end_turn"}}
```

Stop reasons: `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, `cancelled`

## Implementation Plan

### Files to create/modify

1. **`src/aura_acp_stdio_ffi.erl`** — Erlang FFI: spawn child process via `open_port({spawn, Command}, [binary, {line, 65536}, use_stdio])`. Write NDJSON lines to stdin. Read lines from stdout. Forward parsed JSON to callback pid.

2. **`src/aura/acp/stdio.gleam`** — Gleam wrapper: `start(command, callback_pid)`, `send_request(port, method, params, id)`, `receive_message(timeout)`. Types for JSON-RPC messages.

3. **`src/aura/acp/transport.gleam`** — Abstraction layer: `Transport { Http(server_url) | Stdio(command) }`. Functions: `create_session(transport, cwd)`, `prompt(transport, session_id, text)`, `cancel(transport)`, `list_agents(transport)`. Routes to `client.gleam` (HTTP) or `stdio.gleam` (stdio) based on transport type.

4. **`src/aura/acp/manager.gleam`** — Replace direct `client.*` calls with `transport.*` calls. The transport is determined from config.

5. **`src/aura/config.gleam`** — Add `acp_transport: String` field ("stdio" or "http"). Add `acp_command: String` for stdio binary path.

### Event mapping (stdio → AcpEvent)

| Stdio event | AcpEvent |
|---|---|
| First `session/update` | AcpStarted |
| `agent_message_chunk` | AcpProgress |
| `tool_call` | AcpProgress (with tool info) |
| `tool_call_update(completed)` | AcpProgress |
| `result.stopReason = "end_turn"` | AcpCompleted |
| `result.stopReason = "cancelled"` | AcpFailed("cancelled") |
| `result.stopReason = "refusal"` | AcpFailed("refused") |
| Process exit | AcpFailed("process died") |

### Config

```toml
[acp]
transport = "stdio"                         # "stdio" or "http"
command = "claude-agent-acp"                # for stdio
server_url = "http://localhost:8000"        # for http
agent_name = "claude-code"
global_max_concurrent = 4
```

### Key differences from HTTP

- One child process per session (not one shared server)
- Session lifecycle tied to process lifetime
- No separate SSE connection — events come on stdout
- Initialize handshake required before first prompt
- Cancel is a notification, not a request
