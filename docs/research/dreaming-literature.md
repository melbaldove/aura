# Dreaming: Theoretical Foundations & Literature Review

> Research reference for the design of Aura's memory consolidation system ("dreaming").
> Compiled 2026-04-16.

---

## 1. Information Theory

### 1.1 Rate-Distortion Theory (Shannon, 1959)

**Core idea:** Given a source of information (all of Aura's accumulated knowledge) and a channel with fixed capacity (the context window's token budget for memory), rate-distortion theory defines the fundamental trade-off: how much can you compress before the representation becomes too lossy to be useful?

**Application to dreaming:** The context window is the channel. Memory entries are the source signal. The "distortion" is the loss of useful information when the LLM can't recall something it needs. Dreaming's optimization target is: *minimize distortion (lost useful knowledge) at a given rate (token budget).*

The optimal encoding isn't uniform compression — it allocates more bits to high-value information and fewer to low-value information. A memory entry about an unusual architectural decision (high surprise, high future relevance) deserves more tokens than a memory entry about a standard deployment process (low surprise, derivable from docs).

**Key implication:** There exists a theoretical floor — you can't compress below the entropy of the useful knowledge without losing information. Dreaming should approach this floor but never pretend to beat it. When the knowledge genuinely exceeds the budget, the system must make explicit trade-offs about what to lose.

### 1.2 Minimum Description Length (Rissanen, 1978)

**Core idea:** The best model for a dataset is the one that most compresses it. MDL formalizes Occam's Razor: the shortest description that reproduces the data is the best explanation.

**Application to dreaming:** Two memory files can encode the same knowledge. One has 15 entries with redundant phrasing and overlapping facts. The other has 7 entries that cover the same ground in fewer tokens. MDL says the second is strictly better — it's a shorter description of the same information.

Consolidation is MDL optimization: merge overlapping entries, eliminate redundancy, find shorter formulations that preserve the same knowledge. The LLM doing the consolidation is acting as a compressor — finding patterns across entries and expressing them more efficiently.

**Key implication:** Dreaming should measure success not by entry count but by information density. Fewer entries at the same coverage is always better.

### 1.3 Mutual Information

**Core idea:** I(X; Y) measures how much knowing X tells you about Y. High mutual information means the variables are strongly related.

**Application to dreaming:** The value of a memory entry is its mutual information with future interactions: I(entry; future_queries). An entry about "the user prefers terse responses" has high mutual information with almost every future interaction. An entry about "deployed hotfix to staging on March 3" has mutual information only with queries about that specific deployment, which decays rapidly.

This is why recency alone is a bad retention signal. A stale entry about a permanent architectural decision is more valuable than a fresh entry about a transient deployment. The ideal retention function weights *expected future relevance*, not just age.

**Key implication:** Dreaming should assess each entry's expected utility for future interactions, not just its age or size.

### 1.4 Entropy and Surprisal

**Core idea:** Information content of an event is proportional to how surprising it is. Predictable events carry little information; surprising ones carry a lot.

**Application to dreaming:** If something is standard practice, widely documented, or derivable from the codebase, its surprisal is low — the LLM could probably guess it. Storing it in memory is wasteful because the tokens carry little information the LLM doesn't already have.

Conversely, exceptions, overrides, personal preferences, non-obvious decisions — these are high-surprisal. The LLM cannot derive them. They're the entries that most deserve memory tokens.

**Key implication:** Don't memorize what's derivable. Memory should hold the *residual* — what's left after you subtract what the LLM can infer from the codebase, docs, and general training.

---

## 2. Cognitive Science

### 2.1 Complementary Learning Systems Theory (McClelland, McNaughton & O'Reilly, 1995; Kumaran, Hassabis & McClelland, 2016)

**Core idea:** The brain has two learning systems that serve complementary roles:

- **Hippocampus:** Rapid learning, episodic memory, pattern-separated (each memory stored distinctly to avoid interference). This is where new experiences are initially encoded. High fidelity, fast, but capacity-limited and prone to interference.
- **Neocortex:** Slow learning, semantic memory, overlapping distributed representations. Extracts statistical regularities across many experiences. Low fidelity for individual episodes but captures the *structure* of the world.

During sleep (particularly slow-wave sleep), the hippocampus **replays** recently encoded episodes to the neocortex. The neocortex gradually integrates these into its existing knowledge structure. This is systems consolidation — the transfer from fast episodic storage to slow semantic storage.

**Application to dreaming:** This is the most direct theoretical analog:

| Brain | Aura |
|-------|------|
| Hippocampus | Conversation history, flare outcomes, state changes |
| Neocortex | Memory files (MEMORY.md, STATE.md, USER.md) |
| Sleep replay | The dreaming process |
| Systems consolidation | Episodic → semantic transformation |

The current system has the hippocampus (conversations) and the neocortex (memory files) but no replay process connecting them. The review system (`review.gleam`) is a weak version — it only looks at the current conversation, only runs during active interaction, and doesn't synthesize across episodes.

