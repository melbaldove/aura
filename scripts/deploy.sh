#!/usr/bin/env bash
# Deploy Aura to Eisenhower.
# Handles all the gotchas:
#   1. rsync all source files
#   2. gleam clean + build (ensures no stale beams)
#   3. Fix esqlite NIF (gleam clean wipes it, OTP 27+ needs recompile)
#   4. Recompile Erlang FFI beams (gleam build doesn't compile .erl files)
#   5. Restart via launchctl
set -euo pipefail

REMOTE="melbournebaldove@192.168.50.140"
REMOTE_DIR="~/aura"
RPATH="/opt/homebrew/bin"

echo "==> Syncing config..."
rsync -av gleam.toml manifest.toml "${REMOTE}:${REMOTE_DIR}/"

echo "==> Syncing source + tests..."
rsync -av --delete \
  --include='*.gleam' --include='*.erl' --include='*/' --exclude='*' \
  src/ "${REMOTE}:${REMOTE_DIR}/src/"
rsync -av --delete \
  --include='*.gleam' --include='*.erl' --include='*/' --exclude='*' \
  test/ "${REMOTE}:${REMOTE_DIR}/test/"

echo "==> Syncing man pages + scripts..."
rsync -av docs/man/ "${REMOTE}:${REMOTE_DIR}/docs/man/"
rsync -av scripts/ "${REMOTE}:${REMOTE_DIR}/scripts/"

echo "==> Clean build..."
ssh "$REMOTE" "export PATH=${RPATH}:\$PATH && cd ${REMOTE_DIR} && gleam clean && gleam build"

echo "==> Fixing esqlite NIF (OTP 27+)..."
ssh "$REMOTE" "export PATH=${RPATH}:\$PATH && cd ${REMOTE_DIR}/build/dev/erlang/esqlite/ebin && erlc -o . ../src/esqlite3.erl ../src/esqlite3_nif.erl"

echo "==> Recompiling Erlang FFI beams..."
ssh "$REMOTE" "export PATH=${RPATH}:\$PATH && cd ${REMOTE_DIR}/build/dev/erlang/aura && for f in _gleam_artefacts/aura_*_ffi.erl; do erlc -o ebin \"\$f\" && echo \"  compiled \$(basename \$f)\"; done"

echo "==> Installing man pages..."
ssh "$REMOTE" "bash ${REMOTE_DIR}/scripts/install-man-pages.sh"

echo "==> Restarting Aura..."
ssh "$REMOTE" "launchctl kickstart -k gui/\$(id -u)/com.aura.agent"

echo "==> Waiting for startup..."
sleep 5
ssh "$REMOTE" "tail -3 /tmp/aura.log | grep -v heartbeat"

echo "==> Deploy complete."
