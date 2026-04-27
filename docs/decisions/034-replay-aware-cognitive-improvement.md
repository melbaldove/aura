# ADR-034: Replay-aware cognitive improvement proposals

**Status:** Accepted
**Date:** 2026-04-27

## Context

Aura can capture correction labels and generate label-grouped patch briefs, but
label grouping alone is not enough to justify changing policy. A correction
should be tested against the current worker/model/policy path first so the
proposal shows whether the current system still fails, already passes, or lacks
enough expectations to evaluate.

The tempting shortcut is to mutate policy as soon as feedback is captured. That
would hide learning behind automation and risk overfitting one complaint into a
durable rule. The product principle is instead auditable learning: corrections
become examples, examples become replay evidence, and replay evidence motivates
ordinary text changes.

## Decision

Add `cognitive-improve propose`.

The command loads `labels.jsonl`, reruns labeled events through the existing
cognitive replay path, groups the resulting cases by likely text surface, and
writes a markdown report under:

```text
~/.local/share/aura/cognitive/improvement-proposals/<timestamp>.md
```

The report includes replay counts, pass/fail/skipped status per case, actual
attention/work/authority outputs, validation errors, event summaries, notes,
and patch briefs for the relevant policy or concern surface.

The command does not apply policy or concern changes. Text mutation remains a
separate approval-gated step.

## Consequences

The learning loop now has before-proof: a proposed improvement is tied to live
replay evidence instead of only a label category. This keeps the implementation
aligned with the Bitter Lesson principle: use replay and examples rather than
hard-coded cognitive theory.

Running improvement proposals can call the configured cognitive model for each
labeled event, so it is an explicit operator command rather than an ambient
background side effect.
