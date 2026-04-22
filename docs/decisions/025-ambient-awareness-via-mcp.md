# ADR 025: Ambient Awareness via MCP and Generalized Flares

**Status:** Superseded by ADR 026
**Date:** 2026-04-22
**Extends:** ADR 018 (Flare Architecture), ADR 020 (Memory Dreaming)
**Superseded:** Two load-bearing assumptions failed on contact with reality — MCP `resources/subscribe` is not adopted in the ecosystem (optional in spec, implemented almost nowhere), and webhooks require a public HTTPS endpoint incompatible with A.U.R.A.'s home-laptop deployment stance. See ADR 026 for the revised approach.

## Context

Today A.U.R.A. knows only what the user says in Discord. Anything happening elsewhere — an email landing, a Linear ticket updating, a calendar invite arriving — is invisible until the user mentions it. This creates a repeating friction: re-briefing A.U.R.A. on context it could have observed for itself, and missing the moment when something needs attention.

We also have an existing abstraction — flares (ADR 018) — that nearly fits the shape we need for long-lived per-subject context, but is currently coupled to ACP-dispatched coding work. Its roster, lifecycle, rekindle-on-schedule, and handback loop are all usable for non-coding subjects; the binding to ACP is the only thing in the way.

Separately, the Model Context Protocol (MCP) has stabilized a resource-subscription mechanism (`resources/subscribe` + `notifications/resources/updated`) that is LLM-native and has a growing ecosystem of server implementations for the services the user actually touches (Gmail, Linear, Calendar, Slack, Notion, GitHub).

Three options were in play:

1. Build a new abstraction ("tracks") alongside flares for ambient awareness.
2. Generalize flares to cover any long-lived subject, using MCP as the event substrate.
3. Defer — keep the current "user tells us" model and invest elsewhere.

## Decision

### Generalize flares; adopt MCP as the event substrate

Flares become the universal primitive for any long-lived subject — a person, an email thread, a project, a topic, a commitment, or still an ACP-dispatched coding task. The coding-task case becomes one specialization (`session: Some(AcpSession)`), not the identity of the abstraction.

MCP is the primary integration surface for external events. `mcp_client_pool` (a `factory_supervisor`) owns one child actor per configured server. Events normalize into a CloudEvents-shaped `AuraEvent` envelope at `event_ingest`, dedupe by `(source, external_id)`, get tagged (rules + LLM classifier), persist to an `events` table, then route to flares whose selectors match.

### Flare is reactor, brain is interactor

A flare is not a passive record. When an event is delivered, `flare_manager` spawns a short-lived `flare_worker` that loads the flare's context + policies + the event, runs a single LLM call, and emits a decision (Log / Notify / Act / Propose). The worker executes the decision — updating flare state, invoking MCP tools, or routing a surface through brain — then dies.

Brain remains the user-facing interactor: it handles Discord conversations, creates/finds/resolves flares on behalf of the user, and presents flare surfaces to the user. The flare's decision locus is the flare+event pair; the brain's decision locus is the user+turn pair. Both share AURA's identity (SOUL, USER, policies); they're different roles of the same agent, not separate agents.

### Selectors, not skills, on the flare

Each flare carries a `selector_description` (English, brain-authored) and a `selector_predicate` (compiled). Predicates are a small algebra: field-match AND/OR/NOT for the fast path, `FuzzyMatch(hint)` for an LLM classifier fallback when needed. Users never see predicates; they see the English description and can edit it in chat.

