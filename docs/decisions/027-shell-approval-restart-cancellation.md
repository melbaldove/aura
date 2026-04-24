# ADR-027: Restart-cancel shell approvals

**Status:** Accepted
**Date:** 2026-04-24

## Context

Shell approvals are Discord button interactions backed by a blocked tool worker
waiting on a process-local subject. The Discord message is durable enough for a
user to click after a channel actor restart, but the waiting subject and pending
approval list are not. Treating that click as still valid would require
persisting and resuming the whole turn/tool continuation, not just the approval
metadata.

The invariant is that every tool call produces a visible outcome and dangerous
shell approval never silently disappears or resumes under guessed state.

## Decision

Persist shell approval metadata to SQLite when the Discord button message is
created. On channel actor startup, load every still-pending shell approval for
that channel, mark it `restart_cancelled`, and edit the original Discord message
to tell the user to rerun the command if it is still needed.

Normal approve/reject/expiry/supersede paths transition only rows still in the
`pending` state, so a late worker timeout cannot overwrite a restart
cancellation.

## Consequences

This preserves the no-silent-errors invariant without inventing resumable tool
continuations. A restart may require the user to rerun a dangerous shell command,
but the stale button is visibly invalidated and the approval ledger records why.

Future resumable approvals would need a larger design: durable turn state,
durable tool call correlation, and replay-safe command execution semantics.
