#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
app="${1:?Pass the staged Orange.app path}"
framework="$project_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$app/Contents" && -d "$framework" ]] || { printf 'Missing app or resolved Sparkle framework.\n' >&2; exit 1; }
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources/Licenses"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$project_root/licenses/Sparkle.txt" "$app/Contents/Resources/Licenses/Sparkle.txt"
