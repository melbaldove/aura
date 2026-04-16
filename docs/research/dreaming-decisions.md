# Dreaming: Design Decisions Log

> Running log of decisions made during the dreaming design brainstorm.
> Companion to `dreaming-literature.md` (theoretical foundations).

---

## D1: Storage model — flat files as materialized view over SQLite archive

**Date:** 2026-04-16

**Decision:** The existing flat files (STATE.md, MEMORY.md, USER.md) with § key/content format remain the **interface** — what the LLM sees every turn. But they become a **materialized view** over a SQLite archive, not the sole copy of knowledge.

**Architecture:**
- **Working set** (flat files): governed by a token budget, not a character cap. Loaded into the system prompt as today. Dreaming re-renders these files after each consolidation cycle.
- **Archive** (SQLite `memory_entries` table): append-only log of every entry ever written. Never deleted, only superseded. Each superseded entry links to its replacement via `superseded_by`, creating a full lineage graph. This is the lossless record that makes aggressive working-set consolidation safe.

**Why:**
- P5 (working set optimization): flat files are the working set, kept small and dense
- P6 (lossless archive, lossy working set): archive preserves raw entries, working set can be aggressively compressed because originals are recoverable
- Separates interface (what LLM reads) from storage (what dreaming optimizes over)
- Flat file format (§ keys) is good — human-readable, LLM-readable, simple to parse. No reason to change the interface.
- SQLite is already in the stack (db actor, serialized writes). One new table.

**What changes:**
- Remove hard character caps from `structured_memory.gleam` (2200 / 1375)
- Replace with token budget (configurable, TBD)
- `set()` writes through to SQLite archive in addition to flat file — inserts new row, marks old row with `superseded_by` pointing to new row
- `remove()` marks archive entry with `superseded_at_ms` and `superseded_by = NULL` (explicitly removed, no replacement)
- Dreaming consolidation: inserts merged entry, marks all source entries with `superseded_by` pointing to the merged entry
- New `memory_entries` table in `db_schema.gleam` (schema version 4):
  ```sql
  CREATE TABLE memory_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    domain TEXT NOT NULL,
    target TEXT NOT NULL,
    key TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL,
    superseded_at_ms INTEGER,
    superseded_by INTEGER REFERENCES memory_entries(id)
  )
  ```
- Dreaming process reads archive + current working set, synthesizes, re-renders flat files within budget

**What doesn't change:**
- Brain still loads flat files into system prompt (no change to `build_system_prompt` or `build_llm_context`)
- LLM still uses `set`/`remove` memory tool during conversations
- Three targets (state/memory/user) remain — they map to different temporal scales
- § key/content format unchanged

## D2: Remove hard character caps, replace with token budget

**Date:** 2026-04-16

**Decision:** Remove the hard 2200/1375 character caps. Replace with a configurable token budget that dreaming enforces.

