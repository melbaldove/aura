# Engineering Practice

This document describes how we build Aura. Product-level constraints on what
Aura is for live in [`PRODUCT_PRINCIPLES.md`](PRODUCT_PRINCIPLES.md). Current
architecture models live under `docs/architecture/` until they are accepted as
ADRs.

## Philosophy

Aura's design draws from two battle-tested traditions. **Unix philosophy** governs interfaces — how Aura touches the world, presents information, and composes capabilities. **OTP philosophy** governs the runtime — how Aura stays alive, manages state, and recovers from failure.

### Unix philosophy

Applies to: skills, tools, documentation, file formats, configuration, extensibility.

**Do one thing well.** A skill monitors Linear. A different skill formats digests. They don't know about each other. Tools are atomic — `read_file` reads, `write_file` writes. If a flare has two independent tasks, dispatch two flares.

**Text is the universal interface.** Memory is keyed plaintext (`§ key`). Config is TOML. Logs are JSONL. Skills communicate via stdin/stdout. If you can't `cat` it, it's wrong. No binary state, no opaque blobs.

**Compose, don't extend.** Schedules invoke skills. Skills call CLI tools. The brain composes tools. New capability = new small piece, not a bigger existing piece. When something needs to do more, add a new thing that works with it — don't make it bigger.

**Separate mechanism from policy.** The brain is mechanism (tool loop, routing, streaming). SOUL.md is policy (personality). AGENTS.md is policy (domain expertise). Config is mechanism. Don't encode behavior in the engine.

**Everything is a file.** Config in `~/.config/aura/` (XDG). State in `~/.local/state/aura/`. Data in `~/.local/share/aura/`. Documentation via man pages. The filesystem is the API.

**Fail noisily.** Tool calls always return results — success or error, never silence. LLM-facing functions never return silent defaults (`""` or `[]` on failure means the LLM confidently proceeds with garbage). Everything else logs on error. Optional absence is not an error; parse failures, disk errors, and network timeouts are — even if the system can continue without the result.

**Transparency over cleverness.** Every ACP session emits progress. Every state change is visible. If you can't see what the system is doing, the system is wrong. When something breaks, make the system tell you what's happening before touching code.

**Parsimony.** Solve the concrete problem. Don't abstract for hypothetical futures until a second case exists. When you do generalize, verify every assumption from the original design still holds — if any breaks, redesign from the new constraints.

**Signs you're duck-taping instead of solving:**
- Hardcoding what should be discovered at runtime.
- Patching inputs instead of fixing the interface that confused the caller.
- Adding instructions to explain a tool — the interface should be self-evident.
- Growing special cases: if every new input needs a new handler, the abstraction is wrong.

