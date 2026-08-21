#!/bin/zsh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

export CLANG_MODULE_CACHE_PATH="$DIR/.build/clang-module-cache"
export SWIFTPM_CACHE_PATH="$DIR/.build/swiftpm-cache"

swift build -c release

echo "Built:"
echo "  .build/release/CodexTrafficLightApp"
echo "  .build/release/codex-light-mxp"
echo "  .build/release/codex-light-hook-mxp"
echo "  .build/release/wanhe-status-updater"
