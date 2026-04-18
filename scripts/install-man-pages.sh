#!/bin/bash
# Install Aura man pages to the system man path.
# Run on Eisenhower after deploy.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAN_SRC="$SCRIPT_DIR/../docs/man"

MAN_BASE="/opt/homebrew/share/man"

mkdir -p "$MAN_BASE/man1" "$MAN_BASE/man5" "$MAN_BASE/man7"

cp "$MAN_SRC/aura.1" "$MAN_BASE/man1/"
cp "$MAN_SRC/aura-config.5" "$MAN_BASE/man5/"
cp "$MAN_SRC/aura-flares.7" "$MAN_BASE/man7/"
cp "$MAN_SRC/aura-diagnostics.7" "$MAN_BASE/man7/"
cp "$MAN_SRC/aura-browser.7" "$MAN_BASE/man7/"

echo "Man pages installed to $MAN_BASE"
