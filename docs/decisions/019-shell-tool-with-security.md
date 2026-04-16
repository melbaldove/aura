# ADR-019: Shell tool with layered security

**Status:** Accepted
**Date:** 2026-04-16

## Context

Aura's brain has 12 purpose-built tools but no general-purpose shell execution. Every new capability (man pages, git operations, process inspection, orphan cleanup) requires a new Gleam tool implementation. This contradicts the Unix philosophy we just adopted — the shell is how Unix tools compose, and denying the brain shell access means it can't practice what ENGINEERING.md preaches.

Meanwhile, flares already have full bash via Claude Code with `bypassPermissions`. The brain not having shell access is inconsistent — the orchestrator is more restricted than the agents it dispatches.

The risk is real: the brain processes user messages from Discord, creating a prompt injection surface for arbitrary command execution. We studied Hermes Agent's terminal security stack (44 dangerous command patterns, Tirith binary scanner, three-mode approval workflow) to understand the state of the art.

### Hermes inefficiencies we identified

- **44 uncompiled regex patterns** checked per command — no compilation, no caching, no short-circuiting.
- **Tirith always runs even when regex already caught the command** — two overlapping detection layers that never short-circuit each other.
- **Threading nightmare** — global lock on approval state, blocking `Event.wait()` that can orphan threads, sudo password cached globally instead of per-session.
- **External binary dependency** (Tirith) — auto-downloaded from GitHub with SHA-256 + optional cosign verification. Entire install/retry/failure-marker infrastructure because Python can't do the scanning natively.
- **Smart approval has no verdict caching** — same command in two conversations triggers two LLM calls.

### Aura's advantages

- **OTP actors eliminate concurrency issues.** Brain processes one message at a time. No locks, no races, no orphaned threads. Approval state lives in actor state.
- **BEAM handles Unicode natively.** Erlang's `unicode` module does NFKC normalization. No external binary needed for homograph detection.
- **Propose flow already exists.** Dangerous commands go through the same approval mechanism as config writes — post to Discord, user confirms.
- **Aura ships as a binary.** Security scanning compiles in. No downloading tools from GitHub at runtime.

## Decision

Add a `shell` tool to the brain with a layered security pipeline, all compiled into the Aura binary.

### Tool interface

```
shell(command, timeout?)
- command: string — the shell command to execute
- timeout: optional int — seconds, default 180, max 600
```

Returns structured result: `{output, exit_code, truncated}`.

### Security pipeline

Four layers, evaluated in order. Each layer can pass, block, or escalate.

```
command input
    ↓
[1. Normalize]     Strip ANSI, null bytes, NFKC normalize
    ↓
[2. Fast reject]   Single compiled regex alternation (all patterns)
    ↓  pass
[3. Content scan]  Homograph detection, obfuscation checks (native Gleam)
    ↓  pass
[4. Execute]       Erlang open_port, capture output, enforce timeout
```

If layer 2 matches → identify which pattern → escalate to approval.
If layer 3 detects threat → escalate to approval.
Approval uses the existing `propose` flow via Discord.

### Layer 1: Normalization (Erlang FFI)

- Strip ANSI escape sequences
- Remove null bytes
- Unicode NFKC normalization via `unicode:characters_to_nfkc_binary/1`
- Lowercase for matching

All in one Erlang FFI function. Called once per command.

### Layer 2: Fast pattern rejection

Pre-compiled at startup into two forms:
- **Union regex**: all patterns joined with `|` for single-pass match/no-match
- **Individual compiled patterns**: walked only when union matches, to attribute which pattern triggered

Pattern categories (adapted from Hermes, plus Aura-specific):

**Destructive:**
`rm -r /`, `rm --recursive`, `mkfs`, `dd if=`, `chmod 777/666`, `chown -R root`

**Data:**
`DROP TABLE/DATABASE`, `DELETE FROM` (without WHERE), `TRUNCATE TABLE`

**System:**
`systemctl stop/restart/disable`, `kill -9 -1`, `pkill -9`, fork bombs

