# Multi-Client / Beacon Protocol — Exploration

**Status:** Living document. Exploration in progress. Not a spec. Not a plan.
**Last updated:** 2026-04-19
**Purpose:** Park the context from our brainstorming so you can re-read and pick up cold. Captures where we started, the reframes that got us here, the current working position, and what's still open.

---

## TL;DR

What started as "make Aura multi-client so tools can run on different machines" cascaded through several reframes:

1. **Client as first-class abstraction** (not just transport) → named **beacon**, analogous to Aura's existing **flare**: flares go out as short-lived dispatches; beacons are durable inbound presences.
2. **App as primary product, not the brain.** Aura-the-brain becomes pluggable reference infrastructure; the beacon apps (Mac, iOS, Android) become the user-facing commercial product, on the Tailscale/Supabase playbook.
3. **Conversation surface is a beacon capability too**, not just tool hosting. Discord is just one kind of beacon.
4. **We're actually building TWO layered standards** — a beacon protocol (device mesh for AI) and a universal human↔agent interaction protocol (the missing layer in the stack).
5. **The protocol's purpose is cognitive-load management**, not conversation-UX standardization. This reframes primitives from "message/thread/reaction" to "Concern/Engagement/Provenance" — grounded in 50 years of HCI research (Sheridan, Horvitz, Lee & See, Endsley, Amershi).

We stopped before writing a spec. The next gate is to read Amershi et al. 2019 "Guidelines for Human-AI Interaction" in full and use it to finalize the primitive list.

---

## Where we started

Original prompt: "I want to make Aura multi-client. A client running on different machines, but one gateway brain. Tools can execute on these different machines. My Mac has its own local stuff; Eisenhower is the server; imagine Aura on my phone with access to Apple Health."

The initial shape looked like: brain on Eisenhower, other machines dial in and expose tools, tool results tagged with origin.

---

## The reframes — how we got here

Each bullet is a pivot the user made that moved the design.

