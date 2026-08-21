#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(/usr/bin/tr -d '[:space:]' < "$DIR/VERSION")"
REMOTE="${WANHE_UPDATE_REMOTE:-root@116.62.119.214}"
DATA_DIR="${WANHE_UPDATE_DATA_DIR:-/opt/wanhe-codex-rank/data}"

"$DIR/build-update-package.command"
ARCHIVE="$DIR/artifacts/wanhe-status-$VERSION.tar.gz"
MANIFEST="$DIR/artifacts/wanhe-status-$VERSION.manifest.json"

/usr/bin/ssh "$REMOTE" "/bin/mkdir -p '$DATA_DIR/client-releases'"
/usr/bin/scp "$ARCHIVE" "$REMOTE:$DATA_DIR/client-releases/wanhe-status-$VERSION.tar.gz.uploading"
/usr/bin/scp "$MANIFEST" "$REMOTE:$DATA_DIR/macos-client-update.json.uploading"
/usr/bin/ssh "$REMOTE" "/bin/mv '$DATA_DIR/client-releases/wanhe-status-$VERSION.tar.gz.uploading' '$DATA_DIR/client-releases/wanhe-status-$VERSION.tar.gz' && /bin/mv '$DATA_DIR/macos-client-update.json.uploading' '$DATA_DIR/macos-client-update.json'"

echo "已发布 Mac 状态栏 $VERSION：$REMOTE"
echo "灰度比例：${WANHE_UPDATE_ROLLOUT:-10}%  强制更新：${WANHE_UPDATE_MANDATORY:-false}"
