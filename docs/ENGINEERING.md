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
