# ADR 020: Memory Dreaming — Offline Consolidation System

## Status
Accepted (2026-04-16)

## Context

Aura's memory has two problems:

1. **Hard character caps (2200/1375) force the LLM to play Tetris** — deleting entries for space, not relevance. There's no way to preserve all useful knowledge within the limits.

2. **No synthesis across sources.** Flare findings are consumed once and forgotten. State entries accumulate but never get promoted to durable memory. Conversation patterns vanish after compression. Cross-domain knowledge isn't extracted.

The active memory review (ADR-013) helps with in-conversation persistence but only operates on the current conversation, only runs during active interaction, and doesn't synthesize across episodes or sources.

### Theoretical foundation

Informed by Complementary Learning Systems theory (McClelland et al.), rate-distortion theory, the Generative Agents reflection mechanism (Park et al.), MemGPT's memory hierarchy (Packer et al.), and Reflexion's failure-signal prioritization (Shinn et al.). Full literature review in `docs/research/dreaming-literature.md`.

Eight derived principles:
- P1: Maximize information density per token (rate-distortion, MDL)
- P2: Episodic → semantic transformation (CLS theory)
- P3: Reflection generates new knowledge (Generative Agents)
- P4: Don't store what's derivable (entropy/surprisal)
- P5: Working set optimization (MemGPT, cache hierarchy)
- P6: Lossless archive, lossy working set (systems design)
- P7: Failure signals are high-information (Reflexion)
- P8: Verification strengthens retention (Voyager)

## Decision

### Storage model

Flat files (STATE.md, MEMORY.md, USER.md) become a **materialized view** over a SQLite archive. The § key/content format is unchanged. The files are what the LLM sees; the archive is the lossless record.

- **Working set** (flat files): governed by a token budget (10% of context window). Loaded into the system prompt as today.
- **Archive** (`memory_entries` table): append-only log of every entry ever written. Entries are marked superseded when replaced or consolidated, never deleted. Each superseded entry links to the entry that replaced it (`superseded_by`), creating a full lineage graph — trace forward ("what replaced this?") or backward ("what was merged to produce this?").

Hard character caps are removed. The token budget replaces them — dreaming enforces it offline, invisibly. The LLM never sees the budget. It writes memories freely based on quality and relevance; dreaming consolidates within budget on the next cycle. No budget indicator in the system prompt — showing one would reintroduce the conservative Tetris behavior the caps caused.

### Token budget

10% of the model's context window, proportionally allocated:

| File | Share | On 200K | On 128K |
|------|-------|---------|---------|
| Domain MEMORY.md | ~40% | ~8,000 | ~5,120 |
| Domain STATE.md | ~25% | ~5,000 | ~3,200 |
| Global MEMORY.md | ~20% | ~4,000 | ~2,560 |
| USER.md | ~15% | ~3,000 | ~1,920 |

### Global memory as soft index

Global MEMORY.md serves two roles: **universal knowledge** (cross-domain facts, preferences, patterns) and **soft index** (condensed pointers to what each domain knows). The LLM gets a cross-domain `read` action on the memory tool to fetch another domain's memory when the index suggests relevance.

### Trigger and scope

Cron-triggered, per-domain, parallel (map-reduce). Each domain is an independent unit of work (OTP isolation). Domain dreams run as parallel BEAM processes (map), global dream runs after all domains complete (reduce). Total time: `max(domain_times) + global_time`.

### Four sources

All four episodic sources feed dreaming from day one:
1. Memory files — consolidate, compress, find shorter formulations
2. State files — promote resolved/completed entries into durable memory
3. Flare outcomes — synthesize findings (requires `result_text` column on flares table)
4. Conversation compaction summaries — extract knowledge from compressed history

Sources stay where they naturally live (no denormalization). Dreaming reads from multiple tables.

### Four-phase LLM process

Each domain's dream cycle is four sequential LLM calls in one context session:

1. **Consolidate** — merge overlapping entries, eliminate redundancy, compress formulations
2. **Promote** — extract durable knowledge from state, flare outcomes, compaction summaries
3. **Reflect** — find emergent patterns and insights across all organized knowledge
4. **Render** — produce final working set within token budget using `set`/`remove` tool calls

After each domain, dreaming emits an index entry to global memory. The global pass runs last, consolidating index entries alongside universal knowledge.

**Model:** Dedicated `models.dream` config key, defaulting to `models.brain` (the best available model). Dreaming performs the hardest reasoning in the system — consolidation, promotion, reflection, budget trade-offs. Output quality compounds daily. Latency is irrelevant (offline cron). Not the cheap monitor model.

### Two layers of memory hygiene

1. **Live conversation** — LLM + active review (ADR-013) manage memory in real time with soft budget visibility
2. **Dreaming** — periodic offline consolidation catches what live management misses

Neither replaces the other.

## Consequences

- Memory capacity increases ~10x (from hard char caps to 10% of context window)
- Knowledge is never lost — SQLite archive preserves all entries losslessly
- Aggressive consolidation becomes safe because originals are recoverable
- Flare findings, state promotions, and cross-conversation patterns are synthesized
- Global memory becomes a navigable index over all domain knowledge
- Cross-domain retrieval is possible via the memory read action
- New schema migration (v4): `memory_entries` table (with `superseded_by` lineage) + `result_text` on flares
- New scheduled task: dreaming cron entry
- Dreaming consumes LLM tokens offline — cost of 4 calls per domain per cycle
- Brain system prompt loading is unchanged — still reads flat files
