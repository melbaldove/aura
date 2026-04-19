# ADR-024: Dual-framework testing strategy (gleeunit + dream_test)

**Status:** Accepted
**Date:** 2026-04-19

## Context

Principle #10 (docs/ENGINEERING.md) requires every feature to ship with a
behavior test. 560+ unit tests already exist in gleeunit. Cross-cutting
workflow tests — "send a message to a domain channel, verify the LLM is
called with the right context and Discord receives the response" —
don't fit the unit-test shape. They span brain, channel actors, tool
workers, DB, Discord.

Options considered:
- A: add cross-cutting tests to gleeunit with ad-hoc structure
- B: introduce dream_test + Gherkin as a second framework; keep gleeunit
  for unit tests
- C: migrate everything to dream_test

## Decision

Option B. Separation:

- `test/aura/*_test.gleam` — gleeunit, unit + module-level tests
- `test/features/**/*.feature` — dream_test + Gherkin, cross-cutting scenarios
- `test/fakes/*.gleam` — shared fake clients (gleeunit-testable themselves)
- `test/contract/*_test.gleam` — gleeunit, live-provider contract tests
  (directory-based opt-in)

## Consequences

**Better:**
- Existing 560+ unit tests stay unchanged (no migration cost)
- Gherkin scenarios readable to any contributor — no Gleam knowledge needed
- dream_test's `{int}`, `{string}`, `{word}` captures + world KV store
  cover common scenario needs
- Scope-appropriate frameworks: BDD where cross-cutting, plain where simple

**Worse:**
- Two frameworks, two mental models
- dream_test is v2.1.1; small ecosystem risk
- Feature tests require more setup (step definitions) than unit tests

## Mitigations

- Treat Aura as an early dream_test adopter; contribute patterns upstream
  (see aura-testing(7) → UPSTREAM CONTRIBUTION)
- If dream_test stagnates, `test/features/` is rewritable in gleeunit;
  blast radius is contained

## Related

- ADR-023 (DI for external clients — provides the fake infrastructure)
- Principle #9 in docs/ENGINEERING.md (three test categories)
- Principle #10 in docs/ENGINEERING.md (verification non-negotiable)
