#!/bin/bash
# Builds and installs clipboard-manager to ~/.local/bin (no sudo needed).
#   ./install.sh                 install the binary
#   ./install.sh --launch-agent  also start it automatically at login
#   PREFIX=/usr/local ./install.sh   install to /usr/local/bin instead
set -euo pipefail
cd "$(dirname "$0")"

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LABEL="com.clipboard-manager"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh

mkdir -p "$BIN_DIR"
# Replacing a running binary: stop it first, restart afterwards.
WAS_RUNNING=0
if [ -x "$BIN_DIR/clipboard-manager" ] && "$BIN_DIR/clipboard-manager" status | grep -q "is running"; then
    WAS_RUNNING=1
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    "$BIN_DIR/clipboard-manager" stop >/dev/null
fi
install -m 755 build/clipboard-manager "$BIN_DIR/clipboard-manager"
echo "Installed $BIN_DIR/clipboard-manager"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not on your PATH. Add this to ~/.zshrc:"
       echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

if [ "${1:-}" = "--launch-agent" ]; then
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Application Support/clipboard-manager"
    sed -e "s|__BINARY__|$BIN_DIR/clipboard-manager|" -e "s|__HOME__|$HOME|g" \
        launchd/$LABEL.plist > "$PLIST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Launch agent installed: clipboard-manager will start at login (and is running now)."
elif [ "$WAS_RUNNING" = 1 ]; then
    "$BIN_DIR/clipboard-manager" start
fi
