#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

cd "$repo_dir"
expected_prompt_hash="ad772142c0b376f22048539333a4130b98fe5cb565295b7b35598ddab806d7c3"
prompt=$(awk '/^```text$/ { block += 1; next } block == 2 { print; exit }' \
  docs/runtime/personal-life-codex-monitor.md)
actual_prompt_hash=$(printf '%s\n' "$prompt" | shasum -a 256 | awk '{ print $1 }')
test "$actual_prompt_hash" = "$expected_prompt_hash"

nix develop --command bash scripts/test.sh \
  test/aura/codex_monitor_runtime_test.gleam \
  test/aura/codex_monitor_test.gleam \
  test/aura/cli_test.gleam
