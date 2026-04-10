# ADR 017: Background Agent Architecture (OpenPoke Pattern)

## Status
Superseded by [ADR 018](018-flare-architecture.md)

## Context
ACP sessions currently operate as fire-and-forget: the brain dispatches, the monitor shows progress, the session completes, and the results are trapped. The user never gets an answer to their original question. The brain doesn't read what the agent produced, doesn't summarize findings, and doesn't continue the conversation.

This was exposed when a user asked Aura to "understand the exclusion feature" — ACP dispatched, the agent read 8 files and wrote an analysis, but the user only got a dry status card. The agent's actual findings were never surfaced.

## Inspiration
The OpenPoke architecture (shloked.com/writing/openpoke) implements this pattern:
- An Interaction Agent (conductor) manages a swarm of Execution Agents
- Execution Agents are persistent, have their own conversation history, run independently
- When they finish, they deliver a status report back to the Interaction Agent
- The Interaction Agent evaluates whether to surface results, suppress noise, or wait
- Multiple agents run in parallel, results weaved into conversation naturally

## Decision
Aura's brain is the Interaction Agent. ACP sessions are Execution Agents. The architecture:

1. **Dispatch**: Brain dispatches work to an ACP agent (existing)
2. **Monitor**: Push-based monitor shows progress (ADR 016, implemented)
3. **Handback**: When agent finishes a turn, structured results flow back to the brain's conversation as a system message. The brain re-enters its tool loop and answers the user naturally.
4. **Continuation**: The ACP session stays alive. The brain can send follow-up input, and the agent continues with full context.
5. **Agency**: The brain can query agent state at will — it treats the agent as an extension of its own thinking.

### Result payload (on agent turn completion)
Three layers:
- **Done summary** — from monitor's cumulative LLM summary (high-level progress)
- **Last 5 tool calls** — what the agent did at the end (context)
- **Agent's final message** — the agent's actual conclusion/output (the answer)

### Execution Agent types
ACP agents are not limited to Claude Code. An Execution Agent could be:
- Claude Code via ACP stdio — coding tasks
- Another Aura instance — with its own system prompt, domain knowledge, tools
- Any ACP-compatible agent — Cursor, Windsurf, custom agents
- A future Aura sub-instance for complex delegation

The brain doesn't care what's behind the ACP session. The protocol is the abstraction.

### Brain behavior on handback
- Load the thread conversation (full history)
- Append result as a system message
- Re-enter tool loop — LLM sees original question + all context + agent results
- Respond naturally (can also use read_file for more detail)
- Non-blocking — user can chat in the thread while agent runs

## Consequences
- ACP sessions become first-class extensions of the brain's thinking
- Users get actual answers, not status cards
- Multi-turn agent conversations become natural (send_input for follow-ups)
- Architecture supports parallel agents with results weaved into conversation
- Foundation for Aura delegating to other Aura instances

## Implementation Status
- Monitor (push-based, LLM summarization, edit in place): **Implemented**
- Result handback (completion → brain tool loop): **Designed, not yet implemented**
- Multi-agent parallel orchestration: **Future**
- Aura-as-execution-agent: **Future**
