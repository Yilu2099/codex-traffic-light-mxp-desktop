#!/bin/zsh
set -euo pipefail

DOMAIN="gui/$(/usr/bin/id -u)"
APP_PLIST="$HOME/Library/LaunchAgents/com.codex.traffic-light-mxp.plist"
UPDATER_PLIST="$HOME/Library/LaunchAgents/com.codex.traffic-light-mxp-updater.plist"
TRASH_DIR="$HOME/.Trash/wanhe-status-launchagents-$(/bin/date +%Y%m%d-%H%M%S)-$$"

/bin/launchctl bootout "$DOMAIN" "$APP_PLIST" >/dev/null 2>&1 || true
/bin/launchctl bootout "$DOMAIN" "$UPDATER_PLIST" >/dev/null 2>&1 || true
for PLIST in "$APP_PLIST" "$UPDATER_PLIST"; do
  if [[ -e "$PLIST" ]]; then
    /bin/mkdir -p "$TRASH_DIR"
    /bin/mv "$PLIST" "$TRASH_DIR/"
  fi
done
echo "状态栏和自动更新已停止。LaunchAgent 文件已移到废纸篓，安装版本仍保留。"
