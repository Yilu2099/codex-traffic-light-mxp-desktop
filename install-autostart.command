#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.codex/bin"
APP_PATH="$BIN_DIR/CodexTrafficLightApp"
PLIST="$HOME/Library/LaunchAgents/com.codex.traffic-light-mxp.plist"
DOMAIN="gui/$(id -u)"

detect_codex_bin() {
  local candidate=""

  if [[ -n "${CODEX_TRAFFIC_LIGHT_CODEX_BIN:-}" && -x "$CODEX_TRAFFIC_LIGHT_CODEX_BIN" ]]; then
    print -r -- "$CODEX_TRAFFIC_LIGHT_CODEX_BIN"
    return
  fi

  candidate="$(command -v codex 2>/dev/null || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    print -r -- "$candidate"
    return
  fi

  local candidates=(
    "$HOME/.local/bin/codex"
    "/Applications/ChatGPT.app/Contents/Resources/codex"
    "$HOME/Applications/ChatGPT.app/Contents/Resources/codex"
    "/Applications/Codex.app/Contents/Resources/codex"
    "$HOME/Applications/Codex.app/Contents/Resources/codex"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      print -r -- "$candidate"
      return
    fi
  done

  return 1
}

"$DIR/build.command"
mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$DIR/.build/release/CodexTrafficLightApp" "$APP_PATH.tmp"
chmod +x "$APP_PATH.tmp"
mv "$APP_PATH.tmp" "$APP_PATH"

sed \
  -e "s#__APP_PATH__#$APP_PATH#g" \
  -e "s#__HOME__#$HOME#g" \
  "$DIR/com.codex.traffic-light-mxp.plist.template" > "$PLIST"

if CODEX_BIN="$(detect_codex_bin)"; then
  plutil -insert EnvironmentVariables -xml '<dict/>' "$PLIST"
  plutil -insert EnvironmentVariables.CODEX_TRAFFIC_LIGHT_CODEX_BIN -string "$CODEX_BIN" "$PLIST"
  echo "Detected Codex: $CODEX_BIN"
else
  echo "Warning: Codex executable was not found; the app will retry discovery at runtime."
fi

launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Autostart installed: $PLIST"
