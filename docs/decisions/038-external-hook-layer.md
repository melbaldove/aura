# ADR-038: External hook layer — socket commands, two lanes, durable external asks

**Status:** Draft (pending acceptance)
**Date:** 2026-08-07
**Amends:** ADR 021 (protocol clause only)
**Extends:** ADR 027 (restart-cancellation pattern, different terminal outcome)
**Composes with:** ADR 026 (no public endpoints; integration boundary), ADR 028 (cognitive delivery), ADR 031 (dead-letter reuse)

## Context

Aura's only external IPC surface is the ctl Unix socket (ADR 021), whose
commands are hardcoded case clauses with no generic event injection and no
return channel. Skills are pull-only; the scheduler is poll-based; interaction
callbacks resolve only in-process approvals held in channel-actor state. There
is no way for an arbitrary same-host process to alert the user through Aura or
to receive the user's decision back.

The driving need: long-running standalone processes (browser collectors,
batch jobs, daemons we write) hit situations only the user can resolve, and
must reach him urgently through Discord — then learn what he decided.

Three architectures were considered:

- **A. Minimal socket extension** — generic `event`/`notify`/`ask`/`decision`
  commands on the existing socket; `ask` blocks and returns the decision as
  its response (the per-connection handler may already block; no FFI change);
  decisions durable in SQLite for disconnect/re-poll.
- **B. Stateful plugin protocol** — persistent connections, registration with
  capabilities, Aura pushes decisions over the held socket. Real-time push,
  but requires connection lifecycle, heartbeats, offline queuing, and an FFI
  rewrite — cost now for a benefit that only materializes with many always-on
  plugin subscribers.
- **C. MCP** — rejected. MCP is client-initiated request/response for tools;
  ad-hoc processes that initiate contact and wait on humans invert that
  relationship, and ADR 026 already established MCP's push path is
  unadopted in the ecosystem. MCP remains the LLM's action surface.

A further product constraint: the services must stay standalone and
Aura-ignorant. Aura knowledge must not be embedded in each service. And a
process-management constraint: Aura deploys SIGTERM the BEAM, so Aura must
never parent long-running plugin processes (the same reason flares delegate to
tmux).

## Decision

Adopt **Architecture A**, wrapped in a hook layer, as specified in
[`docs/architecture/external-hooks.md`](../architecture/external-hooks.md).

