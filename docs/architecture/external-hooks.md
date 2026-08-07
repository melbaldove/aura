# External Hook Layer

Status: Agreed design, pending ADR acceptance
Date: 2026-08-07
ADR: [`docs/decisions/038-external-hook-layer.md`](../decisions/038-external-hook-layer.md) (draft)

Derives from `docs/PRODUCT_PRINCIPLES.md` (attention is deliberate; integrations
are evidence feeds) and `docs/ENGINEERING.md` (Unix philosophy: text interfaces,
compose don't extend, everything is a file; OTP philosophy: supervise, never
parent what you can't restart).

## Intent

Aura is the single interaction point with the user. Arbitrary same-host
processes — scripts, collectors, daemons we build — should be able to reach the
user through Aura (urgent alerts, approval requests, progress events) and
receive the user's decisions back, **without those processes knowing Aura
exists**.

Services stay standalone and Aura-ignorant. All Aura knowledge lives in a thin
hook layer on Aura's side.

Driving example (source-specific, not part of the model): a browser-automation
collector hits an anti-bot challenge. It merely prints a line to stdout and
keeps polling the page. A hook rule turns that line into an urgent Discord
alert. The user solves the challenge in the live window; the collector notices
on its own. Optionally, the hook asks a blocking question ("Resolved / Abort")
and materializes the answer where the collector already looks.

## Model

A hook is a **checkpointed stream tailer with a rule set**. One mechanism, two
stream sources:

```
source                        mechanism
----------------------------  ---------------------------------------------
(1) ad-hoc process:           aura-hook run --rules x.toml -- <cmd>
    spawned by the wrapper    parents the child, tees stdout/stderr to a log
                              file, applies rules to the stream as it passes,
                              returns decisions as files/signals/stdin.
                              Exits with the child. Not daemon-managed.

(2) OS-managed daemon:        a supervised tailer inside Aura follows the
    launchd/systemd unit      daemon's log file from a saved byte offset,
    writes a log file         applying the same rules. Restarts resume from
                              the checkpoint — no missed lines, no re-fired
                              alerts. Same checkpoint discipline as the Gmail
                              integration's IMAP UID checkpoint.

(3) scheduler → skills        existing path for recurrent short tasks;
                              unchanged

        rule matches fire ──▶ hook commands on the ctl socket
                                          │
                   ┌──────────────────────┼───────────────────────┐
                   ▼                      ▼                       ▼
                event                 notify / ask            decision
              (cognitive            (direct lane,          (re-poll a
               pipeline,             hook-rule-authorized)  recorded ask)
               ADR 028)
```

Properties that fall out of "everything is a file tail":

- **The log file is the zero-cost record lane.** A line that matches no rule
  still exists — in the file, greppable — without costing an event or a model
  call. Rules are the volume control.
- **Checkpointing** (saved offset per tailed file) gives restart resume and
  Aura-downtime catch-up for free: lines accumulate in the file and are
  processed on return.
- **The daemon's surface stays minimal.** Aura proper only ever runs
  supervised file tailers; it never manages pipes or children.

**Aura never parents long-running plugin processes.** Ad-hoc runs are parented
by the `aura-hook` wrapper (a short-lived CLI Melbourne invokes, not by the
daemon). Always-on services are parented by launchd/systemd, which Aura may
*trigger* but never replaces. This mirrors the flare/tmux split: the BEAM is
SIGTERM'd on every deploy, so nothing long-lived may hang off it directly.

## The hook rule

The hook rule is the unit of user policy in this layer. A rule binds:

- a **match** (stdout line pattern, or spooled file shape),
- to a **lane** (`event`, `notify`, or `ask`),
- with **content** (text template; button labels for `ask`),
- and a **target** (`default` or `domain:<name>`, validated against configured
  delivery targets).

Rules are ordinary user-authored config (TOML, like schedules). The judgment
"this line is urgent" is made when the user writes the rule — not by the
service, which just prints lines, and not by the model at runtime.

Rule files live conventionally at `~/.config/aura/hooks/<name>.toml`. The
canonical location lets `aura hooks` list registered rulesets, and lets Aura
itself author rules conversationally through the existing `propose`/`write_file`
tools — conversation is configuration. `aura-hook run --rules` may still point
at an explicit path for ad-hoc runs.

## Two lanes

| | Lane 1: `event` | Lane 2: `notify` / `ask` |
|---|---|---|
| Who judges urgency | The model (cognitive pipeline) | The user's hook rule, at author time |
| Path | event_ingest → dedupe → cognitive_worker → validated decision → cognitive_delivery (ADR 028) | validate → persist audit event → direct Discord send → delivery ledger |
| Model in the loop | Yes | No |
| Use for | progress, status, ambient signals | blocked processes, time-critical alerts, decisions the process waits on |
| Failure mode accepted | model may downgrade (tunable via policies/labels) | any same-user process with socket access can alert (audited; allowlist is a future config gate) |

Both lanes dedupe by caller-supplied `(source, external_id)`. Both lanes append
to the existing delivery ledger, so ADR 031 dead-letter retry works unchanged.

Why lane 2 may bypass the model without violating product principle 9:
principle 9 constrains *integrations* — evidence feeds Aura subscribes to —
from becoming policy engines. Hook rules are not integrations; they are the
user's own policy in config form. Product invariant 15 (justify why-now) is
satisfied structurally: every lane-2 Discord message is automatically prefixed
with its provenance — `[hook:<source>/<rule>]` — so an interrupt always names
the rule that authorized it, regardless of how terse the rule's text is; the
ledger records source, text, and correlation ID alongside.

## Cost model

- **Unmatched line: free.** It lands in the log file. No event, no model call.
- **Matched line: the rule's lane decides.** One match fires exactly one socket
  command. `notify`/`ask`: zero LLM calls. `event`: one cognitive-model
  decision call.
- **Dedupe damps repeats.** Rules extract `external_id`s (e.g. a run ID); a
  repeated line with an already-seen `(source, external_id)` is suppressed at
  ingest and never reaches the model.
- The one expensive shape is a high-volume stream of *distinct* events that
  all warrant judgment. That is inherent to the cognitive pipeline (ADR 028),
  not specific to hooks; the mitigations are the same as for any source:
  narrower rules, or digest windows batching delivery.

So the default is: a line costs nothing unless a rule both matches it and maps
it to `event`. Both halves are user policy, written in the rule file.

## Wire protocol

The existing ctl socket (`~/.local/state/aura/aura.sock`, ADR 021) gains four
commands. Line framing is unchanged — one command per line, response lines,
close. Structured commands carry **one line of JSON** as the payload. This
amends ADR 021's "plain text only" clause explicitly (see ADR 038).

```
event {"source":"...","type":"...","subject":"...","external_id":"...","data":{...}}
  → OK: event_id=...        (or OK: deduped)

notify {"source":"...","target":"default|domain:<name>","text":"...","external_id":"..."}
  → OK: delivered event_id=...   (or OK: deduped / ERROR: ...)

ask {"source":"...","correlation_id":"...","target":"...","text":"...",
     "buttons":["Resolved","Abort"],"ttl_minutes":60}
  → blocks until decision, expiry, or disconnect; then one line:
    RESOLVED <correlation_id> <choice>    |    EXPIRED <correlation_id>

decision <correlation_id>
  → RESOLVED <correlation_id> <choice>  |  PENDING  |  EXPIRED  |  UNKNOWN
```

`ask` blocking needs no FFI change: `aura_socket_ffi` already spawns one
process per connection and calls the handler synchronously; the handler waits
on a subject. The 5s socket timeout covers reading the command line, not the
handler. A hook that doesn't want to block sends `ask` on one connection and
polls `decision` on others.

`ask` is idempotent by `correlation_id`: a duplicate `ask` while pending
returns the in-flight state; after resolution it returns the recorded decision.
An ask that arrives while no blocking waiter is attached simply persists —
decisions are looked up, not pushed.

## Decision return and interaction routing

Pending asks live in a new `external_asks` table (correlation ID, source,
channel, message, text, buttons, status, decision, timestamps), written before
the Discord message is posted — same ledger discipline as shell approvals.

Ask buttons use a namespaced `custom_id` (e.g. `xask|<channel>|<correlation_id>|<choice>`).
Brain's interaction handler currently routes only `{action}:{channel}:{id}`
triplets to channel actors and drops the rest; it gains one clause that
recognizes the ask namespace and resolves **statelessly**: look up the ask in
the DB, record the decision, edit the message, and wake the blocked handler if
one is registered in a small in-memory waiter map. No channel-actor state, so
no restart window where a click is dropped.

## Restart semantics (extends the ADR 027 pattern)

Shell approvals are restart-cancelled because their waiter is an in-process
subject that dies with the BEAM. External ask waiters are separate OS processes
that **survive** an Aura restart, so asks are *not* cancelled on restart:

- Pending asks persist; their Discord buttons stay live.
- A click after restart resolves against the DB row — no in-memory state
  needed.
- The hook's blocked connection died with the restart; it reconnects and polls
  `decision <correlation_id>`, learning `PENDING` or the recorded choice.
- Expiry (`ttl_minutes`) still applies: expired asks edit their Discord message
  and resolve blocked waiters with `EXPIRED`.

Same discipline as ADR 027 — persist at creation, every terminal state visible —
with a different terminal outcome, justified by the different waiter topology.

## Trust model

Same-host, same-user. The socket lives in the user-private state directory;
filesystem permissions are the v1 boundary (socket created `0600`). No tokens.
Anything running as the user could already message the user by other means;
the audit ledger (who sent what, when, from which source) is the real control.
If hooks proliferate or the socket is ever shared, a per-source allowlist or
token is a config addition, not a protocol change.

## Introspection

- `asks` — list pending/recent asks with status (reads `external_asks`).
- `hooks` — registered rulesets (from `~/.config/aura/hooks/`) plus recent hook
  activity by source (reads events + delivery ledger).
- Existing `status` gains an `asks pending=N` field.
- Full audit trail already exists: events table, `decisions.jsonl`,
  `deliveries.jsonl`.

## Boundaries and graduation

| Shape | Home |
|---|---|
| Always-on feed Aura connects out to, credentials, high volume | in-process integration (ADR 026), e.g. gmail.gleam |
| User-run or OS-managed process, any language, initiates contact, may wait on a decision | **hook** (this layer) |
| Recurrent short task, pull-based | scheduler → skill (existing) |
| Action the LLM takes on an external service | MCP tool surface (ADR 026) |

Graduation: a hook whose daemon becomes always-on and chatty earns an
in-process integration. A hook pattern that needs Aura-initiated push to many
subscribers earns the deferred stateful protocol (Architecture B in ADR 038).

Hooks are not a backdoor around ADR 026: an *integration* (a process whose only
job is feeding Aura a third-party feed) still belongs in-process. Hooks observe
standalone processes that do their own job whether or not Aura exists.

## Phasing

- **v1**: socket commands (`event`, `notify`, `ask`, `decision`), `external_asks`
  table + interaction routing, `aura-hook` wrapper (spawn, tee to log file,
  apply TOML rules, decision return), `asks`/`hooks` introspection. Sufficient
  for the driving example.
- **v2**: supervised in-daemon file tailer reusing the same rule engine, with
  durable per-file offset checkpoints, for OS-managed daemons; launchd/systemd
  unit registration helper (renders a unit, bootstraps it, points a tailer at
  its log).
- **Deferred**: persistent push protocol (Architecture B in ADR 038),
  allowlists/tokens, multi-user trust.

## Invariants this layer protects

1. Every hook-triggered user-facing send is ledgered with source and
   correlation ID — no silent notifications.
2. Every ask reaches a visible terminal state: resolved, expired, or (hook
   gone) pending with a live button — never dropped.
3. Services carry zero Aura knowledge; the hook layer is the only place the
   protocol exists.
4. Aura never parents long-running plugin processes.
5. Lane 2 urgency is user-authored policy; lane 1 judgment stays with the
   model. Neither impersonates the other.
6. Hook cost is rule-gated: unmatched stream lines never produce events or
   model calls.
