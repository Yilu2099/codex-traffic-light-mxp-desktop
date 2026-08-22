#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_URL=""
INVITE_CODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER_URL="${2:-}"; shift 2 ;;
    --invite) INVITE_CODE="${2:-}"; shift 2 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SERVER_URL" || -z "$INVITE_CODE" ]]; then
  echo "需要团队服务器地址和专属邀请码。" >&2
  echo "用法：./install-team.command --server https://c.wanhe.cn --invite wanhe-xxxx" >&2
  exit 2
fi

SERVER_URL="${SERVER_URL%/}"
HARDWARE_JSON="$(/usr/sbin/system_profiler SPHardwareDataType -json)"
DEVICE_NAME="$(printf '%s' "$HARDWARE_JSON" | /usr/bin/plutil -extract SPHardwareDataType.0.machine_name raw -o - - 2>/dev/null || echo Mac)"
MODEL_ID="$(printf '%s' "$HARDWARE_JSON" | /usr/bin/plutil -extract SPHardwareDataType.0.machine_model raw -o - - 2>/dev/null || true)"
PLATFORM_UUID="$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p' | /usr/bin/head -1)"
if [[ -z "$PLATFORM_UUID" ]]; then
  PLATFORM_UUID="$MODEL_ID|$(/bin/hostname)"
fi
DEVICE_ID="$(printf '%s' "$PLATFORM_UUID" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print substr($1,1,12)}')"
LEGACY_ID="$(/bin/hostname | /usr/bin/shasum -a 256 | /usr/bin/awk '{print substr($1,1,12)}')"

TEMP_RESPONSE="$(/usr/bin/mktemp -t wanhe-codex-register).json"
trap '/bin/rm -f "$TEMP_RESPONSE"' EXIT

/usr/bin/curl -fsS "$SERVER_URL/api/collector/register" \
  -H 'content-type: application/json' \
  --data-binary "{\"inviteCode\":\"$INVITE_CODE\",\"device\":{\"id\":\"$DEVICE_ID\",\"kind\":\"mac\",\"name\":\"$DEVICE_NAME\",\"modelIdentifier\":\"$MODEL_ID\",\"legacyIds\":[\"$LEGACY_ID\"]}}" \
  -o "$TEMP_RESPONSE"

DEVICE_TOKEN="$(/usr/bin/plutil -extract deviceToken raw -o - "$TEMP_RESPONSE")"
USER_ID="$(/usr/bin/plutil -extract profile.userId raw -o - "$TEMP_RESPONSE")"
USER_NAME="$(/usr/bin/plutil -extract profile.userName raw -o - "$TEMP_RESPONSE")"
TEAM="$(/usr/bin/plutil -extract profile.team raw -o - "$TEMP_RESPONSE")"
ROLE="$(/usr/bin/plutil -extract profile.role raw -o - "$TEMP_RESPONSE")"

OLD_PLIST="$HOME/Library/LaunchAgents/com.wanhe.codex-token.plist"
OLD_DISABLED_PLIST="$OLD_PLIST.disabled"
/bin/launchctl bootout "gui/$(/usr/bin/id -u)" "$OLD_PLIST" >/dev/null 2>&1 || true
/bin/launchctl bootout "gui/$(/usr/bin/id -u)/com.wanhe.codex-token" >/dev/null 2>&1 || true

LEGACY_TRASH=""
for LEGACY_PATH in \
  "$OLD_PLIST" \
  "$OLD_DISABLED_PLIST" \
  "$HOME/.wanhe-codex-token/bin" \
  "$HOME/.wanhe-codex-token/logs"
do
  if [[ -e "$LEGACY_PATH" ]]; then
    if [[ -z "$LEGACY_TRASH" ]]; then
      LEGACY_TRASH="$HOME/.Trash/wanhe-old-collector-$(/bin/date +%Y%m%d-%H%M%S)-$$"
      /bin/mkdir -p "$LEGACY_TRASH"
    fi
    /bin/mv "$LEGACY_PATH" "$LEGACY_TRASH/"
  fi
done

INSTALL_DIR="$HOME/.wanhe-codex-token"
/bin/mkdir -p "$INSTALL_DIR"
/bin/cat > "$INSTALL_DIR/config.env" <<EOF
WANHE_ENDPOINT="$SERVER_URL/api/usage"
WANHE_INGEST_TOKEN="$DEVICE_TOKEN"
WANHE_USER_ID="$USER_ID"
WANHE_USER_NAME="$USER_NAME"
WANHE_TEAM="$TEAM"
WANHE_ROLE="$ROLE"
WANHE_TZ="Asia/Hong_Kong"
WANHE_COLLECT_DAYS="45"
EOF
/bin/chmod 600 "$INSTALL_DIR/config.env"

"$DIR/install-autostart.command"

echo
echo "安装完成：$USER_NAME"
echo "设备：$DEVICE_NAME${MODEL_ID:+ · $MODEL_ID}"
if [[ -n "$LEGACY_TRASH" ]]; then
  echo "已停用旧服务器采集器，并将旧文件移到废纸篓。"
fi
echo "状态栏会显示周额度；点击后可查看今日团队全部成员并打开排行榜。"
