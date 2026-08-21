#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(/usr/bin/tr -d '[:space:]' < "$DIR/VERSION")"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
  echo "VERSION 格式不正确：$VERSION" >&2
  exit 2
fi

BIN_DIR="$HOME/.codex/bin"
APP_ROOT="$HOME/.wanhe-codex-token/app"
RELEASES_DIR="$APP_ROOT/releases"
RELEASE_PATH="$RELEASES_DIR/$VERSION"
CURRENT_PATH="$APP_ROOT/current"
PLIST_DIR="$HOME/Library/LaunchAgents"
APP_PLIST="$PLIST_DIR/com.codex.traffic-light-mxp.plist"
UPDATER_PLIST="$PLIST_DIR/com.codex.traffic-light-mxp-updater.plist"
MONITOR_PLIST="$PLIST_DIR/com.codex.traffic-light-codex-monitor.plist"
MONITOR_PATH="$BIN_DIR/codex-light-codex-monitor"
DOMAIN="gui/$(/usr/bin/id -u)"
NO_LAUNCH="${WANHE_INSTALL_NO_LAUNCH:-0}"

"$DIR/build.command"
/bin/mkdir -p "$BIN_DIR" "$RELEASES_DIR" "$PLIST_DIR" "$HOME/Library/Logs" "$HOME/.wanhe-codex-token/logs"
STAGING="$(/usr/bin/mktemp -d "$APP_ROOT/.install-$VERSION.XXXXXX")"
trap '/bin/rm -rf -- "$STAGING"' EXIT

/bin/cp "$DIR/.build/release/CodexTrafficLightApp" "$STAGING/CodexTrafficLightApp"
/bin/cp "$DIR/.build/release/codex-light-mxp" "$STAGING/codex-light-mxp"
/bin/cp "$DIR/.build/release/codex-light-hook-mxp" "$STAGING/codex-light-hook-mxp"
/bin/cp "$DIR/.build/release/wanhe-status-updater" "$STAGING/wanhe-status-updater"
/bin/cp "$DIR/VERSION" "$STAGING/VERSION"
/usr/bin/rsync -a --delete \
  "$DIR/.build/release/CodexTrafficLightMXP_CodexTrafficLightApp.bundle/" \
  "$STAGING/CodexTrafficLightMXP_CodexTrafficLightApp.bundle/"
/bin/chmod 755 "$STAGING/CodexTrafficLightApp" "$STAGING/codex-light-mxp" "$STAGING/codex-light-hook-mxp" "$STAGING/wanhe-status-updater"

if [[ "$NO_LAUNCH" != "1" ]]; then
  /bin/launchctl bootout "$DOMAIN" "$UPDATER_PLIST" >/dev/null 2>&1 || true
  /bin/launchctl bootout "$DOMAIN" "$APP_PLIST" >/dev/null 2>&1 || true
fi

if [[ -e "$RELEASE_PATH" ]]; then
  /bin/mv "$RELEASE_PATH" "$APP_ROOT/replaced-$VERSION-$(/bin/date +%Y%m%d-%H%M%S)"
fi
/bin/mv "$STAGING" "$RELEASE_PATH"
trap - EXIT

/bin/ln -sfn "releases/$VERSION" "$CURRENT_PATH"

BACKUP_DIR=""
for NAME in CodexTrafficLightApp codex-light-mxp codex-light-hook-mxp CodexTrafficLightMXP_CodexTrafficLightApp.bundle; do
  DESTINATION="$BIN_DIR/$NAME"
  if [[ -e "$DESTINATION" && ! -L "$DESTINATION" ]]; then
    if [[ -z "$BACKUP_DIR" ]]; then
      BACKUP_DIR="$APP_ROOT/pre-auto-update-backup-$(/bin/date +%Y%m%d-%H%M%S)"
      /bin/mkdir -p "$BACKUP_DIR"
    fi
    /bin/mv "$DESTINATION" "$BACKUP_DIR/"
  fi
done

/bin/ln -sfn "../../.wanhe-codex-token/app/current/CodexTrafficLightApp" "$BIN_DIR/CodexTrafficLightApp"
/bin/ln -sfn "../../.wanhe-codex-token/app/current/codex-light-mxp" "$BIN_DIR/codex-light-mxp"
/bin/ln -sfn "../../.wanhe-codex-token/app/current/codex-light-hook-mxp" "$BIN_DIR/codex-light-hook-mxp"
/bin/cp "$DIR/scripts/codex-light-codex-monitor" "$MONITOR_PATH"
/bin/chmod 755 "$MONITOR_PATH"

/usr/bin/sed \
  -e "s#__APP_PATH__#$CURRENT_PATH/CodexTrafficLightApp#g" \
  -e "s#__HOME__#$HOME#g" \
  "$DIR/com.codex.traffic-light-mxp.plist.template" > "$APP_PLIST"
/usr/bin/sed \
  -e "s#__UPDATER_PATH__#$CURRENT_PATH/wanhe-status-updater#g" \
  -e "s#__HOME__#$HOME#g" \
  "$DIR/com.codex.traffic-light-mxp-updater.plist.template" > "$UPDATER_PLIST"
/usr/bin/sed \
  -e "s#__MONITOR_PATH__#$MONITOR_PATH#g" \
  -e "s#__HOME__#$HOME#g" \
  "$DIR/com.codex.traffic-light-codex-monitor.plist.template" > "$MONITOR_PLIST"

if [[ "$NO_LAUNCH" != "1" ]]; then
  /bin/launchctl bootstrap "$DOMAIN" "$APP_PLIST"
  /bin/launchctl bootstrap "$DOMAIN" "$UPDATER_PLIST"
  /bin/launchctl bootout "$DOMAIN" "$MONITOR_PLIST" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "$DOMAIN" "$MONITOR_PLIST"
fi

echo "状态栏已安装：$VERSION"
echo "自动更新：已启用，每 15 分钟检查"
echo "更新日志：$HOME/.wanhe-codex-token/logs/updater.log"
if [[ -n "$BACKUP_DIR" ]]; then
  echo "原安装文件已备份：$BACKUP_DIR"
fi
