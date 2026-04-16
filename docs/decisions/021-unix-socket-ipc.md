# ADR 021: Unix Socket IPC for CLI-to-Daemon Communication

## Status
Accepted (2026-04-16)

## Context

Aura runs as a single-instance BEAM daemon. CLI commands (`start`, `doctor`) are currently standalone processes with no way to communicate with the running daemon. Features like `dream` need to trigger actions inside the running process (which owns the DB actor, scheduler, config, etc.).

Options considered:
- **File trigger** — CLI writes a sentinel file, scheduler polls for it. Simple but polling-based (up to 60s latency), fragile (crash between read and delete = duplicate trigger).
- **Erlang distribution** — Built into BEAM. Requires node naming, cookies, hidden nodes. BEAM-specific, doesn't compose with standard Unix tools.
- **HTTP endpoint** — Daemon runs a web server. Heavy dependency for simple control commands.
- **Unix socket** — Daemon binds a well-known socket path. CLI connects, sends text, reads response. Standard Unix IPC pattern (Docker, PostgreSQL, systemd).

## Decision

Unix socket at `~/.local/state/aura/aura.sock`.

**Protocol:** Line-delimited text. One command per connection. Client sends a line, server processes it, sends response lines, closes connection. No framing, no JSON — plain text in, plain text out.

**Lifecycle:**
- Daemon creates socket on startup (after supervisor tree is up)
- Daemon removes socket on shutdown
- Stale socket from a crash is removed on next startup (check PID file or just unlink)
- CLI fails fast with clear error if socket doesn't exist ("Aura is not running")

**Commands:** Extensible text commands, starting with:
- `dream` — trigger a dream cycle immediately
- `status` — report running state (uptime, domains, active flares, last dream)
- `ping` — liveness check

**Implementation:**
- Erlang FFI (`aura_socket_ffi.erl`) — gen_tcp listener on a Unix socket, spawns a handler process per connection
- Gleam module (`aura/ctl.gleam`) — command dispatcher that routes text commands to the appropriate actor
- CLI in `aura.gleam` — `gleam run -- dream` connects to socket, sends "dream", prints response

## Consequences

- CLI commands can interact with the running daemon — no second BEAM instance
- Standard Unix pattern — composable with `socat`, `nc`, scripts
- Text protocol is human-readable and debuggable
- Socket file serves as implicit "is running?" check
- New commands are one case clause in the dispatcher
- Requires Erlang FFI for socket lifecycle (gen_tcp doesn't support Unix sockets natively — need `local` address family via low-level socket API)
