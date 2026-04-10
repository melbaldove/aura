# ADR 018: Flare Architecture for Background Agents

**Status:** Accepted
**Date:** 2026-04-10
**Supersedes:** ADR 017 (Background Agent Architecture)

## Context

ACP sessions are fire-and-forget. The brain dispatches work, the monitor shows progress, the session completes, and the results are trapped. The user never gets an answer to their original question.

Beyond the handback gap, ACP sessions have no persistent identity. Each dispatch is ephemeral — there's no way to resume a previous session, schedule follow-ups, or reason about "what am I currently working on." The brain has no working memory of its delegated work.

ADR 017 proposed an OpenPoke-inspired architecture with "Interaction Agent" and "Execution Agents." The framing was wrong — it treated agents as independent entities. Aura is one mind. Its extensions should be modeled as such.

## Decision

### Flares, not agents

Aura extends itself through **flares** — persistent units of work with identity and context. A flare is not a separate agent. It's Aura reaching out. The terminology was chosen because an aura (energy field) projects flares (directed energy into the world).

### Core architecture

- **Brain** — central consciousness and sole orchestrator
- **Flare manager** — OTP actor owning the roster (identity, lifecycle, persistence). Does not know how to execute.
- **Execution layer** — pluggable. The brain decides how to execute a flare (ACP stdio, HTTP, tmux, future AuraInstance). The transport layer is unchanged.

### Persistent identity

A flare has a stable UUID that survives across executions. It can be ignited, parked, rekindled days later, and archived. Claude Code's `--resume` flag enables conversation continuity across process restarts — the flare manager stores the session ID, Claude Code stores the conversation.

### Lifecycle states

Active → Parked → (trigger) → Active → ... → Archived. No terminal state — everything can be rekindled, including archived and failed flares.

### Handback

When a flare's execution completes, results flow back to the brain's conversation as a system message. The brain re-enters the tool loop and responds naturally. The brain is the sole writer to shared memory.

### Trigger system

Flares can be rekindled by: schedule (cron), delay (one-shot timestamp), event (pattern match on incoming events, deferred), or manual (user/brain initiated). Multiple triggers per flare.

### Alternatives considered

1. **Flares as independent agents** (OpenPoke literal). Rejected — creates first-class/second-class contexts, violates "One Aura" (principle 1).
2. **Brain handles everything inline** (no separate processes). Rejected — can't do sustained parallel work (30-minute coding sessions).
3. **Extend acp_manager with identity** (minimal change). Rejected — the conceptual shift from "sessions" to "persistent extensions of Aura" justifies a new abstraction. But the implementation wraps rather than rewrites the existing transport layer.

## Consequences

### Easier
- Users get actual answers from delegated work, not status cards
- Brain can reason about ongoing work through the roster
- Scheduled and deferred work becomes possible
- Foundation for Aura delegating to other Aura instances

### Harder
- More state to manage (flare records, triggers, roster)
- Recovery is more complex (liveness checks, trigger re-registration)
- Deprecating 5 ACP tools in favor of 1 flare tool is a migration

### Implementation approach
Phased: (1) result handback, (2) unified tool, (3) flare manager + SQLite, (4) triggers and parking. Each phase deploys and verifies before the next begins. The existing acp_manager and transport layer work throughout — they are wrapped, not rewritten.
