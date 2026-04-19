# Aura feature tests

dream_test + Gherkin scenarios verifying Aura's end-to-end behavior.

## Quick start

Full guide: `man aura-testing`.

### Layout

- `workflows/` — user-observable journeys
- `capabilities/` — per-tool / per-module behavior
- `fault-tolerance/` — failure modes and recovery
- `steps/` — Gleam step definitions grouped by concept (common / llm / tool)

### Add a scenario

1. Pick the right subdirectory
2. Write a `.feature` file with Given/When/Then
3. If a step is new, add it to the right `steps/*.gleam` module
4. Run `gleam run -m features/runner`
5. Commit

### Running

```
gleam test                          # unit tests (test/aura/)
gleam run -m features/runner        # all feature scenarios
```
