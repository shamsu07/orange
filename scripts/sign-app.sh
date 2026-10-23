#!/bin/bash
set -euo pipefail
app="${1:?Pass the staged Orange.app path}"
identity="${ORANGE_SIGN_IDENTITY:--}"
flags=(--force --sign "$identity")
if [[ "$identity" == - ]]; then
    flags+=(--timestamp=none)
else
    flags+=(--options runtime --timestamp)
fi
framework="$app/Contents/Frameworks/Sparkle.framework"
[[ -d "$framework" ]] || { printf 'Sparkle must be embedded before signing.\n' >&2; exit 1; }
# Sign nested helpers before their containing bundles. Never use --deep to sign.
for service in Installer Downloader; do
    if [[ "$service" == Downloader ]]; then
        codesign "${flags[@]}" --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/$service.xpc"
    else
        codesign "${flags[@]}" "$framework/Versions/B/XPCServices/$service.xpc"
    fi
done
codesign "${flags[@]}" "$framework/Versions/B/Autoupdate"
codesign "${flags[@]}" "$framework/Versions/B/Updater.app"
codesign "${flags[@]}" "$framework"
for tool in ffmpeg ffprobe; do
    path="$app/Contents/Resources/Tools/bin/$tool"
    [[ ! -f "$path" ]] || codesign "${flags[@]}" "$path"
done
codesign "${flags[@]}" "$app"
codesign --verify --deep --strict "$app"
