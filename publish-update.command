#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(/usr/bin/tr -d '[:space:]' < "$DIR/VERSION")"
REMOTE="${WANHE_UPDATE_REMOTE:-wanhe-innovation}"
DATA_DIR="${WANHE_UPDATE_DATA_DIR:-/opt/wanhe-codex-rank/data}"
ROOT="${DATA_DIR:h}"
HEAD="$(git -C "$DIR" rev-parse HEAD)"
MAIN="$(git -C "$DIR" ls-remote origin refs/heads/main | cut -f1)"
[[ "$HEAD" == "$MAIN" ]] || { echo "发布源码尚未同步到 GitHub main，已停止。" >&2; exit 2; }
git -C "$DIR" diff --quiet
git -C "$DIR" diff --cached --quiet
EXPECTED="$(ssh "$REMOTE" "readlink -f '$ROOT/current'")"
BEFORE="$(ssh "$REMOTE" "sha256sum '$DATA_DIR/macos-client-update.json' | cut -d ' ' -f1")"
LIVE="$(ssh "$REMOTE" "cat '$DATA_DIR/macos-client-update.json'" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>console.log(JSON.parse(s).version));')"
node -e 'const a=process.argv[1].split(".").map(Number),b=process.argv[2].split(".").map(Number);let c=0;for(let i=0;i<3&&!c;i++)c=Math.sign(a[i]-b[i]);if(c<=0)process.exit(2)' "$VERSION" "$LIVE"

"$DIR/build-update-package.command"
ARCHIVE="$DIR/artifacts/wanhe-status-$VERSION.tar.gz"
MANIFEST="$DIR/artifacts/wanhe-status-$VERSION.manifest.json"

SUFFIX="$(uuidgen)"
SHA="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1])).sha256' "$MANIFEST")"
/usr/bin/ssh "$REMOTE" "mkdir -p '$DATA_DIR/client-releases' '$ROOT/incoming'"
/usr/bin/scp "$ARCHIVE" "$REMOTE:$ROOT/incoming/mac-$SUFFIX.tar.gz"
/usr/bin/scp "$MANIFEST" "$REMOTE:$ROOT/incoming/mac-$SUFFIX.json"
/usr/bin/ssh "$REMOTE" bash -s -- "$ROOT" "$DATA_DIR" "$EXPECTED" "$BEFORE" "$VERSION" "$SUFFIX" "$SHA" <<'REMOTE'
set -euo pipefail
root=$1 data=$2 expected=$3 before=$4 version=$5 suffix=$6 sha=$7
exec 9>"$root/deploy.lock"
flock -x 9
[[ $(readlink -f "$root/current") == "$expected" ]]
[[ $(sha256sum "$data/macos-client-update.json" | cut -d ' ' -f1) == "$before" ]]
[[ $(sha256sum "$root/incoming/mac-$suffix.tar.gz" | cut -d ' ' -f1) == "$sha" ]]
target="$data/client-releases/wanhe-status-$version.tar.gz"
[[ ! -e $target ]] || { echo 'Release artifact already exists; stop.'; exit 2; }
cp -p "$data/macos-client-update.json" "$data/macos-client-update.json.rollback-$version"
mv "$root/incoming/mac-$suffix.tar.gz" "$target"
mv "$root/incoming/mac-$suffix.json" "$data/macos-client-update.json"
REMOTE

echo "已发布 Mac 状态栏 $VERSION：$REMOTE"
echo "灰度比例：${WANHE_UPDATE_ROLLOUT:-10}%  强制更新：${WANHE_UPDATE_MANDATORY:-false}"
