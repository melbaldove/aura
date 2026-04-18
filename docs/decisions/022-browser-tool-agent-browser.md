# ADR 022: Browser Tool via agent-browser CLI

Status: Accepted
Date: 2026-04-18

## Context

Aura cannot drive browsers. The congregation-accounting skill needs hub.jw.org interaction; jira/linear dashboards and other JS-rendered apps are out of reach. We evaluated three paths:

1. Wrap the `agent-browser` npm CLI (hermes-agent's approach)
2. Ship our own Playwright wrapper (Python or Node script)
3. Build a native CDP client from BEAM using the existing WebSocket FFI

## Decision

Wrap `agent-browser`. It's already production-hardened by hermes, gives us accessibility-tree snapshots with element refs, supports both local headless mode and CDP attach for BYO browsers, and requires zero per-site integration work. Aura adds a thin Gleam dispatcher with SSRF and secret-exfiltration guards, plus session scoping that matches the conversation model.

## Consequences

**Upside**
- Proven battery-included CLI; our code is ~400 lines of Gleam + one FFI module
- Sessions persist cookies/auth across tool calls via agent-browser's `--session` flag
- BYO-browser via `--cdp` when auth is user-maintained (e.g., openclaw-controlled Chrome)
- Accessibility-tree output is text-first; no vision model needed for structure

**Downside**
- New runtime dep on Eisenhower: npm install of agent-browser (one-time bootstrap step in deploy.sh)
- We pay for agent-browser's bugs/regressions and depend on its maintenance
- Can't automate passkey auth (neither can anyone else — out of scope)

## Rejected

- **Native CDP from BEAM**: too much scope for uncertain value. Aura has raw WebSocket FFI (for Discord) that could, in theory, drive Chromium directly, but reimplementing agent-browser's ariaSnapshot extraction is a multi-week project. Deferred.
- **Our own Playwright wrapper**: same problem — we'd be rebuilding agent-browser.

## References

- Spec: `docs/superpowers/specs/2026-04-18-browser-tool-design.md`
- Inspiration: `/tmp/hermes-agent/tools/browser_tool.py`
