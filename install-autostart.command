#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.codex.traffic-light-mxp.plist"
DOMAIN="gui/$(id -u)"

"$DIR/build.command"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

sed \
  -e "s#__APP_PATH__#$DIR/.build/release/CodexTrafficLightApp#g" \
  -e "s#__HOME__#$HOME#g" \
  "$DIR/com.codex.traffic-light-mxp.plist.template" > "$PLIST"

launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Autostart installed: $PLIST"