1. **Hook layer, not service changes.** Services emit natural outputs (stdout
   lines, log files, exit codes). A single **checkpointed stream-tail
   mechanism** applies user-authored rules to those streams and speaks the
   socket protocol on the service's behalf. Two stream sources, one rule
   engine: the `aura-hook` wrapper (spawns an ad-hoc process, tees its output
   to a log file, matches rules in-stream, returns decisions as
   files/signals/stdin) and a supervised in-daemon file tailer (follows an
   OS-managed daemon's log from a saved byte offset, resuming across restarts).
   The tee'd log file doubles as the zero-cost record lane: unmatched lines
   are retained and greppable without producing events or model calls. Rule
   files live conventionally at `~/.config/aura/hooks/<name>.toml`, which lets
   introspection list registered rulesets and lets Aura author rules
   conversationally via the existing `propose`/`write_file` tools.

2. **Aura never parents long-running plugins.** Ad-hoc processes are parented
   by the short-lived `aura-hook` CLI; daemons are parented by launchd/systemd.
   Aura may register or trigger OS units on demand, but is a client of the OS
   process manager, not one.

3. **Two lanes.** `event` injects into `event_ingest` and flows through the
   cognitive pipeline unchanged (model judges record/digest/surface_now/ask_now
   per ADR 028). `notify`/`ask` bypass model classification — urgency is
   asserted by the user's hook rule at author time — but are validated
   (known target, bounded text), deduped by caller `(source, external_id)`, and
   appended to the same delivery ledger, so ADR 031 dead-letter retry applies.
   This is the accepted exception to "integrations don't decide whether the
   user should care": hook rules are user-authored policy, not integrations.
   Lane-2 Discord messages are automatically prefixed with
   `[hook:<source>/<rule>]` provenance, so every direct interrupt visibly names
   the rule that authorized it (product invariant 15 holds structurally, not
   just in the ledger).

   **Cost model:** an unmatched stream line costs nothing (it sits in the log
   file). A matched line fires exactly one socket command — zero LLM calls for
   `notify`/`ask`, one cognitive-model call for `event`, with `(source,
   external_id)` dedupe suppressing repeats before the model is involved.
   There is deliberately no "record-only event" lane: the tee'd log file is
   the free record; `event` is reserved for lines worth a judgment.

4. **Durable external asks.** `ask` posts Discord buttons under a namespaced
   `custom_id`, persists the pending ask to a new `external_asks` table before
   posting, and blocks the socket connection until decision or expiry. Brain's
   interaction handler gains one clause for the ask namespace and resolves
   statelessly against the DB, waking the blocked handler if present. Callers
   that disconnected re-poll `decision <correlation_id>`.

5. **Restart semantics.** Pending external asks are **not** cancelled on Aura
   restart (diverging from ADR 027's outcome for shell approvals): their
   waiters are external OS processes that survive the BEAM. Buttons stay live,
   decisions record against the DB row, waiters re-poll. ADR 027 itself is
   untouched — in-process waiters are still restart-cancelled.

6. **Protocol amendment to ADR 021.** Line-delimited request/response framing
   is unchanged, but structured hook commands carry one line of JSON payload.
   ADR 021's "no JSON, plain text in, plain text out" clause is amended to:
   plain-text *framing* always; JSON *payloads* for commands that need
   structure. All other ADR 021 decisions (socket path, lifecycle, one command
   per connection, dispatcher) stand.

7. **Trust model.** Same-host same-user; filesystem permissions on the socket
   (`0600`) are the v1 boundary. No tokens. Audit via events table + delivery
   ledger. Per-source allowlists are a future config gate, not a protocol
   change.

8. **Architecture B deferred.** If always-on plugins later need Aura-initiated
   push to many subscribers, the stateful protocol can be added; the v1 command
   set is its substrate.

## Consequences

### Easier

- Any same-host process can reach the user urgently and wait on his decision,
  in any language, with zero Aura-specific code in the process itself.
- One hook mechanism, not two: the ad-hoc wrapper and the daemon tailer share
  a rule engine, and the wrapper's tee makes every observed stream a
  checkpointable file.
- The driving collector case needs only: print a line on challenge; hook rule
  maps it to an urgent alert. v1 resume stays DOM-polling; the general
  decision-return path exists for processes that want it.
- Reuse, not reinvention: dedupe (`source, external_id`), delivery ledger,
  dead-letter retry (ADR 031), delivery-target validation (ADR 028), Discord
  button plumbing, checkpoint discipline (Gmail's IMAP offset pattern).
- Zero FFI changes for the blocking `ask`; the per-connection handler model in
  `aura_socket_ffi` already supports it.
- No public endpoints; ADR 026 untouched. The integration/plugin boundary is
  explicit: Aura-initiated always-on feeds stay in-process; external-initiated
  ad-hoc processes use hooks.

### Harder

- The ctl dispatcher is no longer the whole socket story — the handler may now
  block for the TTL of an ask. Acceptable at personal scale (one spawned
  process per connection); documented in the architecture note.
- Two alert lanes means two kinds of urgency authority (model vs. hook rule).
  The boundary is documented and both lanes are ledgered, but operators must
  know which lane a given alert took — the ledger records it.
- New surface area: `external_asks` table, interaction-routing clause, hook
  rule config format, the `aura-hook` tailer CLI, and (v2) the supervised
  in-daemon tailer with durable offsets and the OS-unit registration helper.
- A hook rule that matches too broadly can spam urgent alerts. Mitigated by
  audit and the future allowlist; accepted consciously.

### Explicitly not changed

- ADR 026: no public endpoints, no MCP subscriptions; in-process integrations
  remain the home for always-on third-party feeds. Hooks are not a
  subprocess-per-source integration backdoor — they observe standalone
  processes that exist independently of Aura.
- ADR 027: shell approvals remain restart-cancelled.
- ADR 028/031: cognitive delivery and dead-letter mechanics are reused
  unchanged.
