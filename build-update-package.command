#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(/usr/bin/tr -d '[:space:]' < "$DIR/VERSION")"
SOURCE_VERSION="$(/usr/bin/sed -n 's/.*public static let current = "\([^"]*\)".*/\1/p' "$DIR/Sources/CodexTrafficLightCore/ClientUpdate.swift" | /usr/bin/head -1)"
PRIVATE_KEY="${WANHE_UPDATE_PRIVATE_KEY:-$HOME/.config/wanhe-updater/update-signing-private.pem}"
ROLLOUT="${WANHE_UPDATE_ROLLOUT:-10}"
MANDATORY="${WANHE_UPDATE_MANDATORY:-false}"
OUTPUT_DIR="$DIR/artifacts"

if [[ ! -f "$PRIVATE_KEY" ]]; then
  echo "找不到更新签名私钥：$PRIVATE_KEY" >&2
  exit 2
fi
if [[ "$VERSION" != "$SOURCE_VERSION" ]]; then
  echo "VERSION($VERSION) 与客户端编译版本($SOURCE_VERSION) 不一致，已停止发布。" >&2
  exit 2
fi

"$DIR/build.command"
/bin/mkdir -p "$OUTPUT_DIR"
STAGING="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wanhe-status-$VERSION.XXXXXX")"
trap '/bin/rm -rf -- "$STAGING"' EXIT

/bin/cp "$DIR/.build/release/CodexTrafficLightApp" "$STAGING/CodexTrafficLightApp"
/bin/cp "$DIR/.build/release/codex-light-mxp" "$STAGING/codex-light-mxp"
/bin/cp "$DIR/.build/release/codex-light-hook-mxp" "$STAGING/codex-light-hook-mxp"
/bin/cp "$DIR/.build/release/wanhe-status-updater" "$STAGING/wanhe-status-updater"
/bin/cp "$DIR/scripts/codex-light-codex-monitor" "$STAGING/codex-light-codex-monitor"
/bin/cp "$DIR/com.codex.traffic-light-codex-monitor.plist.template" "$STAGING/com.codex.traffic-light-codex-monitor.plist.template"
/bin/cp "$DIR/VERSION" "$STAGING/VERSION"
/usr/bin/rsync -a --delete \
  "$DIR/.build/release/CodexTrafficLightMXP_CodexTrafficLightApp.bundle/" \
  "$STAGING/CodexTrafficLightMXP_CodexTrafficLightApp.bundle/"
/bin/chmod 755 "$STAGING/CodexTrafficLightApp" "$STAGING/codex-light-mxp" "$STAGING/codex-light-hook-mxp" "$STAGING/wanhe-status-updater" "$STAGING/codex-light-codex-monitor"

ARCHIVE="$OUTPUT_DIR/wanhe-status-$VERSION.tar.gz"
MANIFEST="$OUTPUT_DIR/wanhe-status-$VERSION.manifest.json"
/usr/bin/tar -czf "$ARCHIVE" -C "$STAGING" .
/usr/bin/env node "$DIR/scripts/create-update-manifest.mjs" \
  "$VERSION" "$ARCHIVE" "$PRIVATE_KEY" "$MANIFEST" "$ROLLOUT" "$MANDATORY"

echo "更新包：$ARCHIVE"
echo "版本清单：$MANIFEST"