Flares do **not** carry per-flare behavioral skills. Identity-by-transcript (OpenPoke's insight) is sufficient — the accumulated event log + label + summary specializes a flare. Capability skills (`gmail/SKILL.md`, `linear/SKILL.md`) stay global and get loaded contextually when their tools come into scope, as A.U.R.A. already does.

### Notification is flare-owned, policy-guided

Notification is not a flag on the flare and not a separate central notifier. It's part of the per-event decision the `flare_worker` makes, scoped to the flare's context, with global and domain policies (`~/.config/aura/policies/notification.md`) as scaffolding. Policies are a distinct config class from skills — skills teach how to use a capability; policies specify when and whether A.U.R.A. should act.

### Autonomy via the existing tier system

Flares act through tools. Tools carry tiers (`Autonomous` / `NeedsApproval` / `NeedsApprovalWithPreview`) — the same system A.U.R.A. already uses for file writes. MCP tool tiers are classified at server discovery via a small LLM call, cached, and user-reviewable.

Default posture is restrictive: flares can read and draft freely, but sending / closing / deleting require approval surfaced as a proposal. A future expansion slot (`autonomy_grants`) on the flare record allows per-flare, per-tool grants with conditions; left unimplemented in v1 but present on the record for forward compatibility.

### Users never see flares

Users speak naturally: "track this," "what's up with X," "stop." Brain orchestrates flare creation, lookup, update, and resolution through internal tools (`find_flares`, `load_flare`, `create_flare`, `update_flare`, `resolve_flare`, `park_flare`, `search_events`). Flare labels are brain-generated using naming conventions from `flare-management.md`. The abstraction stays below the conversation surface.

### Alternatives considered

1. **New "track" primitive alongside flares.** Rejected — splits the abstraction and creates first-class/second-class contexts. Principle 1 (One Aura) forbids it.
2. **Per-flare skill attachment.** Rejected — OpenPoke demonstrates identity-by-transcript works without pinned skills, and adding skill-binding introduces composition and versioning ceremony without proportional benefit.
3. **Tag-based inverted index for routing.** Rejected for v1 (may revisit). Per-flare predicate evaluation is cheap enough at personal scale; inverted index can be added later without API change.
4. **Shared brain with event-context injection.** Rejected — would serialize all event handling through brain's mailbox and mix ambient event handling with user-facing conversation. Per-event flare workers preserve parallelism and match A.U.R.A.'s existing worker pattern.
5. **Flare as passive data, brain as sole agent.** Rejected — every event would require a full brain turn to decide, coupling ambient work to the user-facing loop.

## Consequences

### Easier
- A.U.R.A. has ambient awareness without user briefing — the most visible user-facing benefit.
- Per-subject persistent context (thread, person, project, commitment) answers repeat questions without re-explaining.
- MCP ecosystem growth translates directly into new A.U.R.A. capabilities with zero per-integration glue work.
- Dreaming extends naturally to flare logs; cross-flare fact promotion reduces re-derivation cost.
- Flare-worker per-event isolation gives BEAM-native parallelism for ambient work.

### Harder
- The LLM tagger at ingestion is load-bearing — bad tagging produces bad routing. Cost budget (heartbeat-model calls per event) must be monitored.
- Per-flare per-event LLM decisions add cost that scales with event volume. Policies must lean toward Log as the default; policy quality is now first-class.
- MCP auth is a new UX surface (in-chat device-code flow). Getting OAuth flows right across providers (Gmail, Linear, Notion, Slack, GitHub) is real work.
- The tier system expands from file writes to MCP tools; tier classification at discovery needs to be reliable or safety degrades.
- Schema additions: `events` table, `flare_events` join, selector columns on flare, policy files, MCP config. Migrations and defaults for existing flares.

### Notes on compatibility
- Existing ACP-bound flares continue to work unchanged — they become flares with `session: Some(AcpSession)` and a selector tuned to match their handbacks.
- `flare_manager` gains the `spawn flare_worker on event` responsibility but keeps its current roster/persistence/lifecycle role.
- `static_supervisor` for the MCP pool is insufficient because servers can be added at runtime via chat auth; the pool uses `factory_supervisor`.
- `channel_actor` refactor (already landed) is load-bearing for flare surfacing: parallel per-channel actors mean many flares can surface to their threads concurrently without interruption.

### Implementation phasing
Seven phases, each shipping independently with verification: (1) event pipeline + Gmail, (2) selectors + routing + log-only workers, (3) full decision loop + policies, (4) in-chat MCP auth + tier classification, (5) lifecycle automation, (6) dreaming integration, (7) ambient creation. Spec: `docs/superpowers/specs/2026-04-22-ambient-awareness-flares-design.md`.
