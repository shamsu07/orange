# Third-party notices

Orange's source and original artwork are licensed under [MIT](LICENSE). Dependencies keep their own terms. The public repository does not contain Tangerine source, artwork or sounds, and Orange is not affiliated with Tangerine.

## Sparkle 2.10.0

- Source: [sparkle-project/Sparkle, tag 2.10.0](https://github.com/sparkle-project/Sparkle/tree/2.10.0).
- Resolved source revision: `eef1a539a373c1f1a320624b1130fc5de7b2e100`.
- License: MIT-style license, with separate BSD notices for bundled bsdiff/bspatch and other included code. The complete upstream notice is preserved in [licenses/Sparkle.txt](licenses/Sparkle.txt).
- Distribution: Swift Package Manager supplies the upstream binary framework; the app bundles that framework and its installer helpers. Its full notice is also included at `Orange.app/Contents/Resources/Licenses/Sparkle.txt`.

Sparkle's update verification is separate from Apple's code signing and notarization. Its presence does not make an ad hoc signed Orange build notarized.

## FFmpeg 9.0.2 and libwebp 1.6.0

The packaged media backend is built from pinned official source archives. FFmpeg retains its upstream LGPL terms. The selected build disables GPL and nonfree components, network protocols and automatic external dependency detection. libwebp retains its BSD license and patent notice. These licenses do not become MIT when bundled with Orange.

The app's `Contents/Resources/Tools/share/` directory includes matching source archives, licenses, configuration, source URLs and checksums. When libwebp is enabled, its `COPYING`, `PATENTS` and `AUTHORS` notices and matching source are required as well. See [backend build and redistribution details](docs/ffmpeg-build.md) for exact configuration and source materials. Source-only builds can omit this optional backend.

## macOS frameworks and tools

AppKit, SwiftUI, ImageIO, Core Graphics, PDFKit, Vision, AVFoundation, ServiceManagement and other macOS system components remain platform dependencies under Apple's terms. Orange uses installed macOS archive utilities for ZIP, TAR and GZIP creation; those executables are not redistributed by Orange.

Contributors must document the source, exact version, license and redistribution requirements before adding a new dependency or asset. Release packaging must preserve the notices for the components actually shipped.
