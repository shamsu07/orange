# Orange

Orange is an open-source macOS menu-bar file converter. Its target is Tangerine's contextual Finder drag wheels and local conversion workflow, described in the [App Store listing](https://apps.apple.com/in/app/tangerine-file-converter/id6813034065?mt=12) and [product website](https://tangerineformac.com/).

**Orange is not a complete 1:1 Tangerine replica yet.** Native Tangerine 2.0.2 evidence now includes General/Formats settings and a user-provided screenshot of its image wheel during a real held drag. Orange's revised wheel follows that observed geometry and ordering, but exact visuals, complete Finder workflows, remaining native tools and performance parity are not established. See the [reference and parity contract](docs/reference-parity.md).

Orange 0.1.3 passed **111 tests, zero failures and zero skips** on **22 October 2026**: 69 core tests and 42 app tests, with no compiler warnings. **Its native acceptance failed:** the user still encountered a first-attempt wheel activation failure after the native-session rewrite. A subsequent diagnostic attempt worked, which does not establish a fix. Eighteen controller tests cover first drags, file changes, app switching, event ordering, cancellation and missing mouse-up recovery, but cannot prove Finder's event delivery. Earlier native checks completed a rotation and opened the AirDrop chooser and floating shelf; device transfer and real reboot/login remain unverified. Runtime results cover macOS 27.0.1; macOS 13 is the deployment target without runtime validation yet. See [0.1.3 verification](docs/verification-0.1.3.md).

## Install a packaged build

A packaged build does not require Swift, Xcode or a compiler. Local Apple silicon artifacts are in `dist/Orange-0.1.3-macos-arm64.dmg` and `.zip`; no public download URL is published yet.

1. Open `Orange-<version>-macos-<architecture>.dmg`.
2. Drag **Orange** onto **Applications** in the disk image.
3. Eject the disk image, then open Orange from Applications.

On first launch, choose whether to launch at login, then click **Enable Orange**. Registration occurs only through that explicit setup action or the Settings toggle; macOS can require Login Items approval. Login is optional: registration failures never block setup, and Settings offers retry and error details. After setup, background launches stay in the menu bar. Use the menu-bar item for Settings, files and activity rather than expecting a large window at every launch.

The portable ZIP contains the same complete `Orange.app`; unzip it and move the app to Applications. Release artifacts include `SHA256SUMS`. The current local app is ad hoc signed and is not a published or notarized release; package generation alone does not change that status.

