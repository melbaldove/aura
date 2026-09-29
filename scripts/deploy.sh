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

LOCAL_DEPLOY=false
case "${1:-}" in
  "") ;;
  --local)
    LOCAL_DEPLOY=true
    cd "$(dirname "$0")/.."
    REMOTE_DIR="$(printf '%q' "$PWD")"
    ;;
  *) echo "Usage: bash scripts/deploy.sh [--local]" >&2; exit 2 ;;
esac

run_on_host() {
  if "$LOCAL_DEPLOY"; then
    bash -c "$1"
  else
    ssh "$REMOTE" "$1"
  fi
}

if ! "$LOCAL_DEPLOY"; then
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
  rsync -av --delete priv/ "${REMOTE}:${REMOTE_DIR}/priv/"
  rsync -av docs/man/ "${REMOTE}:${REMOTE_DIR}/docs/man/"
  rsync -av scripts/ "${REMOTE}:${REMOTE_DIR}/scripts/"
  rsync -av --delete evals/ "${REMOTE}:${REMOTE_DIR}/evals/"
fi

echo "==> Bootstrapping npm runtime tools (if missing)..."
run_on_host "set -e
export PATH=${RPATH}:\$PATH
if ! command -v agent-browser >/dev/null 2>&1; then
  echo 'Installing agent-browser...'
  npm install -g agent-browser
fi
if ! command -v claude-agent-acp >/dev/null 2>&1; then
  echo 'Installing claude-agent-acp...'
  npm install -g @agentclientprotocol/claude-agent-acp
fi
if ! command -v codex-acp >/dev/null 2>&1; then
  echo 'Installing codex-acp...'
  npm install -g @zed-industries/codex-acp
fi
agent-browser install
for bin in agent-browser claude-agent-acp codex-acp; do
  echo \"\$bin: \$(command -v \$bin)\"
done"

echo "==> Clean build..."
run_on_host "export PATH=${RPATH}:\$PATH && cd ${REMOTE_DIR} && gleam clean && gleam build"

echo "==> Fixing esqlite NIF (OTP 27+)..."
run_on_host "export PATH=${RPATH}:\$PATH && cd ${REMOTE_DIR}/build/dev/erlang/esqlite/ebin && erlc -o . ../src/esqlite3.erl ../src/esqlite3_nif.erl"

echo "==> Recompiling Erlang FFI beams..."
run_on_host "export PATH=${RPATH}:\$PATH && cd ${REMOTE_DIR}/build/dev/erlang/aura && for f in _gleam_artefacts/aura_*_ffi.erl; do erlc -o ebin \"\$f\" && echo \"  compiled \$(basename \$f)\"; done"

echo "==> Installing man pages..."
run_on_host "bash ${REMOTE_DIR}/scripts/install-man-pages.sh"

echo "==> Restarting Aura..."
run_on_host "launchctl kickstart -k gui/\$(id -u)/com.aura.agent"

echo "==> Waiting for startup..."
sleep 5
run_on_host "tail -3 /tmp/aura.log | grep -v heartbeat"

echo "==> Deploy complete."