**Remote code execution:**
`bash/sh -c`, `python/perl/ruby/node -e`, `curl|wget | bash`, heredoc execution

**File system:**
`> /etc/`, `tee` to sensitive paths, `sed -i` on system config, `xargs rm`, `find -delete`

**Git history rewriting:**
`git reset --hard`, `git push --force/-f`, `git clean -f`, `git branch -D`

**Aura self-protection:**
Kill the BEAM process, delete the SQLite database, rm XDG directories, modify launchd plist, kill tmux sessions with active flares.

### Layer 3: Content-level scanning (native Gleam)

- **Homograph detection**: check URLs in the command for mixed-script characters. Flag URLs containing characters from multiple Unicode scripts (Latin + Cyrillic, etc.). Implemented as a pure Gleam function using Erlang's `unicode` module for script classification.
- **Obfuscation detection**: flag commands with excessive Unicode escapes, hex-encoded characters, or base64-encoded payloads piped to decoders.

No external binary. Compiles into the Aura binary.

### Layer 4: Approval flow

When a command is flagged:
1. Brain posts to Discord: "Shell command flagged: `<command>` — Reason: `<pattern description>`. Approve?"
2. User reacts or replies to approve/deny
3. Approval is session-scoped (per conversation) by default
4. Brain caches approval decisions in actor state: `Dict(String, ApprovalDecision)` keyed by pattern description

Smart approval (future): route flagged commands through the monitor model for risk assessment before prompting the user. Cache verdicts by command hash.

### Output handling

- **Timeout**: default 180s, max 600s, enforced via Erlang port options
- **Truncation**: 50K char max. Keep 40% head + 60% tail (errors appear early, recent output at end). Include `truncated: True` in result.
- **ANSI stripping**: strip from output before returning to LLM
- **Exit code**: included in result. Non-zero is not an error — the LLM interprets it.

### Self-protection patterns

Aura-specific patterns that Hermes doesn't need:

| Pattern | Reason |
|---------|--------|
| `kill.*beam` | Don't kill the BEAM VM |
| `rm.*aura.db` | Don't delete the database |
| `rm.*\.config/aura\|\.local/share/aura\|\.local/state/aura` | Don't delete XDG directories |
| `launchctl.*com.aura` | Don't modify the service |
| `tmux kill-session` | Don't kill flare sessions without going through flare_manager |

### What the brain uses it for

- `man aura-flares` — self-knowledge via man pages
- `git log`, `git diff` — repository awareness
- `ps aux | grep claude-agent-acp` — orphan process detection
- `cat /tmp/aura.log | tail -50` — self-diagnosis
- General Unix tool composition — the brain becomes a Unix citizen

## Consequences

### What becomes easier

- New capabilities don't require new Gleam tool implementations
- The brain can compose Unix tools the way they were designed to be composed
- Self-diagnosis via logs, process inspection, man pages — all through one tool
- Man pages become the natural documentation interface for both humans and the brain

### What becomes harder

- Security surface increases — shell execution is inherently more dangerous than purpose-built tools
- Prompt injection from Discord messages could potentially reach shell execution
- Need to maintain the dangerous command pattern list as new threats emerge

### What we explicitly chose not to do

- **No external binary dependencies for security** — everything compiles in. No Tirith, no auto-download, no install lifecycle management.
- **No threading/locking** — OTP actor model handles this. No global locks, no blocking queues, no orphaned threads.
- **No sudo support** — if Aura needs sudo, the architecture is wrong.
- **No multi-environment backends** — Aura runs locally. One execution path.
- **No `force` parameter** — Hermes lets the LLM retry with `force=True` after approval. Aura's brain checks approval state in the actor, not via a parameter the LLM controls.

### Migration

Existing purpose-built tools (`read_file`, `write_file`, `memory`, etc.) remain. They're more ergonomic for their specific use cases and have built-in safety (tier permissions, security scan). The shell tool supplements them — it doesn't replace them.

### Tool count

12 → 13 built-in tools.
