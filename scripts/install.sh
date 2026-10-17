#!/usr/bin/env bash
# Builds pressy and the menu bar app, installs ~/.local/bin/pressy and ~/Applications/Pressy.app,
# creates a config from the example if there is none, and (re)loads the LaunchAgents
# li.sudo.pressy (daemon) and li.sudo.pressy.bar (menu bar app).
set -euo pipefail

LABEL=li.sudo.pressy
APP_LABEL=li.sudo.pressy.bar
PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin/pressy"
APP="${PRESSY_APP:-$HOME/Applications/Pressy.app}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pressy"
AGENTS="$HOME/Library/LaunchAgents"
LOG="$HOME/Library/Logs/pressy.log"
DOMAIN="gui/$(id -u)"
SIGN_IDENTITY="${PRESSY_SIGN_IDENTITY:-pressy local signing}"

cd "$(dirname "$0")/.."

# Same lookup as the daemon: $PRESSY_CONFIG, else config.yaml, config.yml, config.json. A config.json
# alone is converted to config.yaml once (below, with the new binary) and kept as config.json.bak.
MIGRATE_JSON=
if [[ -n "${PRESSY_CONFIG:-}" ]]; then
  CONFIG="$PRESSY_CONFIG"
elif [[ -f "$CONFIG_DIR/config.yaml" ]]; then
  CONFIG="$CONFIG_DIR/config.yaml"
elif [[ -f "$CONFIG_DIR/config.yml" ]]; then
  CONFIG="$CONFIG_DIR/config.yml"
else
  CONFIG="$CONFIG_DIR/config.yaml"
  [[ -f "$CONFIG_DIR/config.json" ]] && MIGRATE_JSON="$CONFIG_DIR/config.json"
fi

# The local certificate (make cert) keeps privacy grants across rebuilds, ad-hoc does not.
if security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
  SIGN="$SIGN_IDENTITY"
else
  echo "warning: no \"$SIGN_IDENTITY\" identity (make cert), signing ad-hoc: privacy grants are lost with every build" >&2
  SIGN=-
fi

# write_agent LABEL LOGFILE PROGRAM [ARGS...]: LaunchAgent started at login, restarted after a crash.
write_agent() {
  local label=$1 log=$2
  shift 2
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
EOF
    for arg in "$@"; do printf '\t\t<string>%s</string>\n' "$arg"; done
    cat <<EOF
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
	<string>$log</string>
	<key>StandardErrorPath</key>
	<string>$log</string>
</dict>
</plist>
EOF
  } > "$AGENTS/$label.plist"
  # bootout returns before the job is gone; bootstrapping too early fails with "5: Input/output error".
  if launchctl bootout "$DOMAIN/$label" 2>/dev/null; then
    for _ in $(seq 50); do
      launchctl print "$DOMAIN/$label" >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi
  launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
}

swift build -c release

# Daemon. Signed with the bundle id from its embedded Info.plist; privacy settings list it as "pressy".
install -d "$PREFIX/bin"
install -m 755 .build/release/pressy "$BIN"
codesign --force --sign "$SIGN" --identifier "$LABEL" "$BIN"

if [[ -n "$MIGRATE_JSON" ]]; then
  "$BIN" convert "$MIGRATE_JSON" "$CONFIG"
  mv "$MIGRATE_JSON" "$MIGRATE_JSON.bak"
  echo "converted $MIGRATE_JSON to $CONFIG (old file kept as $MIGRATE_JSON.bak)"
elif [[ ! -f "$CONFIG" ]]; then
  install -d "$(dirname "$CONFIG")"
  cp config.example.yaml "$CONFIG"
  echo "created $CONFIG from config.example.yaml"
fi
"$BIN" check --config "$CONFIG"

# Menu bar app: a plain bundle around the PressyBar executable.
install -d "$APP/Contents/MacOS" "$AGENTS" "$(dirname "$LOG")"
install -m 755 .build/release/PressyBar "$APP/Contents/MacOS/PressyBar"
cp Support/PressyBar-Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN" "$APP"

write_agent "$LABEL" "$LOG" "$BIN" run --config "$CONFIG"
write_agent "$APP_LABEL" "$HOME/Library/Logs/pressy-bar.log" "$APP/Contents/MacOS/PressyBar"

echo "installed $BIN and $APP, LaunchAgents $LABEL and $APP_LABEL loaded"
echo "config: $CONFIG"
echo "logs:   tail -f $LOG"
