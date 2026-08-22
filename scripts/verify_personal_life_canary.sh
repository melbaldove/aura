#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

cd "$repo_dir"

nix develop --command bash scripts/test.sh \
  test/aura/personal_life_live_canary_local_test.gleam \
  test/aura/canary_preflight_test.gleam \
  test/aura/canary_metrics_test.gleam \
  test/aura/db_schema_test.gleam \
  test/aura/connector_activation_test.gleam \
  test/aura/connector_runtime_test.gleam \
  test/aura/integrations/gmail_api_test.gleam \
  test/aura/integrations/calendar_api_test.gleam \
  test/aura/codex_monitor_runtime_test.gleam \
  test/aura/codex_monitor_test.gleam
