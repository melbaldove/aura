# ADR-030: Text-First Concern Tracking

**Status:** Accepted
**Date:** 2026-04-26

## Context

Aura needs a durable way to remember what the user cares about so future
observations can be interpreted against live work, risks, relationships,
deadlines, theses, and open questions.

The user should not have to know or administer an internal "concern" abstraction.
At the same time, ambient cognition cannot stay useful if every source event is
judged in isolation. Previous design options risked overbuilding a typed
concern schema, source-specific routing tables, or command-specific prompt
rules.

The governing engineering constraint is the Bitter Lesson principle: use a
minimal harness, ordinary text policy/state, model judgment, validation, and
replay before promoting structure into code.

## Decision

Aura will track concerns as ordinary markdown files under
`~/.local/state/aura/concerns/`.

The LLM-facing mechanism is a built-in `track` tool with four actions: `start`,
`update`, `pause`, and `close`. The tool writes a readable markdown file with
summary, why it matters, current state, watch signals, evidence, authority,
gaps, and recent notes.

Code owns only deterministic safety and persistence:

- Validate the action.
- Validate a stable lowercase kebab-case slug.
- Constrain writes to the XDG concern directory.
- Run the existing prompt-injection/security scan before persistence.
- Fail noisily on missing targets or disk errors.

Policy owns when tracking is appropriate. A default `concerns.md` policy tells
the model to track only durable objects of care, work, watch, risk, or taste;
to avoid tracking one-off lookups and generic preferences; and to surface a gap
when durable intent is plausible but unresolved.

## Consequences

This gives Aura a general addressable object of care without a typed concern
database or hard-coded source ontology.

Directed conversation and ambient cognition share the same substrate: a user can
say "watch this" or Aura can later update the same concern from an email,
ticket, calendar event, branch change, or world-state observation.

The model can decide whether a thing is durably alive, while code keeps the
filesystem safe and auditable. Replay remains the bar for adding structure: if
markdown concern files plus model judgment repeatedly fail labeled examples, add
the smallest structure proven necessary by those failures.
