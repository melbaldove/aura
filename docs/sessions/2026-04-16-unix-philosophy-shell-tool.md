# Session: Unix Philosophy, Shell Tool, and Dreaming

**Date:** 2026-04-16
**Starting commit:** `b847f94` (flare self-knowledge, awaiting_response, archive, manual)
**Commits this session:** `b28b48d` (ground engineering principles in Unix and OTP philosophy)

## Initial Goal

Improve Aura's memory system by removing hard character limits and implementing "dreaming" — a periodic consolidation process that synthesizes knowledge from memory, STATE.md, and ACP session outcomes. The user's vision: Aura always has the memory tokens it minimally needs, but exhaustively preserves all important knowledge.

## What Actually Happened

The session took three productive detours before we could build anything, each more fundamental than the last. Every detour was the right call — you can't build dreaming on shaky foundations.

### Detour 1: MANUAL.md is orphaned

We built `docs/MANUAL.md` last session but never connected it. README doesn't link to it. The brain doesn't load it. The manual claims "loaded by the brain for self-diagnosis" but that's aspirational, not actual. The brain's self-knowledge is hardcoded strings in the system prompt.

**Resolution path:**
- Discussed manual tool (section-based) vs file read tool
- File read tool doesn't support progressive reading (no offset/limit)
- User noted MANUAL.md will be huge → section-based access needed
- User asked: "is our manual file supported to be read via `man`?" → No, it's markdown
- User: "we want to be unix first. LLM can use any arbitrary man including its own"

**Key decision:** The tool should be `man`, not `manual`. General purpose. Brain calls `man aura-flares` for self-knowledge, `man tmux` for external tools. Same interface for humans and the LLM. MANUAL.md should be converted to proper troff man pages, split by topic.

### Detour 2: Engineering principles are restating Unix

User realized: "some of our engineering principles could just be the unix philosophy." This led to a full revision of `docs/ENGINEERING.md`.