**Critical insight — interleaved replay:** The brain doesn't just replay the most recent episode. It interleaves recent episodes with older memories, which prevents catastrophic forgetting (new knowledge overwriting old). Dreaming should review *all* memory in the context of new information, not just append new entries.

### 2.2 Active Systems Consolidation Hypothesis (Born & Wilhelm, 2012)

**Core idea:** An extension of CLS that argues sleep isn't passive stabilization — it's **active transformation**. During consolidation, memories are:

- **Abstracted:** Details stripped, gist extracted
- **Integrated:** Connected to existing knowledge schemas
- **Generalized:** Individual episodes become general rules
- **Reweighted:** Important elements strengthened, irrelevant ones weakened

The sleeping brain doesn't just copy memories from hippocampus to neocortex. It *distills* them.

**Application to dreaming:** This is the difference between "append new entries to memory" (what the review system does) and true dreaming. Dreaming should:

1. Take raw episodes (conversation, flare results, state changes)
2. Extract the gist — what's the general principle, not the specific incident?
3. Integrate with existing memory — does this confirm, contradict, or extend what's already known?
4. Generalize — "deploy broke because of X" becomes "X requires Y as a prerequisite"
5. Reweight — strengthen entries that keep proving relevant, weaken ones that never get used

### 2.3 Ebbinghaus Forgetting Curve & Spacing Effect (Ebbinghaus, 1885)

**Core idea:** Memory strength decays exponentially over time, but each review resets and flattens the curve. Information reviewed at increasing intervals (spaced repetition) is retained far more efficiently than information crammed or reviewed at constant intervals.

