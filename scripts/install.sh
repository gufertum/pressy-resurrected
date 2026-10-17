#!/usr/bin/env bash
# Builds pressy, installs it to $PREFIX/bin (default ~/.local/bin), creates a config from the
# example if there is none, and (re)loads the LaunchAgent li.sudo.pressy.
set -euo pipefail

LABEL=li.sudo.pressy
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin/pressy"
CONFIG="${PRESSY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/pressy/config.json}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/pressy.log"
DOMAIN="gui/$(id -u)"
SIGN_IDENTITY="${PRESSY_SIGN_IDENTITY:-pressy local signing}"

cd "$(dirname "$0")/.."

swift build -c release
install -d "$PREFIX/bin"
install -m 755 .build/release/pressy "$BIN"
# Signed with the bundle id from the embedded Info.plist; macOS privacy settings list it as "pressy".
# The local certificate (scripts/make-signing-cert.sh) keeps privacy grants across rebuilds, ad-hoc does not.
if security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$LABEL" "$BIN"
else
  echo "warning: no \"$SIGN_IDENTITY\" identity (make cert), signing ad-hoc: privacy grants are lost with every build" >&2
  codesign --force --sign - --identifier "$LABEL" "$BIN"
fi

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