**Why:** The caps force the LLM to play Tetris — deleting entries for space, not relevance. A token budget is the right constraint (it's what actually matters for the context window), and dreaming is the process that maintains it, not the LLM during live conversation.

## D3: Trigger and scope — cron-triggered, per-domain, sequential

**Date:** 2026-04-16

**Decision:** Dreaming runs on a fixed cron schedule, processes one domain at a time, sequentially. Each domain is an independent unit of work. After all domains, process global USER.md.

**Why (from ENGINEERING.md):**
- **"Do one thing well"** — a dream cycle consolidates one domain. Clear scope, clear inputs/outputs.
- **"Let it crash"** — per-domain isolation. A crash consolidating domain A doesn't affect domain B.
- **"Compose, don't extend"** — small piece that runs N times, not a monolithic all-domains pass.
- **"Parsimony"** — cross-domain pattern detection is hypothetical. USER.md is already global for cross-cutting knowledge.
- **"Separate mechanism from policy"** — cron schedule is policy (when), dreaming process is mechanism (how).

**Execution:** Map-reduce. Domain dreams run in parallel (one BEAM process each), global dream runs after all domains complete.

```
Map:    spawn(dream(A)) | spawn(dream(B)) | spawn(dream(C))
Barrier: wait for all to complete (or exhaust retries)
Reduce: dream(global) — consolidates index entries from all domains
```

Total time: `max(domain_times) + global_time`. A slow domain doesn't block fast ones. If a domain fails after retries, the global pass works with whatever succeeded — it just won't have that domain's index entry.

**Integration:** Uses existing scheduler infrastructure. One cron entry in `schedules.toml`.

## D4: Four sources feed dreaming from day one

**Date:** 2026-04-16

**Decision:** All four episodic sources are inputs to the dreaming process:

1. **Memory files** — consolidate, compress, find shorter formulations (MDL optimization)
2. **State files** — promote resolved/completed state entries into durable memory (episodic → semantic)
3. **Flare outcomes** — synthesize findings from completed flares (requires persisting result_text)
4. **Conversation compaction summaries** — compressed conversation history from the DB

**Why (from principles):**
- P2 (episodic → semantic): all four are episodic sources at different timescales
- P3 (reflection generates new knowledge): synthesis across sources produces insights not in any individual source
- P7 (failure signals are high-information): flare failures and conversation corrections are high-value inputs
- No scoping down — the user explicitly chose all four for v1

## D5: Dreaming process — four LLM calls in one context session

**Date:** 2026-04-16

**Decision:** Each domain's dream cycle is a four-phase LLM conversation within a single context session:

1. **Consolidate** — merge, deduplicate, compress existing memory entries (MDL optimization)
2. **Promote** — extract durable knowledge from state, flare outcomes, compaction summaries (episodic → semantic)
3. **Reflect** — find emergent patterns across the organized knowledge (new knowledge creation)
4. **Render** — produce final working set within token budget, using `set`/`remove` tool calls to write through the normal path (which handles SQLite archive automatically)

**Why:**
- Each call does one thing well (Unix)
- Reflection must see consolidation output — can't reflect on raw inputs (P3)
- Shared context means sources transmitted once, not four times
- Tool-based render reuses existing write-through path
- Maps to existing `review_tool_loop` pattern

## D6: Source data stays where it lives — no denormalization

**Date:** 2026-04-16

**Decision:** Dreaming reads each source from its natural home:

| Source | Read from |
|--------|-----------|
| Memory entries (archive) | `memory_entries` table (new, schema v4) |
| State entries | STATE.md flat files (existing) |
| Flare outcomes | `flares` table (add `result_text` column) |
| Compaction summaries | `conversations.compaction_summary` column (existing) |

No denormalization table. The `memory_entries` table is only for keyed memory write-through archive. Episodic sources stay in their existing tables.

**Why:** "Parsimony" — don't duplicate data that already has a home. Dreaming reads from multiple tables, which is a simple query per source.

## D7: Token budget is 10% of context window, proportionally allocated

**Date:** 2026-04-16

**Decision:** Total memory budget is 10% of the model's context window, split across all loaded memory files:

| File | Share | On 200K | On 128K |
|------|-------|---------|---------|
| Domain MEMORY.md | ~40% | ~8,000 | ~5,120 |
| Domain STATE.md | ~25% | ~5,000 | ~3,200 |
| Global MEMORY.md | ~20% | ~4,000 | ~2,560 |
| USER.md | ~15% | ~3,000 | ~1,920 |

**Why:**
- JARVIS-like assistant managing multiple life domains needs deep knowledge per domain
- On 200K context, even 10% barely dents conversation capacity (163K left, compression still far away)
- 10x more generous than today's hard caps
- Dreaming ensures every token earns its place (P1)
- Proportional to context window — scales automatically with model capability

## D9: No budget indicator in system prompt — LLM writes freely

**Date:** 2026-04-16

**Decision:** The token budget is invisible to the LLM during live conversation. No "memory: 3,200/8,000 tokens" gauge in the system prompt. The LLM writes memories freely based on quality and relevance, not space concerns. Dreaming enforces the budget silently offline.

**Why:**
- Showing a budget reintroduces the Tetris behavior we're eliminating — the LLM becomes conservative about writing memories when it sees the budget is tight
- The whole point of dreaming is to separate memory quality (LLM's job during conversation) from memory quantity (dreaming's job offline)
- Transient over-budget between dream cycles is negligible on a 200K context window
- Two clean layers: LLM writes freely → dreaming consolidates within budget

## D10: Dreaming uses the most intelligent model available

**Date:** 2026-04-16

**Decision:** Dreaming uses a dedicated `models.dream` config key, defaulting to the same model as `models.brain` (the best available). Not the cheap monitor model.

**Why:**
- Dreaming does some of the hardest reasoning in the system: judging redundancy, distinguishing durable knowledge from transient status, synthesizing emergent patterns (P3)
- Output quality compounds — each day's consolidation builds on the previous one
- Dreaming runs offline on cron, latency irrelevant. Cost is 4 LLM calls per domain per cycle.
- The quality of memory shapes every future interaction — highest-leverage LLM call Aura makes

## D8: Global memory is universal knowledge + soft index over domain memories

**Date:** 2026-04-16

**Decision:** Global MEMORY.md serves two roles:

1. **Universal knowledge** — cross-domain facts, preferences, patterns
2. **Soft index** — condensed pointers to what each domain knows, providing information scent for cross-domain retrieval

Example index entry: `§ domain-health: tracks medications, doctor appointments, insurance claims, annual checkup schedule`

**Fetch mechanism:** The LLM gets a way to read another domain's memory at runtime (extend memory tool with `read` action + domain parameter) when the global index suggests relevant knowledge lives elsewhere.

**Dreaming's role:** After consolidating each domain, dreaming emits a summary/index entry to global memory. The global memory pass (last in sequence) consolidates index entries alongside universal knowledge.

**Holistic consistency:** Dreaming ensures the total picture across ALL files is consistent — no contradictions between domains, no duplicated knowledge that should live in one place, index entries that accurately reflect current domain knowledge.

**Why:**
- Information foraging theory — global memory provides "scent" that guides retrieval
- Cache hierarchy — L1 (global, always loaded, metadata-rich) / L2 (domain, loaded on demand, detail-rich)
- "One Aura" principle — cross-domain access is allowed, the channel sets default context not a wall
- Dreaming sequence: domain A → domain B → ... → global (last, sees all domain summaries)
