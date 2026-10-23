#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash scripts/package.sh [--no-build]

Build Orange, then create a drag-and-drop DMG, portable ZIP and SHA256SUMS in dist/.
--no-build packages the existing build/Orange.app without compiling.

Optional environment:
  ORANGE_SIGN_IDENTITY    Developer ID signing identity; otherwise retain local signing.
  ORANGE_NOTARY_PROFILE   Existing notarytool keychain profile; opt in to notarization.

Notarization requires ORANGE_SIGN_IDENTITY and a configured Apple developer account.
Existing release artifacts are never overwritten. No upload occurs without a notary profile.
EOF
}

BUILD_APP=true
for argument in "$@"; do
    case "$argument" in
        --no-build) BUILD_APP=false ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
    esac
done

PACKAGE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PACKAGE_APP="$PACKAGE_ROOT/build/Orange.app"
PACKAGE_DIST="$PACKAGE_ROOT/dist"
PACKAGE_CACHE="$PACKAGE_ROOT/.cache/package"
PACKAGE_IDENTITY="${ORANGE_SIGN_IDENTITY:-}"
PACKAGE_NOTARY_PROFILE="${ORANGE_NOTARY_PROFILE:-}"

fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "Packaging requires macOS."
if [[ -n "$PACKAGE_NOTARY_PROFILE" && ( -z "$PACKAGE_IDENTITY" || "$PACKAGE_IDENTITY" == - ) ]]; then
    fail "Notarization requires ORANGE_SIGN_IDENTITY set to a Developer ID identity."
fi
for directory in "$PACKAGE_ROOT/.cache" "$PACKAGE_CACHE" "$PACKAGE_DIST"; do
    [[ ! -L "$directory" ]] || fail "Packaging directories must not be symbolic links: $directory"
