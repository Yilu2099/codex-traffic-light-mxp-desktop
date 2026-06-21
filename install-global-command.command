#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.codex/bin"

"$DIR/build.command"
mkdir -p "$BIN_DIR"
cp "$DIR/.build/release/codex-light-mxp" "$BIN_DIR/codex-light-mxp.tmp"
cp "$DIR/.build/release/codex-light-hook-mxp" "$BIN_DIR/codex-light-hook-mxp.tmp"
chmod +x "$BIN_DIR/codex-light-mxp.tmp" "$BIN_DIR/codex-light-hook-mxp.tmp"
mv "$BIN_DIR/codex-light-mxp.tmp" "$BIN_DIR/codex-light-mxp"
mv "$BIN_DIR/codex-light-hook-mxp.tmp" "$BIN_DIR/codex-light-hook-mxp"

echo "Installed:"
echo "  $BIN_DIR/codex-light-mxp"
echo "  $BIN_DIR/codex-light-hook-mxp"