1. **"A machine declares what tools it has, then AURA can just call it."** Collapsed transport/identity/push into one clean model: tools travel, source is tagged.
2. **"A new abstraction called 'client'"** — not just transport, a first-class named entity with identity, catalog, presence.
3. **"C (full vision)"** — the client is also a conversation surface, not just a tool host. Discord becomes one kind of client among many.
4. **"Apple Health stays a tool, phone doesn't push"** — everything is a tool call; events/push mostly fold into the tool model. (Later walked back: push is structurally needed for iOS wake-on-demand and for real-time events like workout-completed.)
5. **"Name it 'beacon'"** — durable inbound presence, pairs with flare's outbound-dispatch shape.
6. **"App is the main interface to Aura."** Strategic rotation: the commercial product is the app, not the framework.
7. **"Is this a UI/UX problem — can we even spec it?"** Forced the distinction between data-contract (spec-able) and rendering (client's business).
8. **"Is thread even the correct abstraction? Think first principles."** Forced derivation of Context + Reference as deeper primitives, over which thread is one UX.
9. **"The spec's purpose is encoding primitives that manage the user's cognitive load. Human cognitive load doesn't change."** The load-bearing reframe. Re-rooted every primitive in HCI / human-factors research. Turned the question from "what conversation abstractions do we spec" into "what attention-management primitives does this protocol encode."
10. **"Are we basing this on the literature?"** Forced a rigorous research pass before committing to primitives.

---

## Current working position

### The abstraction

**Beacon** = a durable, named, authenticated presence that dials inbound to a central coordinator. Declares capabilities (which tools it hosts, whether it provides a conversation surface) and negotiates presence (`online` / `wakeable` / `unreachable`).

Pairs symmetrically with Aura's existing construct:

| Construct | Direction | Lifetime |
|---|---|---|
| **Flare** | Outbound dispatch from brain | Short-lived task |
| **Beacon** | Inbound presence to brain | Durable identity |

A beacon is *not* a transport. Transport is underneath (reverse-connect WebSocket + APNs/FCM for wake). A beacon is the logical entity the brain reasons about: "this output came from my Mac beacon, that one came from my iPhone beacon."

### What Aura becomes

**Before this conversation:**
Aura = local-first agent framework. Brain is the product. Discord is the user-facing surface.

**After:**
- **Aura the product** = a cross-device AI mesh. The *app* is what users install and pay for.
- **Aura the brain** = reference infrastructure. Open-source, pluggable. Users can BYO or swap in Hermes/Letta/their own. De-emphasized relative to current state.
- **Beacon protocol** = open standard. Device mesh layer.
- **Universal human↔agent interaction protocol** = open standard. Layered on top of beacons (but usable without them).
- **Hosted coordination server** = commercial SKU. Where subscription revenue lives. Tailscale shape.
- **Aura beacon apps (Mac/iOS/Android)** = the user-visible product. Free to download, closed-source polish.

### The two layered protocols

We are not specifying one thing. We are specifying two:

1. **Beacon protocol** — device identity + reverse-connect transport + tool hosting + auth. *"Which device is this."*
2. **Human↔Agent interaction protocol** — transport-agnostic conversation semantics with cognitive-load primitives. *"Which concern is this, who initiated it, what's the state, how autonomously should the agent act, what provenance does it carry."*

A beacon can carry a human↔agent conversation (iOS app). Something that isn't a beacon (ephemeral web chat, voice endpoint, email adapter) can also carry one. The conversation protocol **must not require beacons** to adopt, or we lose ecosystem leverage.

---

## The universal protocol — what we're actually building

### Purpose

Encode the primitives that best manage the user's cognitive load in an ongoing relationship with an AI agent. The invariant: human cognitive load doesn't change across tech eras. Working memory, attention budget, context-switching cost, ability to track parallel concerns — stable. UX patterns change; cognition doesn't.

### Positioning

Not *"the SMTP of AI agents"* (that framing centers communication).
Instead: *"cognitive-load-aware human↔agent interaction protocol"* (centers attention management).

The closest analog is not email or chat. It's **how you work with a very capable human assistant** — you tell them the engagement level per task, they defer what isn't urgent, they digest long threads, they check in on things that need it, they keep a provenance log, they resurface things on schedule. That pattern is what we're encoding.

### The existing ecosystem (what it does and doesn't cover)

| Protocol | Scope | Status |
|---|---|---|
| **MCP** (Anthropic) | agent ↔ tools | Shipped, adopted |
| **ACP** (Zed) | client process ↔ agent runtime orchestration | Shipped |
| **A2A** (Google) | agent ↔ agent coordination | Shipped |
| **AG-UI** (CopilotKit) | single-session frontend ↔ agent-backend wire | Shipped, broadly adopted |
| **A2UI** (Google + CopilotKit) | UI-render-layer catalog for agent-emitted UI | Early (v0.9) |
| **A2H** (Twilio Labs) | transactional agent→human approval intents | Early, narrow |
| **Open Floor Protocol** (LF AI) | multi-agent with human participant | Shipped, niche |
| **(missing)** | **cognitive-load-aware human↔agent interaction** | Unoccupied |

**Key finding:** AG-UI covers ~30-40% of what we need, concentrated in run-level streaming + tool calls + generative UI + interruption. It deliberately punts on threads, presence, reactions, edits, offline replay, multi-surface sync, identity, and all cognitive-load primitives. Those are the 60-70% gap we fill.

**Strategic posture:** layer on top of AG-UI at the conversation-wire layer. AG-UI handles how a single UI session streams events; our protocol handles the ongoing cognitive-load-aware conversation those sessions live inside. Don't re-spec what AG-UI already does.

### The primitive set (provisional, grounded in literature)

Each primitive has a citation anchor. Don't trust; verify — we haven't read all of these in full yet.

#### Core cognitive-load primitives

1. **Concern** — unit of user attention with lifecycle. Everything the user is paying attention to or has delegated is a Concern. Cognitive load attaches to Concerns. Conversations, threads, tasks, projects are UX patterns over Concerns.
   *Lineage:* Gonzalez & Mark (2004) "working spheres"; Bratman BDI intentions. The synthesis into a protocol primitive is novel.

2. **Engagement Mode** — per Concern: `autonomous` / `check-in` / `interactive`. Compresses Sheridan's 10-level automation scale into user-visible bands.
   *Lineage:* Sheridan & Verplank (1978); Parasuraman/Sheridan/Wickens (2000); Scerri/Pynadath/Tambe (2002) adjustable autonomy.

3. **State** — canonical Concern transitions: active / pending / resolved / deferred / blocked / failed.
   *Lineage:* Rao & Georgeff (1991, 1995) BDI; van der Aalst workflow patterns. "Blocked" added from workflow tradition (pragmatic).

4. **Priority / Salience** — attention weight per Concern. Must be priority × interruptibility × context, not a static scalar.
   *Lineage:* Horvitz/Jacobs/Hovel (1999) decision-theoretic attention; Wickens (2008) multiple resources.

5. **Deferral** — push a Concern out of attention with time/condition-based resurface.
   *Lineage:* Risko & Gilbert (2016) cognitive offloading; Einstein & McDaniel (1990) prospective memory. Strong empirical grounding.

6. **Digest** — budget-capped summary of a Concern's state + history, on demand. Should carry an SA-level parameter (facts / meaning / implications).
   *Lineage:* Endsley (1995) three-level SA; Shneiderman (1996) overview-first.

7. **Provenance** — every action under a Concern has an audit trail: autonomous vs approved, tool, device, agent version, input context.
   *Lineage:* W3C PROV (Moreau 2013); Chen et al. (2014) SAT model; Amershi G11.

8. **Explanation** — distinct from provenance. Provenance = *what* happened. Explanation = *why*. Both needed.
   *Lineage:* Miller (2019) "Explanation in AI: Insights from the Social Sciences."

9. **Notification policy** — per Concern × priority × Engagement Mode: when the agent is allowed to interrupt. Must include **breakpoint detection** (interrupt at task boundaries, 3× lower cost).
   *Lineage:* Horvitz/Apacible (2003); McFarlane (2002) four coordination methods; Mark (2008) interruption cost; Iqbal & Bailey (2005) breakpoints.

10. **Attention state** — user's current focus state. Not binary. Includes intensity (focused / browsing), duration, interruptibility class (available / DND).
    *Lineage:* Vertegaal (2003) attentive user interfaces; Fogarty et al. (2005) interruptibility prediction; Altmann & Trafton (2002) memory for goals.

11. **Activity visibility** — toggleable real-time view of what the agent is doing, per Concern.
    *Lineage:* Nielsen heuristic #1; Chen (2014) SAT Level 1; Amershi G1/G2/G11.

12. **Trust / Confidence** — agent communicates uncertainty per action/output. Required for appropriate reliance.
    *Lineage:* Lee & See (2004) "Trust in Automation: Designing for Appropriate Reliance."

13. **Shared mental model** — protocol-level "what the agent believes the user currently knows" object. Critical for long-running agents.
    *Lineage:* Cannon-Bowers & Salas.

14. **Repair / Correction** — explicit primitive for correcting agent actions mid-stream, beyond state transitions.
    *Lineage:* Amershi G8 "support efficient dismissal"; G9 "support efficient correction."

15. **Proactivity / Initiator** — every Concern carries who initiated it (user vs agent). Shapes turn-taking semantics.
    *Lineage:* Horvitz (1999) mixed-initiative.

16. **Commitment ceremony** — authority transfer (engaging a mode, delegating a Concern) must be explicit and acknowledged, not merely stated.
    *Lineage:* Bradshaw et al. adjustable autonomy literature.

#### Underlying communication primitives (plumbing)

- **Event** — typed state change, signed, timestamped
- **Participant** — human or agent with identity
- **Surface** — client UI rendering endpoint (phone, Mac, web, voice), declares capabilities
- **Context** — scope collecting events and participants (thread, project, tab, tag all derive from this)
- **Reference** — directed link between any two entities (reply, citation, membership)
- **Capability declaration** — what each surface supports
- **Offline replay** — events-since-cursor

### Novelty honest-assessment

What's genuinely new (vs applying existing research to a new substrate):

- **Concern as a first-class protocol object** — the synthesis of working-sphere + lifecycle + priority + engagement + provenance into one addressable unit. Components exist in the literature; combining them as a protocol primitive does not (to our knowledge).
- **Engagement Mode per-Concern** (not global / not per-task-type). Most adjustable-autonomy work is global.
- **Activity visibility toggleable per-Concern**. Most transparency research treats visibility as system-wide.

Everything else applies existing research. That's fine — application to a new substrate (LLM-agent protocols) is a legitimate contribution.

---

## Commercial framing

### The Tailscale / Supabase playbook

- **Open-source** the beacon protocol + human↔agent protocol + reference brain + SDKs.
- **Closed-source** the polished first-party beacon apps (Mac/iOS/Android).
- **Commercial** the hosted coordination server (where subscription lives).

### SKU stack

1. **Free** — self-hosted coordination + self-hosted brain + free beacon apps. Distribution engine.
2. **Individual Hosted** — $15-25/mo. Hosted coordination, BYO LLM keys. Core revenue.
3. **Pro Hosted** — $40-60/mo. Bundled LLM credits, priority support, multi-device premium.
4. **Family/Team** — $10/user/mo, 3+ seats.
5. **Enterprise** — custom, SSO, SOC2, audit. Last SKU to chase.

BYOLLM on cheap tier, bundled credits only on expensive tier. COGS discipline.

### Positioning vs Hermes (Nous Research)

Hermes is the OSS agent framework of 2026 (~101k stars, multi-platform, six execution backends, self-improving skill loop). Aura cannot win the general agent framework race.

Aura's winning posture:
- **Beacon abstraction + universal h↔a protocol** are structurally missing from Hermes. Don't dilute.
- **Vertical product** (health/wellness coach built on beacons) — Hermes is structurally weak there because it can't reach HealthKit natively.
- **Consumer polish** — Hermes is developer-first, Python-flavored. Consumer mobile-grade UX is a different game.
- **Position as complementary**, not competitive — beacon protocol could expose tools to *any* agent runtime including Hermes. Stripe shape (payments layer), not competing bank.

### Outcome envelope

- Modest: acquihire into Anthropic/Notion/Raycast for $50-300M as protocol + team.
- Strong: standalone $500M-1B company (Tailscale / Raycast / Limitless path).
- Outlier: beacon + h↔a protocol become default substrate. $5B+. Low probability, real optionality.

---

## Architecture sketch (provisional)

```
┌───────────────────────────────────────────────────────────┐
│  Aura Coordination Server (hosted)                        │
│  - Beacon registry (identity, auth, presence)             │
│  - Brain registry (user's chosen brain, BYO or bundled)   │
│  - Event router (beacon↔brain, beacon↔beacon if needed)   │
│  - Push dispatcher (APNs / FCM for wake)                  │
│  - Conversation state store (durable)                     │
└───────────────────────────────────────────────────────────┘
           │ reverse-connect WebSocket              │
           ▼                                        ▼
   ┌────────────┐  ┌────────────┐           ┌──────────────┐
   │ Mac beacon │  │ iOS beacon │           │ Brain        │
   │ tools:     │  │ tools:     │           │ (Aura / any  │
   │  shell     │  │  healthkit │           │  MCP-speaking│
   │  fs        │  │  photos    │           │  runtime)    │
   │  browser   │  │  calendar  │           │              │
   │ conv:      │  │  location  │           │              │
   │  desktop   │  │ conv:      │           │              │
   │  UI        │  │  mobile UI │           │              │
   └────────────┘  └────────────┘           └──────────────┘
```

**Key pieces:**
- Beacons dial the coordination server (reverse-connect)
- Coordination server routes to the user's brain of choice
- Brain dispatches tool calls back through the coordinator to the appropriate beacon
- Conversation events flow both directions via the coordinator
- Push (APNs/FCM) is a side-channel for wake-on-demand

### Transport / wire format

**Decided:** MCP wire format (tool schemas, tool-call envelope) + reverse-connect WebSocket + Aura extensions for beacon identity, presence, push events. Bonus: brain consumes standard MCP servers (Linear, GitHub, Notion) with adjacent code paths.

### Slice plan (provisional, pre-literature-review)

- **Slice 1** — beacon protocol + Mac beacon + Discord-as-beacon (conversation surface on a known-good transport) + reference brain (Aura). Validates both capabilities end-to-end.
- **Slice 2** — iOS beacon with HealthKit wedge + both tool hosting and conversation surface.
- **Slice 3** — Android beacon.
- **Slice 4** — Hosted coordination server (commercial).
- **Slice 5** — Health-coach vertical product SKU.

---

## Open questions / decisions pending

1. **Read Amershi et al. 2019 "Guidelines for Human-AI Interaction" in full** and map each guideline to our primitive list. Likely flags 2-3 more primitives we haven't named, especially around feedback, correction, and scoping user expectations. **This is the gate before any spec work.**
2. **Concrete spec scope for v0.1** of the human↔agent protocol. The full primitive list is the v1.0 target; v0.1 is the minimum viable subset that proves the thesis.
3. **Relationship with AG-UI** — formal "extension" vs "layer on top" vs "draft as replacement." Leaning: layer on top, use AG-UI unchanged for single-session wire.
4. **Relationship with A2UI** — adopt for rich components or define our own? Leaning: adopt, cite.
5. **Naming**:
   - Beacon protocol name — provisional, something like "Aura Beacon Protocol" or a neutral term
   - Human↔agent protocol name — TBD, "Aura Conversation Protocol" overloads existing term; consider something else
   - Don't bikeshed yet. Name after thesis stabilizes.
6. **Whether to build as standalone contributions** (publish specs + reference implementations + step back) **vs as a company** (hosted coordinator + apps + commercial). Leaning: hybrid (Tailscale / Supabase / PostHog playbook). Decision is the founder's appetite more than strategy — both paths are viable.
7. **Discord-as-beacon in Slice 1** — confirmed yes, because app-as-main-interface makes conversation-surface generalization a prerequisite.
8. **Identity model per-beacon** — TBD. Signed device identity (passkey / hardware-backed) is probably required for the "signed author claims" primitive.
9. **Voice and ambient surfaces** — out of scope for v0.1. Ensure primitives don't preclude them (we believe they don't, since Event / Message / Capability are modality-agnostic).