done
mkdir -p "$PACKAGE_CACHE" "$PACKAGE_DIST"
for directory in "$PACKAGE_CACHE" "$PACKAGE_DIST"; do
    resolved="$(cd -- "$directory" && pwd -P)"
    case "$resolved" in "$PACKAGE_ROOT"/*) ;; *) fail "Packaging must remain inside Orange." ;; esac
done
mkdir "$PACKAGE_CACHE/.lock" 2>/dev/null || fail "Another packaging run is active, or .cache/package/.lock needs inspection."
PACKAGE_STAGE=""
PACKAGE_PUBLISHED=()
PACKAGE_PUBLISHED_COUNT=0
PACKAGE_COMPLETE=false
cleanup() {
    status=$?
    trap - EXIT
    if [[ "$PACKAGE_COMPLETE" != true && "$PACKAGE_PUBLISHED_COUNT" -gt 0 ]]; then
        for file in "${PACKAGE_PUBLISHED[@]}"; do rm -f -- "$file"; done
    fi
    if [[ -n "$PACKAGE_STAGE" ]]; then
        case "$PACKAGE_STAGE" in "$PACKAGE_CACHE"/Orange.*) rm -rf -- "$PACKAGE_STAGE" ;; esac
    fi
    rmdir "$PACKAGE_CACHE/.lock" 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
PACKAGE_STAGE="$(mktemp -d "$PACKAGE_CACHE/Orange.XXXXXX")"

if [[ "$BUILD_APP" == true ]]; then bash "$PACKAGE_ROOT/scripts/build.sh"; fi
[[ -d "$PACKAGE_APP" && ! -L "$PACKAGE_APP" ]] || fail "Build build/Orange.app first, or omit --no-build."
[[ -f "$PACKAGE_APP/Contents/Info.plist" && -x "$PACKAGE_APP/Contents/MacOS/Orange" ]] || fail "Orange.app is incomplete."
if [[ "$(plutil -extract OrangeWheelTrace raw -o - "$PACKAGE_APP/Contents/Info.plist" 2>/dev/null || true)" == true ]]; then
    fail "Refusing to package a wheel-diagnostics build. Build the release app first."
fi
codesign --verify --deep --strict "$PACKAGE_APP"
[[ -f "$PACKAGE_APP/Contents/Resources/Licenses/Sparkle.txt" ]] || fail "The Sparkle license is missing."
[[ -x "$PACKAGE_APP/Contents/Frameworks/Sparkle.framework/Sparkle" ]] || fail "The updater framework is missing."
PACKAGE_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PACKAGE_APP/Contents/Info.plist")"
case "$PACKAGE_VERSION" in ''|*[!A-Za-z0-9._-]*) fail "The app version cannot be used safely in release filenames." ;; esac
PACKAGE_ARCHS="$(lipo -archs "$PACKAGE_APP/Contents/MacOS/Orange")"
case "$PACKAGE_ARCHS" in
    arm64) PACKAGE_ARCH=arm64 ;;
    x86_64) PACKAGE_ARCH=x86_64 ;;
    *arm64*x86_64*|*x86_64*arm64*) PACKAGE_ARCH=universal ;;
    *) fail "Unsupported application architecture: $PACKAGE_ARCHS" ;;
esac
PACKAGE_STEM="Orange-$PACKAGE_VERSION-macos-$PACKAGE_ARCH"
for file in "$PACKAGE_STEM.dmg" "$PACKAGE_STEM.zip" SHA256SUMS; do
    [[ ! -e "$PACKAGE_DIST/$file" && ! -L "$PACKAGE_DIST/$file" ]] || fail "Refusing to overwrite dist/$file. Move the previous release artifacts aside first."
done
if [[ -n "$PACKAGE_NOTARY_PROFILE" ]]; then
    for file in "$PACKAGE_STEM-app-notarization.json" "$PACKAGE_STEM-dmg-notarization.json"; do
        [[ ! -e "$PACKAGE_DIST/$file" && ! -L "$PACKAGE_DIST/$file" ]] || fail "Refusing to overwrite dist/$file."
    done
fi

mkdir "$PACKAGE_STAGE/payload" "$PACKAGE_STAGE/artifacts"
PACKAGE_STAGED_APP="$PACKAGE_STAGE/payload/Orange.app"
ditto "$PACKAGE_APP" "$PACKAGE_STAGED_APP"
PACKAGE_TOOLS="$PACKAGE_STAGED_APP/Contents/Resources/Tools"
if [[ -e "$PACKAGE_TOOLS/bin/ffmpeg" || -e "$PACKAGE_TOOLS/bin/ffprobe" ]]; then
    for tool in ffmpeg ffprobe; do [[ -x "$PACKAGE_TOOLS/bin/$tool" ]] || fail "The bundled media backend is incomplete."; done
    for file in share/licenses/ffmpeg/LICENSE.md share/licenses/ffmpeg/COPYING.LGPLv2.1 share/licenses/ffmpeg/COPYING.LGPLv3 \
                share/source/ffmpeg/ffmpeg-9.0.2.tar.xz share/source/ffmpeg/build-ffmpeg.sh \
                share/source/ffmpeg/CONFIGURE.txt share/source/ffmpeg/SHA256SUMS \
                share/source/ffmpeg/SOURCE-URL.txt share/source/ffmpeg/BUILD-VERSION.txt; do
        [[ -f "$PACKAGE_TOOLS/$file" ]] || fail "Missing bundled FFmpeg source or license material: $file"
    done
    (cd "$PACKAGE_TOOLS/share/source/ffmpeg" && shasum -a 256 -c SHA256SUMS)
    if grep -q -- '--enable-libwebp' "$PACKAGE_TOOLS/share/source/ffmpeg/CONFIGURE.txt"; then
        for file in share/licenses/libwebp/COPYING share/licenses/libwebp/PATENTS share/licenses/libwebp/AUTHORS \
                    share/source/libwebp/libwebp-1.6.0.tar.gz share/source/libwebp/CONFIGURE.txt \
                    share/source/libwebp/SHA256SUMS share/source/libwebp/SOURCE-URL.txt; do
            [[ -f "$PACKAGE_TOOLS/$file" ]] || fail "Missing bundled libwebp source, license or patent material: $file"
        done
        (cd "$PACKAGE_TOOLS/share/source/libwebp" && shasum -a 256 -c SHA256SUMS)
    fi
fi

if [[ -n "$PACKAGE_IDENTITY" ]]; then
    if [[ "$PACKAGE_IDENTITY" == - ]]; then
        fail "Leave ORANGE_SIGN_IDENTITY unset to retain ad hoc signing; use a Developer ID identity for distribution signing."
    fi
    bash "$PACKAGE_ROOT/scripts/sign-app.sh" "$PACKAGE_STAGED_APP"
fi
codesign --verify --deep --strict "$PACKAGE_STAGED_APP"

notarize() {
    local artifact="$1" receipt="$2"
    xcrun notarytool submit "$artifact" --keychain-profile "$PACKAGE_NOTARY_PROFILE" --wait --output-format json > "$receipt"
    if [[ "$(plutil -extract status raw -o - "$receipt")" != Accepted ]]; then
        cat "$receipt" >&2
        fail "Apple did not accept notarization. Use the submission ID above to inspect Apple's log before distributing."
    fi
}
if [[ -n "$PACKAGE_NOTARY_PROFILE" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_STAGED_APP" "$PACKAGE_STAGE/notarization.zip"
    notarize "$PACKAGE_STAGE/notarization.zip" "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM-app-notarization.json"
    xcrun stapler staple "$PACKAGE_STAGED_APP"
    xcrun stapler validate "$PACKAGE_STAGED_APP"
fi
codesign --verify --deep --strict "$PACKAGE_STAGED_APP"

ln -s /Applications "$PACKAGE_STAGE/payload/Applications"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_STAGED_APP" "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM.zip"
unzip -tq "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM.zip"
hdiutil create -volname Orange -srcfolder "$PACKAGE_STAGE/payload" -format UDZO "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM.dmg"
if [[ -n "$PACKAGE_IDENTITY" ]]; then
    codesign --force --timestamp --sign "$PACKAGE_IDENTITY" "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM.dmg"
fi
if [[ -n "$PACKAGE_NOTARY_PROFILE" ]]; then
    notarize "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM.dmg" "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM-dmg-notarization.json"
    xcrun stapler staple "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM.dmg"
    xcrun stapler validate "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM.dmg"
fi
if [[ -n "$PACKAGE_IDENTITY" ]]; then
    codesign --verify --strict "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM.dmg"
fi
hdiutil verify "$PACKAGE_STAGE/artifacts/$PACKAGE_STEM.dmg"
(cd "$PACKAGE_STAGE/artifacts" && shasum -a 256 "$PACKAGE_STEM.dmg" "$PACKAGE_STEM.zip" > SHA256SUMS)
for source in "$PACKAGE_STAGE/artifacts/"*; do
    target="$PACKAGE_DIST/$(basename "$source")"
    ln "$source" "$target"
    PACKAGE_PUBLISHED+=("$target")
    PACKAGE_PUBLISHED_COUNT=$((PACKAGE_PUBLISHED_COUNT + 1))
done
PACKAGE_COMPLETE=true
printf '\nCreated dist/%s.dmg, dist/%s.zip and dist/SHA256SUMS\n' "$PACKAGE_STEM" "$PACKAGE_STEM"
if [[ -n "$PACKAGE_NOTARY_PROFILE" ]]; then
    printf 'App and DMG notarization accepted; stapled tickets validated. Receipts are in dist/.\n'
else
    printf 'Notarization was not requested. These artifacts are not claimed to be notarized.\n'
fi
