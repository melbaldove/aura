#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

cd "$repo_dir"

verification_log=$(mktemp -t aura-google-readonly-verification.XXXXXX)
trap 'rm -f "$verification_log"' EXIT

nix develop --command bash scripts/test.sh \
  test/aura/google_execution_db_test.gleam \
  test/aura/google_execution_recovery_test.gleam \
  test/aura/google_readonly_protocol_test.gleam \
  test/aura/google_oauth_runtime_test.gleam \
  test/aura/google_http_client_test.gleam \
  test/aura/google_gmail_runtime_test.gleam \
  test/aura/google_calendar_runtime_test.gleam \
  test/aura/google_control_test.gleam \
  test/aura/connector_runtime_test.gleam \
  test/aura/db_schema_test.gleam \
  test/aura/personal_life_live_canary_local_test.gleam \
  2>&1 | tee "$verification_log"

nix develop --command gleam run -m features/runner \
  2>&1 | tee -a "$verification_log"

if grep -Fq \
  -e 'task9-secret-sentinel-must-not-persist' \
  -e 'task9-transcript-sentinel-must-not-persist' \
  -e 'task9-oauth-secret-sentinel' \
  -e 'task9-oauth-code-sentinel' \
  "$verification_log"; then
  printf '%s\n' "A Task 9 sentinel escaped into verification output." >&2
  exit 1
fi

if rg -n \
  "task9-(secret|transcript)-sentinel-must-not-persist|task9-oauth-(secret|code)-sentinel" \
  docs test/fixtures; then
  printf '%s\n' "A Task 9 sentinel escaped into a fixture or report artifact." >&2
  exit 1
fi

legacy_matches=$(rg -n \
  "mail\\.google\\.com|imap\\.gmail\\.com|connect_gmail" \
  src test docs/man || true)

unexpected_matches=$(printf '%s\n' "$legacy_matches" | sed '/^$/d' | \
  grep -Ev '^test/aura/(oauth_test|google_readonly_http_test|brain_test|brain_tools_test)\.gleam:' || true)

if [ -n "$unexpected_matches" ]; then
  printf '%s\n' "Unexpected retired Gmail runtime reference:" >&2
  printf '%s\n' "$unexpected_matches" >&2
  exit 1
fi

git diff --check