---

## Reading list (priority order)

Before specing, read these. All but the last are established HCI / human-factors literature.

1. **Amershi, S. et al. (2019). "Guidelines for Human-AI Interaction." CHI '19.** DOI: 10.1145/3290605.3300233 — read first. 18 guidelines, densest relevant reference.
2. **Horvitz, E. (1999). "Principles of Mixed-Initiative User Interfaces." CHI '99.** DOI: 10.1145/302979.303030
3. **Lee, J. & See, K. (2004). "Trust in Automation: Designing for Appropriate Reliance." Human Factors 46(1).** DOI: 10.1518/hfes.46.1.50_30392
4. **Parasuraman, R., Sheridan, T., Wickens, C. (2000). "A Model for Types and Levels of Human Interaction with Automation." IEEE SMC-A 30(3).** DOI: 10.1109/3468.844354
5. **Endsley, M. (1995). "Toward a Theory of Situation Awareness in Dynamic Systems." Human Factors 37(1).** DOI: 10.1518/001872095779049543
6. **Risko, E. & Gilbert, S. (2016). "Cognitive Offloading." Trends in Cognitive Sciences 20(9).** DOI: 10.1016/j.tics.2016.07.002
7. **Gonzalez, V. & Mark, G. (2004). "Constant, constant, multi-tasking craziness." CHI '04.** DOI: 10.1145/985692.985707
8. **Miller, T. (2019). "Explanation in Artificial Intelligence: Insights from the Social Sciences." Artificial Intelligence 267.** DOI: 10.1016/j.artint.2018.07.007
9. **Sweller, J., Ayres, P., Kalyuga, S. (2011). Cognitive Load Theory. Springer.**
10. **Chen, J. et al. (2014/2018). Situation Awareness-based Agent Transparency (SAT).** US Army Research Lab technical reports.

Gap: 2023-2026 CHI / CSCW / FAccT proceedings on LLM-agent protocol primitives. We haven't surveyed these. Novelty claims are provisional pending that pass.

---

## Where we stopped

- Primitive set grounded in literature (see above).
- Slice plan provisional (Discord-as-beacon in Slice 1 confirmed).
- Wire format direction set (MCP envelope + reverse WebSocket + extensions).
- Commercial framing set (Tailscale shape; beacon apps are the product).
- Strategic positioning vs Hermes set (complementary, not competitive).
- Not written any spec yet.

**Next gate:** read Amershi 2019 in full, refine primitive list, THEN start Slice 1 spec.

---

## Changelog

- **2026-04-19** — initial document. Captures brainstorming from original "multi-client" prompt through all 10 reframes to the grounded-primitive position. Living doc; update in place as thinking evolves.