Ad hoc signing verifies bundle integrity but does not identify a trusted developer to Gatekeeper. A downloaded test build can be blocked on first launch. For a build whose source and checksum you trust, use macOS **System Settings → Privacy & Security → Open Anyway** if offered, then confirm the system prompt, following [Apple's opening guidance](https://support.apple.com/en-au/102445). An ordinary drag-and-open experience still needs a Developer ID signed, notarized release. These installation and first-launch UI steps have not been validated end to end.

## Build from source

Requires macOS 13 or later and a Swift 6 compiler. The package uses Swift 5 language mode. The current build host runs macOS 27; macOS 13 runtime compatibility has not been validated. The build produces the host's architecture, not a universal binary.

From the repository root:

```sh
bash scripts/build.sh
open build/Orange.app
```

The build script creates a release app bundle with original generated artwork and an ad hoc signature. Set `CONFIGURATION=debug` for a debug bundle or `ORANGE_SIGN_IDENTITY` to choose a signing identity. If the repository-local FFmpeg backend exists, the script includes its executables, matching source and license materials in the app. Build that backend first with `bash scripts/build-ffmpeg.sh`; this explicit step downloads a pinned official source archive and compiles it inside the repository.

Run the test suite separately:

```sh
PATH="$PWD/.cache/tools/bin:$PATH" bash scripts/test.sh
```

Build caches and generated test fixtures stay inside the repository. The confirmed 111-test run used the local source-built FFmpeg/libwebp backend and normal macOS Vision/CoreVideo/audio service access. Restricted automation sandboxes can block these services; running without a media backend changes coverage and can skip media checks.

The [GitHub Actions workflow](.github/workflows/ci.yml) runs native tests, a release build, signature verification and the command-line self-check on `macos-latest`. It does not download or compile FFmpeg. Media integration tests explicitly skip when FFmpeg/ffprobe or required encoders are unavailable; hosted-runner results are separate from the fully enabled local run above. No hosted CI pass is claimed until the workflow runs.

## Package for distribution

```sh
bash scripts/package.sh
```

This builds the app, verifies its signature and creates these files in `dist/`:

- `Orange-<version>-macos-<architecture>.dmg`, with Orange and an Applications shortcut.
- `Orange-<version>-macos-<architecture>.zip`, preserving the complete app bundle.
- `SHA256SUMS`, covering the DMG and ZIP.

Use `bash scripts/package.sh --no-build` to package an existing verified `build/Orange.app`. The script uses a unique staging directory under `.cache/package/`, checks archive/image integrity, preserves bundled FFmpeg source/notices, and refuses to overwrite existing release artifacts. Move a previous `dist/` release aside before packaging again. Creating packages does not publish or upload a release.

The `--no-build` path was smoke-tested on the existing arm64 0.1.0 bundle: ZIP/DMG integrity and final checksums passed; a read-only image mount verified the Applications shortcut, app signature, bundled FFmpeg source/licenses and command-line backend self-check. The mount stayed inside the repository and was detached afterward. DMG creation requires normal macOS disk-image service access; the restricted automation sandbox returned `Device not configured`. This was a packaging check, not a GUI installation or first-launch test.

Optional Developer ID signing and notarization require your own configured Apple developer identity and an existing `notarytool` keychain profile:

```sh
ORANGE_SIGN_IDENTITY="YOUR_DEVELOPER_ID_IDENTITY" \
ORANGE_NOTARY_PROFILE="YOUR_EXISTING_NOTARY_PROFILE" \
bash scripts/package.sh
```

The script signs a staged copy with hardened runtime. Supplying the notary profile explicitly opts in to Apple submissions; only accepted submissions with validated stapled tickets are reported as notarized. Without that profile, the script makes no notarization claim. This path still needs execution and distribution validation; no notarized release is asserted here.

## Implemented scope

| Area | Current behavior |
| --- | --- |
| Application | First-launch setup with explicit enable/login choice; quiet menu-bar operation afterward; file picker/drop target; contextual wheels; small activity panel, cancellation, Finder reveal and backend status |
| Preferences | Separate General, Formats, Compatibility and About tabs; Glass/Solid appearance; wheel size/preview; launch-at-login status; soft selection sound and reveal controls; configurable shortcuts and session conversion defaults |
| Still images | ImageIO decoding; native JPEG/PNG/HEIC/TIFF/BMP/GIF/AVIF outputs where available; WebP through a native encoder or FFmpeg/libwebp fallback; single-image PDF export; orientation-aware decoding |
| Image tools | Resize, rotate 90°, native text recognition, QR reading, supported metadata removal; JPEG/HEIC quality-based recompression |
| PDFs | TXT/MD export using text layers and local OCR fallback for scanned pages; every-page PNG/JPEG rendering at 300 DPI, with independent 10,000-pixel long-edge and 40-megapixel safety limits; merge, split, verified removal of standard private document-information fields |
| Text documents | TXT/Markdown, RTF, DOC, DOCX imports; TXT/MD/HTML/RTF/DOCX exports using native attributed strings. Plain-text exports flatten formatting; Markdown syntax is not rendered |
| Subtitles and tables | SRT ↔ VTT, subtitle TXT export, UTF-8 and BOM-marked UTF-16 text, quoted CSV ↔ TSV including embedded line breaks |
| Archives | ZIP/TAR creation for files or folders; single-file GZIP creation. Multiple ZIP/TAR sources must share one parent folder |
| Audio/video | FFmpeg-backed video MP4/MOV/MKV/WebM/AVI/WMV and audio MP3/M4A/WAV/FLAC/OGG/Opus/AIFF/WMA routes, offered only when the selected backend has the required encoders and input streams |
| Media tools | Recompression, trim, playback speed, audio extraction, PNG snapshot, loudness normalization, descriptive metadata removal |
| Actions | System AirDrop, floating file shelf, clipboard file references, explicit Move, line-separated Copy Path, open containing folders in Terminal |

Formats are discovered from the actual native encoders or FFmpeg backend. A recognized filename extension alone does not establish a working conversion. Animated images and multipage image containers are rejected rather than silently reduced to one frame. Image and video frames have a 40-megapixel safety limit. Text, subtitle, CSV/TSV and native rich-document imports have a 128 MiB input-file limit; these paths load documents in memory rather than promising streaming conversion.

**Wheel use:** drag a file, tap Shift/Command/Control, release the modifier and mouse over the wheel, then click an option. The wheel stays open without holding either input. Releasing the initial drag never executes an option. Escape or an outside click dismisses it. Arrow keys plus Return/Space also confirm after release.

The Finder overlay defaults to Shift for conversion, Command for tools, and Control for actions. Each wheel can select one of eight modifier combinations: Shift, Command, Control, Option, Option + Shift, Command + Shift, Control + Shift, or Option + Command. Retapping the active wheel shortcut advances to the next page when more than eight options exist.

The wheel now defaults to a **252-point diameter**, adjustable from 220 to 560 points, with rounded annular sectors, a transparent center and a small central label pill. The default is inferred from a 504-pixel reference circle at 2× scale; it is not a verified numeric Tangerine preference. A PNG image wheel places **JPG** at the top, then clockwise WebP, HEIC, TIFF, AVIF, BMP and PDF, filtering unavailable outputs and omitting the source format. Other image inputs follow the same format ordering. Glass/Solid appearance, a color fade respecting Reduce Motion, and original soft alternating selection tones are implemented. Selection sound works during the held drag and after release. Tone buffers and output audio are prepared when presenting the wheel and released on dismissal. Repeated movement within a segment stays silent; a 45 ms gate limits boundary jitter without queuing sounds. Segments never resize or move on hover and no trackpad haptic is requested; exact visual/audio parity and perceived latency are unverified.

Native Orange inspection observed onboarding, the 252-point Settings slider and the seven-label preview. Preview clicks select WEBP and update the central pill while keeping targets fixed. A local PNG rotation completed through the main window; AirDrop opened its system chooser and was cancelled without sending; Float opened a shelf containing the selected fixture. These checks do not establish all Finder drag sequences or device transfer. The user heard the earlier tones after release and reported suppression during the held gesture; the final audio correction has regression coverage, with subjective latency still unverified. Real setup/login registration remains unverified.

The native reference screenshot establishes a visible wheel during one real held drag. In 0.1.2, the user confirmed wheel persistence and held-drag tones, but then found intermittent first-drag activation after switching files or returning to Finder. A valid 256 × 256 WebP output was separately verified in that session. Version 0.1.3 removes the shared-pasteboard timing assumption and binds files from the actual native drag session. Complete repeated/app-switch acceptance, permissions, multiple displays, edge placement, cancellation, actions and setup/login behavior still need native verification. The main window also provides a direct file-picker/drop workflow.

## Bundled media backend

The current backend build includes **FFmpeg 9.0.2, ffprobe and libwebp 1.6.0 from official source**. Matching source archives, configurations, license and patent notices are copied under `Orange.app/Contents/Resources/Tools/share/`. Versions, hashes and build steps are recorded in [FFmpeg build notes](docs/ffmpeg-build.md). Orange source/artwork use MIT; FFmpeg retains LGPL terms, and libwebp retains its BSD license and patent notice.

This backend disables GPL/nonfree components, external codec autodetection, device capture and network support. It explicitly enables libwebp alongside native FFmpeg codecs and macOS frameworks; it does not include x264, LAME, libopus, libvorbis or libvpx. Consequently, MP3, Opus and WebM output are not guaranteed. The native Vorbis path explicitly writes OGG as stereo. Menus probe real encoders rather than promising every named route.

Four targeted WebP tests and the two real media integration tests passed with the updated backend, followed by the complete 111-test run. WebP fallback is limited to 16,383 pixels per side and removes descriptive metadata; broad image/color fidelity and complete Finder acceptance remain unqualified.

Discovery checks an explicit absolute `ORANGE_BACKEND_DIR`, then bundled tools, then PATH and standard install locations. A user-provided FFmpeg build can enable additional codecs and keeps its own upstream licenses. Native image/document workflows do not require FFmpeg. The application does not download or install converters automatically.

Some media operations re-encode to MP4 or M4A; compression does not promise a smaller file or an exact target size. Media processing accepts standalone local files and restricts protocol/container handling; it is not a network playlist downloader.

## Files, privacy, and settings

Conversion runs locally, without accounts, uploads, analytics, or a network requirement. Orange has no update downloader. AirDrop is a user-selected macOS sharing action. Source download and optional notarization happen only through explicitly run development/distribution scripts.

Conversions and tools preserve original files. Outputs are staged beside the source and published atomically without replacing an existing file; collisions receive numbered names. **Move changes the originals' locations.** It rejects existing destination names before starting, but a later filesystem failure can leave a partially completed move, which is reported.

At most two conversion jobs run at once. Heavy conversion and capability probing run away from the UI thread. FFmpeg decoder/encoder threads are bounded to at most four per job, with two filter threads. Cancellation stops subprocesses; quitting cancels and awaits running work before termination. These are resource controls, not measured performance claims.

The [v5 synthetic image diagnostic](docs/benchmarks/2026-10-21-arm64-v5-detached.json) reported approximately **1.15 GB peak RSS**, while charged physical footprint was **8.19 MB after JPEG conversion and 9.49 MB at the end**. These metrics differ; the RSS figure alone does not establish a 1 GB leak. This synthetic workload is neither photographic qualification nor a Tangerine comparison, and it does not prove optimization or memory behavior across all workloads.

Setup completion, Finder-wheel enablement, reveal-on-completion, appearance, diameter, feedback and the three drag shortcuts persist. Enabled feedback plays soft original synthesized tones on selection changes, with a separate sound after successful jobs. Hover does not perform an operation or request a trackpad haptic. Launch-at-login state comes from macOS ServiceManagement and can require user approval. Quality, image dimension, metadata-removal toggle, trim range and playback speed reset on restart. Activity and floating shelves are session-only. The Formats tab currently edits shared defaults rather than the reference's per-format policies.

## Known gaps

- No measured native Tangerine visual/behavioral parity or comparative throughput, memory, startup, energy, or idle benchmarks.
- Native repeated/app-switch acceptance failed in 0.1.3; intermittent first-attempt wheel activation remains unresolved. Complete multi-mode workflows and macOS 13 runtime validation remain outstanding.
- Launch-at-login integration and onboarding are implemented; installation/login acceptance is still pending. Folder policies, per-format quality/metadata/compression/dimension policies, Float target selection and Terminal application selection remain incomplete.
- PDF OCR is plain-text recognition for pages without a nonblank text layer, bounded to 150 DPI/2,400 pixels on the long edge. Recognition can contain errors; language coverage and difficult scans need validation. There is no PDF-to-editable-Office layout reconstruction, searchable-PDF generation, PDF compression, or general PDF page editor. PDF information removal does not guarantee removal of embedded XMP, attachment, image, or generated system metadata.
- No Pages, EPUB, PowerPoint, XLS/XLSX/ODS conversion, HTML/RTFD/text-clipping import, archive extraction/transcoding, or RAR/7z backend.
- No animated-image conversion, SVG rasterization guarantee, image crop/annotation/redaction/background tools, video join/crop/split/redaction, or complete audio editing suite.
- AVIF encoding remains dependent on native macOS capabilities. WebP has a native-or-libwebp path, but broad color-profile, gamut, HDR, bit-depth, alpha and metadata fidelity qualification is incomplete.
- No accurate percentage progress, durable job recovery, universal-binary build, validated notarized release, or automatic updates. Native tool parity remains unverified.

See [architecture](docs/architecture.md) for implementation boundaries, [reference parity](docs/reference-parity.md) for remaining acceptance work, and [contribution guidance](CONTRIBUTING.md) for development and pull requests.

## Source and license

| Path | Purpose |
| --- | --- |
| `Sources/Orange/` | AppKit lifecycle, SwiftUI interface, drag overlay, queue, settings, file actions |
| `Sources/OrangeCore/` | Capability routing, native converters, optional media backend, subprocess runner, atomic output publication |
| `Tests/OrangeCoreTests/` | Generated-fixture core and interaction-state tests |
| `Tests/OrangeAppTests/` | Native view, tool/action dispatch and injected login/sharing regression tests |
| `Sources/OrangeArtwork/` | Shared original vector icon for runtime and packaged resources |
| `scripts/` | Build/test/packaging entry points, source-built FFmpeg, app metadata, original icon generation |
| `docs/` | Architecture and reference/parity evidence |

Orange source and its original artwork use [MIT](LICENSE). No Tangerine application code, icons, audio or bundled product assets are included. Native macOS frameworks remain Apple-provided dependencies. FFmpeg retains LGPL terms; libwebp retains its BSD license and patent notice. Matching source, build configuration and notices travel with the app and DMG/ZIP packages. Packaging verifies libwebp materials and archive hash whenever the bundled FFmpeg configuration enables it.
