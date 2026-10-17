#!/usr/bin/env bash
# Builds pressy, installs it to $PREFIX/bin (default ~/.local/bin), creates a config from the
# example if there is none, and (re)loads the LaunchAgent io.schaedler.pressy.
set -euo pipefail

LABEL=io.schaedler.pressy
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin/pressy"
CONFIG="${PRESSY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/pressy/config.json}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/pressy.log"
DOMAIN="gui/$(id -u)"

cd "$(dirname "$0")/.."

swift build -c release
install -d "$PREFIX/bin"
install -m 755 .build/release/pressy "$BIN"
# Ad-hoc signature with the bundle id from the embedded Info.plist; macOS privacy settings list it as "pressy".
codesign --force --sign - --identifier "$LABEL" "$BIN"

if [[ ! -f "$CONFIG" ]]; then
  install -d "$(dirname "$CONFIG")"
  cp config.example.json "$CONFIG"
  echo "created $CONFIG from config.example.json"
fi
"$BIN" check --config "$CONFIG"

install -d "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
		<string>run</string>
		<string>--config</string>
		<string>$CONFIG</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "installed $BIN, LaunchAgent $LABEL loaded"
echo "config: $CONFIG"
echo "logs:   tail -f $LOG"
