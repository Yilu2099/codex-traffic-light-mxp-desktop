#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.codex/bin"
MONITOR="$BIN_DIR/codex-light-codex-monitor"
PLIST="$HOME/Library/LaunchAgents/com.codex.traffic-light-codex-monitor.plist"
DOMAIN="gui/$(id -u)"

"$DIR/install-global-command.command"
mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$DIR/scripts/codex-light-codex-monitor" "$MONITOR"
chmod +x "$MONITOR"

sed \
  -e "s#__MONITOR_PATH__#$MONITOR#g" \
  -e "s#__HOME__#$HOME#g" \
  "$DIR/com.codex.traffic-light-codex-monitor.plist.template" > "$PLIST"

launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Codex Desktop monitor installed: $PLIST"