**Application to dreaming:** Entries that are repeatedly relevant across dreaming cycles should be reinforced (kept hot, possibly compressed further since they're well-established). Entries that are never relevant across multiple cycles are candidates for archival or removal.

This suggests dreaming should track *access patterns* — how often each entry proves relevant during interactions. Frequently relevant entries are high-value; never-accessed entries may be derivable or obsolete.

---

## 3. AI Agent Memory Systems

### 3.1 Generative Agents: Interactive Simulacra of Human Behavior (Park et al., Stanford, 2023)

**Core idea:** Simulated agents in a sandbox world maintain a **memory stream** — a timestamped log of all observations. Periodically, the agent performs **reflection**: it asks itself "what are the 3 most salient high-level questions I can answer given my recent observations?" and then answers them. These reflections become new entries in the memory stream, marked as higher-level.

**Memory retrieval** uses a composite score: `recency × relevance × importance`
- Recency: exponential decay
- Relevance: embedding similarity to current context
- Importance: LLM-rated 1-10 at creation time ("on a scale of 1 to 10, where 1 is mundane and 10 is life-changing, rate the significance of this memory")

**Key innovation — reflection as knowledge creation:** The reflection step doesn't just compress — it produces *new insights* that weren't in any individual observation. "I've been spending a lot of time at the library" + "I haven't seen my friends recently" → "I might be isolating myself due to exam stress." This emergent insight is more valuable than either source memory.

**Application to dreaming:** Dreaming should include a reflection step that asks: "given everything I know about this domain (recent conversations, flare outcomes, existing memory), what higher-level insights can I derive?" The output of reflection is new memory entries that synthesize across sources.

The importance scoring is also relevant — not all memories are equal, and an explicit assessment at write time helps future prioritization.

### 3.2 MemGPT: Towards LLMs as Operating Systems (Packer et al., 2023) / LETTA

**Core idea:** Models an LLM agent's memory after an operating system's virtual memory hierarchy:

- **Core memory** (main context): Small, always loaded, directly editable by the LLM. Contains the "persona" (who the agent is) and "human" (who the user is) blocks. ~2K tokens.
- **Recall memory** (conversation search): Searchable database of past conversation turns. Retrieved on demand via tool calls.
- **Archival memory** (long-term store): Searchable database of arbitrary text. The LLM can insert, search, and retrieve. Unlimited size.

The LLM manages its own memory via explicit tool calls: `core_memory_append`, `core_memory_replace`, `conversation_search`, `archival_memory_insert`, `archival_memory_search`.

**Key innovation — the LLM as its own memory manager:** Rather than an external system deciding what to cache, the LLM itself decides what's important enough for core memory, what to archive, and what to retrieve. This respects the fact that the LLM is the best judge of what information it needs.

**Limitation — reactive only:** MemGPT retrieves when the LLM realizes it needs something. It doesn't proactively optimize core memory for upcoming interactions. There's no "sleep" process that reorganizes memory offline.

**Application to dreaming:** Aura already has the three-tier structure in spirit (memory files = core, conversation DB = recall, no archival yet). MemGPT validates the architecture but highlights the gap: there's no offline optimization of the core memory. Dreaming fills this gap.

### 3.3 Reflexion: Language Agents with Verbal Reinforcement Learning (Shinn et al., 2023)

**Core idea:** After a task attempt (success or failure), the agent generates a verbal reflection: "I failed because I didn't check X before doing Y. Next time, I should verify X first." These reflections are stored and loaded into the prompt for subsequent attempts.

**Key innovation — failure signals are high-information:** A successful task confirms existing knowledge (low surprisal). A failed task reveals a gap (high surprisal). Reflexion captures the *delta* — what the agent learned from the failure — not the full episode.

**Application to dreaming:** Flare outcomes (especially failures, timeouts, and unexpected results) are high-information events that should trigger immediate memory formation. "Flare timed out because the repo had no test infrastructure" is more valuable than "flare succeeded in running the tests."

This also applies to conversation: when Aura makes a mistake and the user corrects it, that correction is high-surprisal and should be prioritized for consolidation.

### 3.4 Voyager: An Open-Ended Embodied Agent with Large Language Models (Wang et al., 2023)

**Core idea:** A Minecraft agent that builds a **skill library** — a collection of verified, reusable JavaScript programs. New skills are added only after the agent verifies they work (the program executes successfully in the game).

**Key innovation — verification before persistence:** The skill library only contains *proven* knowledge. Unverified hypotheses, failed attempts, and speculative code are discarded. This keeps the library high-quality and prevents pollution with unreliable entries.

**Application to dreaming:** Memory entries should have a notion of verification status. Knowledge confirmed by outcomes (flare succeeded, user confirmed, pattern held across multiple instances) is higher quality than speculative entries. Dreaming could use verification as a retention signal — verified knowledge is retained, unverified knowledge is demoted or consolidated.

---

## 4. Derived Principles for Aura's Dreaming System

Synthesizing across all sources:

### P1: Maximize information density per token
*From: Rate-distortion theory, MDL*

Each token in the memory budget should carry maximum useful information. Dreaming optimizes the ratio of useful-knowledge-bits to tokens-consumed. This isn't just compression — it's finding the most efficient *encoding* of knowledge.

### P2: Episodic → semantic transformation
*From: CLS theory, Active Systems Consolidation*

Raw events (conversations, flare outcomes, state changes) should be transformed into generalized knowledge. "The deploy on March 3 broke because migration 042 wasn't run" becomes "deploys require running pending migrations first." The specific episode is discarded; the general lesson persists.

### P3: Reflection generates new knowledge
*From: Generative Agents, Active Systems Consolidation*

The act of reviewing accumulated knowledge produces insights that weren't in any individual source. Dreaming isn't just compression — it's synthesis. The dreaming process should explicitly ask: "what patterns or insights emerge from everything I know?"

### P4: Don't store what's derivable
*From: Entropy/surprisal, information theory*

If the LLM can derive a fact from the codebase, git history, config files, or general training, storing it in memory wastes tokens. Memory should hold the *residual* — exceptions, decisions, preferences, context that exists nowhere else. High-surprisal information only.

### P5: Working set optimization
*From: MemGPT/LETTA, CPU cache hierarchy*

The always-loaded memory should be the working set — entries most likely needed in the next interaction. Not all knowledge needs to be hot. Dreaming maintains an optimal working set by promoting frequently relevant entries and demoting stale ones.

### P6: Lossless archive, lossy working set
*From: MemGPT, systems design*

Raw data (conversation logs, flare outcomes) should be preserved in cold storage (SQLite). The working set (memory files) can be lossy — compressed, merged, summarized — because the original can be recovered via search if needed. This removes the anxiety of "losing" information during consolidation.

### P7: Failure signals are high-information
*From: Reflexion, entropy/surprisal*

Corrections, failures, timeouts, and surprises carry more information per token than confirmations and successes. Dreaming should weight these events heavily during synthesis.

### P8: Verification strengthens retention
*From: Voyager, spaced repetition*

Knowledge confirmed by outcomes (user validation, successful flare, pattern holding across episodes) should be prioritized. Unverified speculation should be treated as provisional. Dreaming can track confirmation signals as a quality metric.

---

## References

- Shannon, C.E. (1959). Coding theorems for a discrete source with a fidelity criterion. *IRE Nat. Conv. Rec.*
- Rissanen, J. (1978). Modeling by shortest data description. *Automatica.*
- Ebbinghaus, H. (1885). *Über das Gedächtnis.*
- McClelland, J.L., McNaughton, B.L., & O'Reilly, R.C. (1995). Why there are complementary learning systems in the hippocampus and neocortex. *Psychological Review.*
- Kumaran, D., Hassabis, D., & McClelland, J.L. (2016). What learning systems do intelligent agents need? Complementary learning systems theory updated. *Trends in Cognitive Sciences.*
- Born, J. & Wilhelm, I. (2012). System consolidation of memory during sleep. *Psychological Research.*
- Park, J.S. et al. (2023). Generative Agents: Interactive Simulacra of Human Behavior. *UIST 2023.*
- Packer, C. et al. (2023). MemGPT: Towards LLMs as Operating Systems. *arXiv:2310.08560.*
- Shinn, N. et al. (2023). Reflexion: Language Agents with Verbal Reinforcement Learning. *NeurIPS 2023.*
- Wang, G. et al. (2023). Voyager: An Open-Ended Embodied Agent with Large Language Models. *arXiv:2305.16291.*
