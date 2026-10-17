#!/usr/bin/env bash
# Stops and removes both LaunchAgents, the binary and the menu bar app. Keeps the config, the logs and the certificate.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
APP="${PRESSY_APP:-$HOME/Applications/Pressy.app}"

for label in li.sudo.pressy.bar li.sudo.pressy; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -f "$PREFIX/bin/pressy"
rm -rf "$APP"

echo "removed LaunchAgents li.sudo.pressy and li.sudo.pressy.bar, $PREFIX/bin/pressy and $APP"
echo "kept: ${XDG_CONFIG_HOME:-$HOME/.config}/pressy/, ~/Library/Logs/pressy*.log, the \"pressy local signing\" certificate"
echo "privacy entries: remove pressy with - in System Settings > Privacy & Security > Input Monitoring"
