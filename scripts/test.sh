#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
export CLANG_MODULE_CACHE_PATH="$project_root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.cache/swift-modules"
swift test --disable-sandbox --cache-path "$project_root/.cache/swift" --config-path "$project_root/.cache/config" --security-path "$project_root/.cache/security" --scratch-path "$project_root/.build" "$@"
