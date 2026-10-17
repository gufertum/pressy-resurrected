#!/usr/bin/env bash
# Stops and removes the LaunchAgent and the binary. Keeps the config and the log.
set -euo pipefail

LABEL=io.schaedler.pressy
PREFIX="${PREFIX:-$HOME/.local}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$PREFIX/bin/pressy"

echo "removed LaunchAgent $LABEL and $PREFIX/bin/pressy"
echo "kept: ${XDG_CONFIG_HOME:-$HOME/.config}/pressy/ and ~/Library/Logs/pressy.log"
echo "privacy entries: tccutil reset All $LABEL"
