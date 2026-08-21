#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.codex/bin"
APP_PATH="$BIN_DIR/CodexTrafficLightApp"
RESOURCE_PATH="$BIN_DIR/CodexTrafficLightMXP_CodexTrafficLightApp.bundle"
BUILT_RESOURCE_PATH="$DIR/.build/release/CodexTrafficLightMXP_CodexTrafficLightApp.bundle"
PLIST="$HOME/Library/LaunchAgents/com.codex.traffic-light-mxp.plist"
DOMAIN="gui/$(id -u)"

"$DIR/build.command"
mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$DIR/.build/release/CodexTrafficLightApp" "$APP_PATH.tmp"
chmod +x "$APP_PATH.tmp"
mv "$APP_PATH.tmp" "$APP_PATH"
mkdir -p "$RESOURCE_PATH"
/usr/bin/rsync -a --delete "$BUILT_RESOURCE_PATH/" "$RESOURCE_PATH/"

sed \
  -e "s#__APP_PATH__#$APP_PATH#g" \
  -e "s#__HOME__#$HOME#g" \
  "$DIR/com.codex.traffic-light-mxp.plist.template" > "$PLIST"

launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Autostart installed: $PLIST"
