#!/bin/bash
set -euo pipefail

# The initial SHA was observed from the official ffmpeg.org HTTPS release archive.
# Every run, including cached/offline runs, verifies it before extracting/building.
VERSION="9.0.2"
SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
SOURCE_URL="https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.xz"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEPS="${ROOT}/.cache/deps"
PREFIX="${ROOT}/.cache/tools"
ARCHIVE="${DEPS}/ffmpeg-${VERSION}.tar.xz"
SOURCE="${DEPS}/ffmpeg-${VERSION}"
BUILD="${DEPS}/ffmpeg-${VERSION}-build"
WEBP_VERSION="1.6.0"
WEBP_SHA256="e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
WEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VERSION}.tar.gz"
WEBP_ARCHIVE="${DEPS}/libwebp-${WEBP_VERSION}.tar.gz"
WEBP_SOURCE="${DEPS}/libwebp-${WEBP_VERSION}"
WEBP_BUILD="${DEPS}/libwebp-${WEBP_VERSION}-build"
JOBS="${ORANGE_FFMPEG_JOBS:-4}"
case "$JOBS" in 1|2|3|4) ;; *) echo "ORANGE_FFMPEG_JOBS must be 1, 2, 3, or 4." >&2; exit 1 ;; esac

mkdir -p "$DEPS" "$PREFIX" "$BUILD"
mkdir -p "${DEPS}/tmp"
export TMPDIR="${DEPS}/tmp"
for directory in "$DEPS" "$PREFIX" "$BUILD"; do
    resolved="$(cd -- "$directory" && pwd -P)"
    case "$resolved" in "$ROOT"/*) ;; *) echo "Build directories must remain inside Orange." >&2; exit 1 ;; esac
done

command -v pkg-config >/dev/null || { echo "Building FFmpeg with WebP requires pkg-config. Install that build tool, then retry; no runtime installation is needed." >&2; exit 1; }
if [[ ! -f "$WEBP_ARCHIVE" ]]; then
    echo "Downloading the official libwebp ${WEBP_VERSION} source archive."
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 180 --retry 2 --output "${WEBP_ARCHIVE}.partial" "$WEBP_URL"
    actual="$(shasum -a 256 "${WEBP_ARCHIVE}.partial" | awk '{print $1}')"
    [[ "$actual" == "$WEBP_SHA256" ]] || { echo "libwebp source checksum mismatch. Refusing to build." >&2; exit 1; }
    mv "${WEBP_ARCHIVE}.partial" "$WEBP_ARCHIVE"
fi
actual="$(shasum -a 256 "$WEBP_ARCHIVE" | awk '{print $1}')"
[[ "$actual" == "$WEBP_SHA256" ]] || { echo "libwebp source checksum mismatch. Refusing to build." >&2; exit 1; }
if [[ ! -f "${WEBP_SOURCE}/configure" ]]; then
    tar -tf "$WEBP_ARCHIVE" | awk -v prefix="libwebp-${WEBP_VERSION}/" 'index($0,prefix)!=1 || $0 ~ /(^|\/)\.\.(\/|$)/ {bad=1} END {exit bad}'
    tar -xf "$WEBP_ARCHIVE" -C "$DEPS"
fi
mkdir -p "$WEBP_BUILD"
webp_flags=("--prefix=${PREFIX}" "--disable-shared" "--enable-static" "--disable-dependency-tracking"
            "--disable-gl" "--disable-sdl" "--disable-png" "--disable-jpeg" "--disable-tiff" "--disable-gif" "--disable-wic")
cd "$WEBP_BUILD"
echo "Building static libwebp ${WEBP_VERSION} with ${JOBS} workers."
if ! MACOSX_DEPLOYMENT_TARGET=13.0 CFLAGS="-O3 -mmacosx-version-min=13.0" LDFLAGS="-mmacosx-version-min=13.0" \
    "$WEBP_SOURCE/configure" "${webp_flags[@]}" > configure.log 2>&1; then
    tail -n 80 configure.log >&2; exit 1
fi
if ! make -j"$JOBS" > build.log 2>&1; then tail -n 80 build.log >&2; exit 1; fi
# Install only static libraries/headers, not libwebp's example programs.
if ! make -C sharpyuv install > install.log 2>&1; then tail -n 80 install.log >&2; exit 1; fi
if ! make -C src install >> install.log 2>&1; then tail -n 80 install.log >&2; exit 1; fi
webp_licenses="${PREFIX}/share/licenses/libwebp"
webp_sources="${PREFIX}/share/source/libwebp"
mkdir -p "$webp_licenses" "$webp_sources"
cp "${WEBP_SOURCE}/COPYING" "${WEBP_SOURCE}/PATENTS" "${WEBP_SOURCE}/AUTHORS" "$webp_licenses/"
cp "$WEBP_ARCHIVE" "$webp_sources/"
printf '%s  %s\n' "$WEBP_SHA256" "libwebp-${WEBP_VERSION}.tar.gz" > "${webp_sources}/SHA256SUMS"
printf '%s\n' "$WEBP_URL" > "${webp_sources}/SOURCE-URL.txt"
{
    printf 'MACOSX_DEPLOYMENT_TARGET=13.0 CFLAGS=%q LDFLAGS=%q ' '-O3 -mmacosx-version-min=13.0' '-mmacosx-version-min=13.0'
    printf '%q ' './configure' "${webp_flags[@]}"
    printf '\nmake -j%s\nmake -C sharpyuv install\nmake -C src install\n' "$JOBS"
} > "${webp_sources}/CONFIGURE.txt"
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"
export PKG_CONFIG_PATH=""

if [[ ! -f "$ARCHIVE" ]]; then
    echo "Downloading the official FFmpeg ${VERSION} source archive."
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 180 --retry 2 --output "${ARCHIVE}.partial" "$SOURCE_URL"
    actual="$(shasum -a 256 "${ARCHIVE}.partial" | awk '{print $1}')"
    [[ "$actual" == "$SHA256" ]] || { echo "FFmpeg source checksum mismatch. Refusing to extract or build." >&2; exit 1; }
    mv "${ARCHIVE}.partial" "$ARCHIVE"
fi
actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$actual" == "$SHA256" ]] || { echo "FFmpeg source checksum mismatch. Refusing to extract or build." >&2; exit 1; }
if [[ ! -f "${SOURCE}/configure" ]]; then
    tar -tf "$ARCHIVE" | awk -v prefix="ffmpeg-${VERSION}/" 'index($0,prefix)!=1 || $0 ~ /(^|\/)\.\.(\/|$)/ {bad=1} END {exit bad}'
    tar -xf "$ARCHIVE" -C "$DEPS"
fi

flags=(
    "--prefix=${PREFIX}"
    "--disable-shared" "--enable-static"
    "--disable-gpl" "--disable-nonfree"
    "--disable-autodetect" "--disable-network"
    "--disable-doc" "--disable-debug" "--disable-devices"
    "--disable-ffplay" "--enable-ffmpeg" "--enable-ffprobe"
    "--enable-videotoolbox" "--enable-audiotoolbox"
    "--enable-zlib"
    "--enable-libwebp" "--pkg-config-flags=--static"
    "--extra-cflags=-mmacosx-version-min=13.0"
    "--extra-ldflags=-mmacosx-version-min=13.0"
)
cd "$BUILD"
echo "Configuring FFmpeg ${VERSION}; logs stay in .cache/deps."
if ! MACOSX_DEPLOYMENT_TARGET=13.0 "$SOURCE/configure" "${flags[@]}" > configure.log 2>&1; then
    tail -n 80 configure.log >&2
    exit 1
fi
echo "Building FFmpeg and ffprobe with ${JOBS} workers."
if ! make -j"$JOBS" > build.log 2>&1; then
    tail -n 80 build.log >&2
    exit 1
fi
if ! make install > install.log 2>&1; then
    tail -n 80 install.log >&2
    exit 1
fi

LICENSES="${PREFIX}/share/licenses/ffmpeg"
SOURCES="${PREFIX}/share/source/ffmpeg"
mkdir -p "$LICENSES" "$SOURCES"
cp "${SOURCE}/COPYING.LGPLv2.1" "${SOURCE}/COPYING.LGPLv3" "${SOURCE}/LICENSE.md" "$LICENSES/"
cp "$ARCHIVE" "$SOURCES/"
cp "${ROOT}/scripts/build-ffmpeg.sh" "$SOURCES/"
printf '%s  %s\n' "$SHA256" "ffmpeg-${VERSION}.tar.xz" > "${SOURCES}/SHA256SUMS"
printf '%s\n' "$SOURCE_URL" > "${SOURCES}/SOURCE-URL.txt"
{
    printf 'MACOSX_DEPLOYMENT_TARGET=13.0 '
    printf '%q ' './configure' "${flags[@]}"
    printf '\nmake -j%s\nmake install\n' "$JOBS"
} > "${SOURCES}/CONFIGURE.txt"
"${PREFIX}/bin/ffmpeg" -version > "${SOURCES}/BUILD-VERSION.txt"
echo "Built backend: ${PREFIX}/bin/{ffmpeg,ffprobe}"
echo "License notices and matching source archive: ${PREFIX}/share/"
