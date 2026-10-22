# Orange's local FFmpeg backend

Orange can build FFmpeg from its official source without installing anything system-wide or using binaries from Tangerine.

Run `./scripts/build-ffmpeg.sh` from the repository with Apple's command-line developer tools and `pkg-config` available. Build products, downloaded source, and logs remain inside `.cache/`. The script uses at most four compiler workers; set `ORANGE_FFMPEG_JOBS=1` through `4` to lower this limit. A repeated build verifies both cached source archives before reusing them. `pkg-config` is a build-time tool; its package lookup is restricted to Orange's local install prefix.

The pinned release is **FFmpeg 9.0.2**, from [the official release archive](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz). The SHA-256 observed from that archive over HTTPS is:

```
8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
```

This checksum pins the downloaded bytes. It is not a detached-signature verification or an independent audit of FFmpeg.

The build disables network access, GPL components, nonfree components, dependency autodetection, device capture, documentation, debug symbols, and ffplay. It keeps native FFmpeg codecs, explicitly enables macOS's system zlib for PNG decoding/encoding, and enables Apple's VideoToolbox and AudioToolbox frameworks. Both compiler and linker target macOS 13. It builds and statically links libwebp for WebP export. Other codec libraries such as x264, LAME, libopus, libvorbis, and libvpx are not installed or linked by this script. Orange discovers the encoders this build actually supplies; formats that require missing encoders remain unavailable.

The WebP dependency is **libwebp 1.6.0**, from [the official WebM Project archive](https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz), with observed SHA-256:

```
e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
```

Its static libraries are installed under `.cache/tools/lib`. Its BSD-style license, patent grant, and author notices are copied to `share/licenses/libwebp`, with the matching archive, checksum, origin URL, and configure command in `share/source/libwebp`. The common build script included under `share/source/ffmpeg` builds both dependencies. libwebp build logs are in `.cache/deps/libwebp-1.6.0-build/`.

When ImageIO has no WebP writer, Orange advertises WebP only after verifying FFmpeg's `libwebp` encoder. It normalizes a single still image through a private PNG, encodes one WebP frame, and removes the temporary files on success or failure. Transparency is retained; descriptive metadata is removed. Quality `0...1` maps to libwebp's lossy quality `0...100`; the highest setting is still lossy. WebP's limit is 16,383 pixels per side, so larger images must be resized explicitly. Animated images remain unsupported.

The exact configure command and build version are recorded in `.cache/tools/share/source/ffmpeg/CONFIGURE.txt` and `BUILD-VERSION.txt`. Build logs are in `.cache/deps/ffmpeg-9.0.2-build/`.

The installed layout is:

```
.cache/tools/bin/ffmpeg
.cache/tools/bin/ffprobe
.cache/tools/share/licenses/ffmpeg/{LICENSE.md,COPYING.LGPLv2.1,COPYING.LGPLv3}
.cache/tools/share/source/ffmpeg/ffmpeg-9.0.2.tar.xz
.cache/tools/share/source/ffmpeg/{build-ffmpeg.sh,CONFIGURE.txt,SHA256SUMS,SOURCE-URL.txt,BUILD-VERSION.txt}
.cache/tools/share/licenses/libwebp/{COPYING,PATENTS,AUTHORS}
.cache/tools/share/source/libwebp/{libwebp-1.6.0.tar.gz,CONFIGURE.txt,SHA256SUMS,SOURCE-URL.txt}
```

The build uses LGPL components. See [FFmpeg's license guidance](https://ffmpeg.org/legal.html) and the copied license texts. Orange invokes FFmpeg as a separate process. When distributing the backend, keep the matching source archive, build script/configuration, and license notices with it. Packaging the complete `.cache/tools` directory under `Orange.app/Contents/Resources/Tools` preserves those materials; backend discovery checks `Tools/bin` and `Tools` before the user's PATH.

To qualify this local backend, prepend the absolute `.cache/tools/bin` directory to PATH when running Orange's tests. To select a different build, set `ORANGE_BACKEND_DIR` to an absolute existing backend directory (either its install prefix or its `bin` folder); this takes precedence over bundled tools and PATH. Relative or missing directories are ignored. No runtime system installation is needed. Native image formats and documents continue to use macOS APIs.

The native FFmpeg Vorbis encoder accepts stereo only. When that encoder is selected, Orange explicitly writes two channels and reports this in the result. A user-provided build with libvorbis retains its broader channel support. Builds without external codec libraries do not guarantee MP3, Opus, or WebM output.
