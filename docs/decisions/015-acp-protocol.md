# ADR 015: ACP Protocol for Agent Dispatch

## Status
Accepted (2026-04-09)

## Context
A.U.R.A.'s agent dispatch was tightly coupled to tmux — shell out to create sessions, poll stdout every 15 seconds, use an LLM to classify raw terminal output. This was fragile (output parsing), expensive (LLM call per check), and not portable (only works with CLI agents in tmux). The Agent Communication Protocol (ACP) is an open standard for agent interoperability backed by IBM/Linux Foundation (https://agentcommunicationprotocol.dev).

## Decision
Replace tmux-based dispatch with ACP. A.U.R.A. becomes an ACP client, talking HTTP to any ACP-compatible server. Use the existing `@agentclientprotocol/claude-agent-acp` adapter for Claude Code. SSE event streams replace polling. The tmux path is kept as a legacy fallback via config (`acp.server_url` empty = tmux).

Multiple interfaces can connect to the same ACP server simultaneously:
- A.U.R.A. dispatches and monitors (orchestrator)
- Zed provides direct editor integration (hands-on coding)
- `acpx` provides terminal access (CLI)
- Discord shows structured progress (mobile/passive)

## Consequences
- Agent dispatch is provider-agnostic — any ACP server works (Claude Code, Codex, Gemini CLI)
- No more stdout scraping or LLM classification of terminal output
- Real-time events via SSE instead of 15-second polling
- Users interact with sessions via Zed, acpx, or Discord — all talking to the same server
- Depends on external ACP server process (sidecar deployment)
- tmux fallback available for environments without an ACP server
