# Engineering Practice

## The Rule

Before starting any feature, ask: **"Does this make Aura do work for me today?"**

If no, it goes to the backlog. No exceptions for "foundational" work, "open source readiness", or "Hermes alignment." Infrastructure that doesn't serve a working feature is waste.

## Priority order

1. **Vertical slices** — end-to-end features that work on Discord. "Message workstream → tools execute → result appears." Always first.
2. **Bugs in working features** — if something that WAS working breaks, fix it before building new things.
3. **Horizontal infrastructure** — persistence, streaming, compression, etc. Only when a vertical slice is blocked by missing infrastructure.
4. **Polish** — docs, tests, refactoring, open-source prep. Last. Never before function.

## Definition of done

A feature is done when:
- [ ] It works on Discord (not just passing tests)
- [ ] You can explain what user action triggers it and what visible result it produces
- [ ] It has been used for real work, not just demoed

A feature is NOT done when:
- It compiles
- Tests pass
- It's deployed
- It has docs

These are necessary but not sufficient. If nobody used it for real work, it's not done.

## Anti-patterns we've hit

| Anti-pattern | Example | Rule |
|---|---|---|
| **Shiny feature bias** | Building Hermes learning loop before workstreams have tools | Vertical slices first |
| **Comparison-driven development** | "Hermes does X, we should too" without checking if X serves our user | Does it make Aura do work today? |
| **Horizontal layer building** | SQLite migration, context compression, FTS5 before workstreams can read files | Infrastructure follows features, not the reverse |
| **Polish before function** | 10 ADRs, ARCHITECTURE.md, CONTRIBUTING.md while workstreams are broken | No polish before function |
| **Review without testing** | Spec review passed but SQL returned oldest messages | End-to-end test on Discord, always |

## Process for new work

1. **State the user story:** "As Melbs, I want to [action] so that [outcome]."
2. **Check:** Does this serve a working vertical slice? If no, backlog it.
3. **Build the thinnest possible version** that works end-to-end on Discord.
4. **Test it yourself on Discord** — not just unit tests.
5. **Then** add tests, docs, polish.

## Backlog discipline

The backlog is not a commitment. Items in the backlog are ideas, not promises. Before picking up a backlog item, re-ask: "Does this make Aura do work for me today?"

If the answer changed since the item was filed, delete it.