Duck tape is sometimes unavoidable (third-party APIs, systems you can't control). Mark it clearly, know what the real fix is. Never the first option.

**Man pages.** `man aura`. `man aura-flares`. Same tool for humans and the LLM. Documentation is a first-class Unix interface, not an afterthought.

### OTP philosophy

Applies to: runtime architecture, actors, state, fault tolerance.

**Let it crash.** Actors restart independently. A crash in the brain doesn't take down the poller. A crash in a flare monitor doesn't take down the brain. Write code for the happy path; let the supervisor handle the rest.

**Supervision trees.** OneForOne — each actor is an isolated failure domain. The supervision tree is the architecture diagram.

**Message passing.** Actors communicate via messages, not shared state. The db actor serializes all database access. The flare_manager owns the flare roster. No process reaches into another's state.

**State encapsulation.** Actor state is private. Public functions send messages and wait for replies. The internal representation can change without breaking callers.

### Metacognitive philosophy

Applies to: user experience, observability, policy, learning surfaces.

**Know what you don't know.** Aura treats its own ignorance as a first-class event. When a gap in heuristics, preferences, context, or state is encountered, surface it — don't silently default. Absence of configured behavior is a signal, not a non-event.

**Introspect before defaulting.** Before falling through to a default, check: do I know what to do here? If not, capture the gap and ask. The answer becomes durable policy.

**Conversation is configuration.** User preferences, routing rules, classification thresholds — learned through natural-language exchange, not config files. The user never has to learn the schema.

**Proactive disclosure over silent correctness.** Better to say "I noticed X and wasn't sure what to do" than to guess right 80% of the time and wrong the other 20%. Visibility over cleverness.

**The gap is the event.** Every site where Aura could silently default deserves a gap-detection hook. Design reviews ask "what does Aura do when this state is missing, stale, or ambiguous?" before asking "what does it do when valid?"

**Precise help over generic failure.** When Aura cannot responsibly proceed, it
should say what is missing, what it already tried, what the impact is, and what
the next useful options are. "I failed" is not enough. Tool gaps, permission
gaps, credential gaps, context gaps, preference gaps, verification gaps,
authority gaps, and confidence gaps are different states with different
resolution paths.

**When not to apply.** Don't surface truly ambiguous signals conversation can't resolve (delete-vs-archive spam). Batch high-frequency gaps to avoid noise. Safety-critical defaults should act first and disclose, not ask.

## Principles

What Unix, OTP, and metacognition don't cover — Aura-specific constraints and process.

1. **One Aura.** There is one agent with domain knowledge partitions. Every channel gets the same capabilities. Architectural decisions that create first-class and second-class contexts are wrong.

2. **Working software is the only measure of progress.** If users can't message a channel and get real work done, nothing else matters.

3. **Ship and verify.** Every change deploys and gets tested in the real environment in the same session. No batching.

4. **Subagents are junior engineers.** Their output compiles. That doesn't mean it's correct. Review against intent, not structure.

5. **Ask, then build.** Architectural and workflow changes get brainstormed with the user first. Implementation within an agreed design does not.

6. **Every bug reveals a gap in thinking.** Fix the bug, write the test, understand what you missed.

7. **Don't break what works.** Before deploying, verify existing functionality still works. New features don't get to break old ones.

8. **Read the spec, don't guess.** When integrating with a protocol, API, or external system, read the official documentation or source code before writing a single line. Guessing at message formats, field names, or response structures creates bugs that compound. If no spec exists, read the implementation. If you can't read the implementation, write a test harness that logs the actual wire format. "It's probably like this" is not engineering.

9. **Test at the lowest layer that exercises the behavior.** Most tests are fast, deterministic, and run on every change. A minority are slow and reality-checking. Keep them separated: when Discord has an outage, CI should not block; when our code breaks, a provider should not be suspected. Every test fits exactly one of three mutually exclusive categories:

    - **Behavior tests** (the bulk). Does my code do the right thing? Unit tests of pure functions and system-integration tests of actors running in a real BEAM with faked network boundaries. Fast, deterministic. Covers state machines, error paths, concurrency, supervision, data transformations.
    - **Contract tests** (the minority). Does the external world behave the way I assume? Live calls to z.ai, Discord, Google, Jira. Run on demand, not per commit. A failure means a provider changed something, not that we broke.
    - **Fault-injection tests** (a subset of behavior tests, important enough to name). Does my code recover when things break? Inject stream stalls, worker crashes, DB errors, malformed responses. Without these, "let it crash" is aspiration, not verified behavior.

    Shape: many behavior tests (sub-second each), few contract tests (dozens, on demand), fault injection woven through behavior tests where recovery matters. Anti-pattern: most coverage from true end-to-end tests — produces slow feedback, flaky runs, and a suite nobody trusts.

10. **Verification is non-negotiable. Every feature ships with a behavior test.** Code is cheap to write; parallelize test authoring via subagents when the surface is wide. A feature without a test is an untested assumption, not a feature. The bar: there is a test that *fails without your change and passes with it*. "It compiled" and "I tried it once in Discord" are not verification. Without this rule, coverage always loses to velocity, and velocity compounds into regression debt that eventually stops the system from being changeable at all. Tautological or empty tests (asserting literals, no assertions, mocks asserting their own return values) are the same as no test — the trivial-test hook exists to catch them.

## System invariants

Properties that must hold at all times. Violations are bugs.

1. **A message is processed exactly once.** The system never processes the same incoming message twice. If it happens, it's a system bug, not an edge case to handle.
2. **Domain context is self-contained.** Everything the LLM needs to operate in a domain is discoverable from the domain directory or system prompt. No assumed knowledge that isn't explicitly provided.
3. **Every tool call produces a visible outcome.** Success or error — never silence. The LLM and the user can always see what happened.
4. **An ACP session is always in exactly one state.** States: `starting` → `running` → `failed`. Completion is declared by the user, not the system. There are no timeouts — flares run until done or explicitly stopped. Every transition emits an event to Discord. No session exists without a state. No session changes state without notification. For stdio sessions, `end_turn` is a turn boundary, not session completion — the session stays active until the process exits or is killed.
5. **A session that stops is always accounted for.** If a tmux session disappears, the monitor detects it and reports why — completed with report, failed without report. No silent disappearances.
6. **Active flare ↔ active monitor.** A dispatch creates exactly one session and one monitor actor. The monitor lives as long as the flare is active — it never stops itself. The monitor is stopped explicitly when the flare is killed, parked, or archived via the session handle. On rekindle, a fresh monitor is created with the new session. No orphaned monitors, no zombie sessions.
7. **Handback is never silent.** When an ACP session completes with `end_turn`, the brain always processes the result through the tool loop. If the tool loop fails, the raw result is posted to Discord as a fallback. No completion goes unacknowledged.
8. **Gaps are explicit.** Missing tools, access, credentials, context, specs, preferences, verification paths, authority, or confidence must be represented as visible gap states with a resolution path. Aura must not continue low-value motion when the next responsible action is to ask, defer, delegate verification, or stop.

## Domain model

- Aura is one entity with domain knowledge partitions
- Channels are context selectors, not capability boundaries
- Each domain has: AGENTS.md (instruction), STATE.md (current status), MEMORY.md (learned knowledge), log.jsonl (event history), skills, conversation history
- Cross-domain access is allowed — the channel sets default context, not a wall
- #aura is the meta-domain for cross-cutting and general work

## Core slices checklist

A living list of end-to-end workflows that must always work. Verified before every deploy:

- [ ] Message any channel → response with full tool capabilities
- [ ] Conversation context recalled across turns
- [ ] Domain context (AGENTS.md, STATE.md, MEMORY.md, skills) loaded in domain channels
- [ ] Web search and fetch work
- [ ] ACP dispatch and monitoring work
- [ ] Learning loop saves skills and memory

## Process

- **New feature:** Brainstorm with user if architectural → agree on design → implement → deploy → verify in real environment
- **Bug fix:** Instrument → find root cause → fix → regression test → deploy → verify
- **Subagent work:** Review output against intent, not just compilation. Check SQL semantics, check data flow, check edge cases.
