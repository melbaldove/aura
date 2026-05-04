# ACP Adapter Support

Aura dispatches flares through the Agent Communication Protocol (ACP). The
runtime currently selects one global ACP transport from `~/.config/aura/config.toml`.

## Default Adapters

`scripts/deploy.sh` bootstraps these npm tools on Eisenhower when missing:

- `codex-acp` from `@zed-industries/codex-acp`
- `claude-agent-acp` from `@agentclientprotocol/claude-agent-acp`

The default generated Aura config uses Codex:

```toml
[acp]
global_max_concurrent = 4
transport = "stdio"
command = "codex-acp"
```

To switch the active stdio adapter to Claude Code:

```toml
[acp]
transport = "stdio"
command = "claude-agent-acp"
```

## Adding Another ACP Adapter

1. Verify the target is an ACP adapter, not just a provider-specific app server.
   Aura's stdio client speaks ACP JSON-RPC methods such as `initialize`,
   `session/new`, and `session/prompt`.
2. Install the adapter binary on the host that runs Aura.
3. Set `[acp].transport = "stdio"` and `[acp].command` to the adapter command or
   absolute binary path.
4. Confirm required auth is present in the launchd environment or provider login
   state.
5. Run a smoke flare in a disposable repo before using the adapter for real work.
6. If the adapter should ship with Aura by default, add it to the npm bootstrap
   block in `scripts/deploy.sh` and document its auth requirements here and in
   `docs/CONFIG.md`.

Codex CLI's `app-server` protocol is JSON-RPC, but it is not the ACP protocol
Aura's stdio transport currently speaks. Use `codex-acp` unless Aura gains a
separate Codex app-server transport.

## Current Limit

Aura has one active global ACP adapter at runtime. Domain config can still tune
legacy provider/worktree fields, but stdio adapter selection is global today.
A future provider registry should make adapters named endpoints so a domain or
individual flare can choose between `codex`, `claude-code`, or another ACP
adapter without editing global config.
