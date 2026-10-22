#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
export CLANG_MODULE_CACHE_PATH="$project_root/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.cache/swift-modules"
configuration="${CONFIGURATION:-release}"
swift_flags=(--disable-sandbox --cache-path "$project_root/.cache/swift" --config-path "$project_root/.cache/config" --security-path "$project_root/.cache/security" --scratch-path "$project_root/.build" -c "$configuration")
swift build "${swift_flags[@]}" --product Orange
swift build "${swift_flags[@]}" --product OrangeIconGenerator
binary_directory="$(swift build "${swift_flags[@]}" --show-bin-path)"
staging="$(mktemp -d "$project_root/.cache/app-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Orange.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/Orange" "$app/Contents/MacOS/Orange"
cp "$project_root/scripts/Info.plist" "$app/Contents/Info.plist"
if [[ "${ORANGE_WHEEL_TRACE:-0}" == 1 ]]; then
    [[ "$configuration" == debug ]] || { printf 'Wheel tracing requires CONFIGURATION=debug.\n' >&2; exit 1; }
    plutil -insert OrangeWheelTrace -bool YES "$app/Contents/Info.plist"
fi
cp "$project_root/LICENSE" "$app/Contents/Resources/LICENSE"
if [[ -x "$project_root/.cache/tools/bin/ffmpeg" && -x "$project_root/.cache/tools/bin/ffprobe" ]]; then
    mkdir -p "$app/Contents/Resources/Tools/bin"
    cp "$project_root/.cache/tools/bin/ffmpeg" "$project_root/.cache/tools/bin/ffprobe" "$app/Contents/Resources/Tools/bin/"
    for entry in share; do
        if [[ -e "$project_root/.cache/tools/$entry" ]]; then
            cp -R "$project_root/.cache/tools/$entry" "$app/Contents/Resources/Tools/"
        fi
    done
    for tool in ffmpeg ffprobe; do
        codesign --force --sign "${ORANGE_SIGN_IDENTITY:--}" --timestamp=none "$app/Contents/Resources/Tools/bin/$tool"
    done
fi
"$binary_directory/OrangeIconGenerator" "$project_root/build"
iconutil --convert icns "$project_root/build/Orange.iconset" --output "$app/Contents/Resources/Orange.icns"
codesign --force --sign "${ORANGE_SIGN_IDENTITY:--}" --timestamp=none "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$project_root/build"
rm -rf "$project_root/build/Orange.app"
mv "$app" "$project_root/build/Orange.app"
app="$project_root/build/Orange.app"
printf '\nBuilt %s\n' "$app"
