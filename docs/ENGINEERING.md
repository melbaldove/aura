# Engineering Practice

## Principles

1. **One Aura.** There is one agent with domain knowledge partitions. Every channel gets the same capabilities. Architectural decisions that create first-class and second-class contexts are wrong.

2. **Working software is the only measure of progress.** If users can't message a channel and get real work done, nothing else matters.

3. **Vertical before horizontal.** Build one complete workflow end-to-end before building infrastructure that serves multiple workflows.

4. **Ship and verify.** Every change deploys and gets tested in the real environment in the same session. No batching.

5. **Instrument, don't theorize.** When something breaks, make the system tell you what's happening before you touch the code.

6. **Subagents are junior engineers.** Their output compiles. That doesn't mean it's correct. Review against intent, not structure.

7. **Ask, then build.** Architectural and workflow changes get brainstormed with the user first. Implementation within an agreed design does not.

8. **Every bug reveals a gap in thinking.** Fix the bug, write the test, understand what you missed.

9. **Don't break what works.** Before deploying, verify existing functionality still works. New features don't get to break old ones.

10. **Design for one, generalize later.** Solve the concrete problem in front of you. Don't abstract for hypothetical future users or platforms until a second case actually exists.

11. **Elegance and efficiency first.** The right solution is as simple as the problem. You can explain it in one sentence. It composes with the rest of the system instead of fighting it. Before writing code, ask: does this solve the general problem or patch this specific instance? Will this still make sense when the next skill, domain, or platform is added?

    **Efficiency means you got there without waste.** When the first attempt feels like it needs a workaround, that's information — the discomfort is telling you the design is wrong. Pause and redesign instead of iterating on patches. Five patches that each make the system slightly worse are not progress, even if the symptom eventually goes away.

    **Signs you're duck-taping instead of solving:**
    - Hardcoding what should be discovered at runtime.
    - Patching inputs (stripping quotes, reordering args) instead of fixing the interface that confused the caller.
    - Adding more instructions to explain how to use something — the tool should be self-evident from its interface.
    - Growing special cases: if every new input needs a new line of handling, the abstraction is wrong.

    Duck tape is sometimes unavoidable — a third-party API that doesn't work the way it should, an external system you can't control. When you do reach for it, mark it clearly and know what the real fix is. But it should never be the first option.

12. **No silent errors.** When something fails, someone must find out. Two rules: (1) LLM-facing functions never return silent defaults — if a tool call fails, the LLM gets an error string back so it can self-correct or inform the user. Returning `""` or `[]` on failure means the LLM confidently proceeds with garbage. (2) Everything else logs on error — config loading, file reads, and network calls can still fall back to defaults, but the error gets a log line. `Error(_) -> []` without a log is a bug waiting to happen. Optional absence (config field not set) is not an error — don't log that. But a parse failure, a disk error, a network timeout — those are errors, even if the system can continue without the result.

## System invariants

Properties that must hold at all times. Violations are bugs.

1. **A message is processed exactly once.** The system never processes the same incoming message twice. If it happens, it's a system bug, not an edge case to handle.
2. **Domain context is self-contained.** Everything the LLM needs to operate in a domain is discoverable from the domain directory or system prompt. No assumed knowledge that isn't explicitly provided.
3. **Every tool call produces a visible outcome.** Success or error — never silence. The LLM and the user can always see what happened.
4. **An ACP session is always in exactly one state.** States: `starting` → `running` → `complete | failed | timed_out`. Every transition emits an event to Discord. No session exists without a state. No session changes state without notification.
5. **A session that stops is always accounted for.** If a tmux session disappears, the monitor detects it and reports why — completed with report, failed without report, or timed out. No silent disappearances.
6. **One session per dispatch.** A dispatch creates exactly one tmux session and one monitor actor. The monitor dies when the session ends. No orphaned monitors, no zombie sessions.

## Domain model

- Aura is one entity with domain knowledge partitions
- Channels are context selectors, not capability boundaries
- Each domain has: AGENTS.md (domain expertise), skills, anchors, logs, conversation history
- Cross-domain access is allowed — the channel sets default context, not a wall
- #aura is the meta-domain for cross-cutting and general work

## Core slices checklist

A living list of end-to-end workflows that must always work. Verified before every deploy:

- [ ] Message any channel → response with full tool capabilities
- [ ] Conversation context recalled across turns
- [ ] Domain context (anchors, skills, AGENTS.md) loaded in domain channels
- [ ] Web search and fetch work
- [ ] ACP dispatch and monitoring work
- [ ] Learning loop saves skills and memory

## Process

- **New feature:** Brainstorm with user if architectural → agree on design → implement → deploy → verify in real environment
- **Bug fix:** Instrument → find root cause → fix → regression test → deploy → verify
- **Subagent work:** Review output against intent, not just compilation. Check SQL semantics, check data flow, check edge cases.