**What changed:**
- 13 principles → Unix philosophy foundation + OTP philosophy foundation + 8 Aura-specific principles
- Unix philosophy governs interfaces: skills, tools, docs, file formats, config, extensibility
- OTP philosophy governs runtime: actors, supervision, fault tolerance, state
- 5 principles that were restating Unix (#3 vertical before horizontal, #5 instrument don't theorize, #10 design for one, #11 elegance, #12 no silent errors) absorbed into the Unix section with concrete Aura examples
- 8 remaining Aura-specific principles: One Aura, working software, ship and verify, subagents are junior engineers, ask then build, every bug reveals a gap, don't break what works, read the spec

**Committed:** `b28b48d`

### Detour 3: Aura needs a shell tool

The `man` tool discussion revealed a bigger gap: Aura has no general-purpose shell execution. Every new capability requires a new Gleam tool. This contradicts Unix philosophy — the shell is how you compose tools.

**Research:** Deep dive into Hermes Agent's terminal security stack:
- 44 dangerous command regex patterns (uncompiled, checked per-command)
- Tirith external Rust binary for content-level scanning (homograph URLs, obfuscation)
- Three-mode approval: manual, smart (LLM-assisted), off
- Threading infrastructure (locks, blocking queues, event waits)

**Hermes inefficiencies identified:**
- Regex patterns not pre-compiled (44 compilations per command)
- Tirith always runs even when regex already caught it (no short-circuit)
- Threading/locking complexity that OTP eliminates for free
- External binary dependency with auto-download/verify/retry infrastructure
- Smart approval has no verdict caching

**Key design decisions:**
- Aura ships as a binary → security scanning compiles in, no external dependencies
- OTP actors → no threading, no locks, no races
- BEAM handles Unicode natively → no Tirith needed
- Approval via existing `propose` flow on Discord
- Self-protection patterns (don't kill BEAM, don't delete DB, don't nuke XDG dirs)

**ADR-019 written:** `docs/decisions/019-shell-tool-with-security.md`

## Dreaming Brainstorm (Parked)

The original goal. Brainstormed but not designed or implemented. Key ideas captured:

### The Problem
Memory is hard-capped at 2200 chars. LLM plays Tetris — deletes entries for space, not relevance. No synthesis across sources. ACP session findings consumed once and forgotten. Conversation patterns vanish after compression.

### Proposed Design

**Four operations:**
- **Consolidate** — merge related entries into denser single entries
- **Promote** — extract durable knowledge from STATE.md (ephemeral → persistent)
- **Demote** — move stale entries to cold storage
- **Synthesize** — extract patterns from completed ACP session outcomes

**Token budget model (replaces hard char limit):**
- **Hot** (always in system prompt) — capped by token budget, highest-priority entries
- **Warm** (loaded on keyword match) — demoted entries, retrieved when relevant
- **Cold** (explicit recall only) — SQLite archive, historical entries

**Sources for synthesis:**
1. Memory files (consolidation + pruning)
2. STATE.md (promote completed state entries to memory)
3. ACP session outcomes (requires persisting `result_text` in flares table first)
4. Conversation compaction summaries (maybe — overlaps with review system)

**When to dream:**
- Scheduled daily + event-driven when memory budget exceeds 80%
- Runs via existing scheduler infrastructure

**Prerequisite:** Persist flare outcomes — add `result_text` column to flares table

**Minimum viable dream:**
1. Remove hard limit from structured_memory.gleam
2. Add token budget (configurable, ~2000 tokens default)
3. Add `dream` scheduled task
4. Dream process: read all memory + state per domain, consolidate, prune, promote, write back within budget
5. Persist flare results in DB
6. No warm tier yet — just hot and cold

## Completed This Session

1. **ENGINEERING.md revision** — Unix + OTP philosophy foundations, 13 → 8 Aura-specific principles
2. **ADR-019** — Shell tool with layered security (written and accepted)
3. **Shell tool implemented** — full security pipeline, 41 patterns, normalization FFI, approval flow, 48 new tests
4. **CLAUDE.md updated** — tool count 12→13, source layout entries
5. **MANUAL.md updated** — Shell subsection with security pipeline docs + diagnostics

## Still TODO

### From this session
1. **Convert MANUAL.md to man pages** — split into:
   - `aura(1)` — overview, synopsis
   - `aura-flares(7)` — flare lifecycle, diagnostics
   - `aura-config(5)` — configuration reference
   - `aura-diagnostics(7)` — troubleshooting
   - Install to local man path

2. **Link manual in README.md** — still not done

3. **Ensure deploy.sh syncs docs/** (or man pages when converted)

### From previous sessions (still open)
4. **Dreaming** — design and implement memory consolidation (parked, needs ADR)
5. **Orphan monitor cleanup** — kill push monitor actors when flares are killed/parked/archived
6. **Logs tool** — give Aura ability to read its own logs for self-diagnosis (parked, likely solved by shell tool)
7. **Orphan `claude-agent-acp` processes** — no automated cleanup (likely solved by shell tool + self-protection)
8. **Persist flare results** — add `result_text` to flares table (prerequisite for dreaming synthesis)
9. **Stale test fix** — `brain_tools_test.gleam` has pre-existing compilation errors

### Design assumption
Aura will ship as a compiled binary (OTP release). All security scanning, man pages, and tools compile in. No runtime external dependencies. This affects how man pages are bundled, how the shell tool works, and how deploy changes.

## Files Changed This Session

| File | Change |
|------|--------|
| `docs/ENGINEERING.md` | Restructured: Unix + OTP philosophy foundations, 8 Aura-specific principles |
| `docs/decisions/019-shell-tool-with-security.md` | NEW: Shell tool ADR with layered security pipeline |
| `docs/decisions/README.md` | Added ADR-019 to index, updated next number to 020 |
| `src/aura/shell.gleam` | NEW: 41 dangerous patterns, scan, execute, normalize, truncate |
| `src/aura_shell_ffi.erl` | NEW: /bin/sh -c execution, ANSI strip, NFKC normalization |
| `test/aura/shell_test.gleam` | NEW: 48 tests — safe commands, flagged categories, normalization, truncation, execution |
| `src/aura/brain_tools.gleam` | Shell tool definition, execution dispatch, PendingShellApproval, approval helpers |
| `src/aura/brain.gleam` | shell_patterns + pending_shell_approvals in state, RegisterShellApproval, handle_shell_interaction |
| `gleam.toml` | Added gleam_regexp dependency |
| `CLAUDE.md` | Tool count 12→13, source layout entries for shell.gleam + aura_shell_ffi.erl |
| `docs/MANUAL.md` | Shell subsection with security pipeline, self-protection, diagnostics |
