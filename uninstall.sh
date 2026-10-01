#!/bin/bash
# Removes the binary and launch agent. Clipboard history is kept unless
# you pass --purge.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin/clipboard-manager"
LABEL="com.clipboard-manager"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DATA="$HOME/Library/Application Support/clipboard-manager"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
[ -x "$BIN" ] && "$BIN" stop || true
rm -f "$BIN"
echo "Removed $BIN and the launch agent."

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$DATA"
    echo "Deleted clipboard history in $DATA"
else
    echo "Clipboard history kept in $DATA (use --purge to delete it)."
fi
