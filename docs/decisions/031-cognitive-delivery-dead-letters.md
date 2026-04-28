# ADR-031: Cognitive delivery dead letters

**Status:** Accepted
**Date:** 2026-04-26

## Context

ADR-028 made cognitive delivery append-only and auditable, but failed sends were
only recorded as failed terminal effects. Real digest failures showed that this
was not operationally repairable: once a target channel or Discord send failed,
the decision was preserved but the user-facing effect could not be retried
without rerunning the model or editing the ledger by hand.

The invariant is that attention judgment and delivery effect are separate. A
retry should repair the effect after configuration or provider recovery; it
should not ask the model to decide again and risk changing the original
attention judgment.

## Decision

Delivery target resolution failures and Discord send failures are recorded as
`dead_letter` entries in `~/.local/share/aura/cognitive/deliveries.jsonl`.
Legacy `failed` entries for `digest`, `surface_now`, and `ask_now` remain
retryable so existing failed digest effects can be repaired.

Add `aura cognitive-delivery retry-dead-letter` as an explicit operator command.
It reads the latest delivery ledger state per event, selects retryable
dead-letter or legacy failed user-facing delivery entries, re-resolves the
current configured target, retries only the delivery effect, and appends a new
`delivered` or `dead_letter` entry. Digest retries are grouped by target.
Immediate retries send a compact message reconstructed from the ledger summary,
rationale, authority, gaps, citations, and event id.

## Consequences

Aura can recover from delivery failures without losing provenance or rerunning a
cognitive decision. The append-only ledger remains the source of truth, and a
successful retry visibly supersedes the previous failed latest state.

The command is explicit rather than automatic in v1. This avoids accidental
re-sends while the target configuration is still wrong, and keeps retry policy
out of code until replay and operational use show what automation is warranted.
There is no database migration; JSONL remains sufficient for the current slice.
