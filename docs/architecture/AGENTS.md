# AGENTS.md

Updated 2026-04-24

## Module Intent

`docs/architecture/` contains evolving architecture notes that are more concrete
than product principles but not always final enough to be ADRs. Use this
directory for current conceptual models, object boundaries, and implementation
direction that may later become a decision record.

## Local Guidance

- Keep notes source-neutral unless the topic is explicitly source-specific.
- Separate product intent, system invariants, and possible implementation
  phases.
- Link back to `docs/PRODUCT_PRINCIPLES.md` when a note derives from product
  philosophy.
- Link to `docs/ENGINEERING.md` when a note imposes implementation behavior.
- Promote a note to `docs/decisions/` when the team commits to a costly or
  hard-to-reverse architecture choice.

## Pitfalls

- Do not let examples from Gmail, Linear, Jira, Calendar, or Git become hidden
  assumptions in the general model.
- Do not encode policy as source-specific routing unless the note explicitly
  documents why that is acceptable.
- Avoid writing design notes that only name abstractions. Include the invariant
  each abstraction protects.

## Open Questions

- Which architecture notes should become ADRs once implementation starts?
- Should mature architecture notes get rendered into man pages for runtime
  operator access?
