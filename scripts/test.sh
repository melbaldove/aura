#!/usr/bin/env bash
set -euo pipefail

gleam build
bash scripts/build-secret-nif.sh
gleam test "$@"
