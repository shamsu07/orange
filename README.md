# Orange

Orange is an MIT-licensed native macOS file converter with contextual Finder wheels. Drag files, tap **Shift** for conversions, **Command** for tools or **Control** for actions, release over the wheel, then click an option. The wheel stays open without holding the key or mouse. Hovering and releasing the original drag never run an operation.

[Download for Apple silicon](https://github.com/shamsu07/orange/releases/latest) · [Website](https://shamsu07.github.io/orange/) · [Usage guide](https://shamsu07.github.io/orange/guide/) · [Report a bug](https://github.com/shamsu07/orange/issues)

Orange aims to reproduce Tangerine's workflow, but **complete 1:1 parity is not established**. See the [parity contract](docs/reference-parity.md) and the [known limits](#boundaries-and-remaining-work).

## Install

Download the DMG from [GitHub Releases](https://github.com/shamsu07/orange/releases/latest). The 0.1.6 release targets **Apple silicon and macOS 13 or later**. Intel and universal downloads are not provided. A packaged app needs no compiler or additional converter installation.

1. Open `Orange-0.1.6-macos-arm64.dmg`.
2. Drag **Orange** to **Applications**, eject the image, then open Orange from Applications.
3. Choose the optional launch-at-login setting and click **Enable Orange**.

After setup, background launches stay in the menu bar. Open Settings from the menu bar or by reopening Orange. Login registration failures do not block setup; macOS can require approval in Login Items. The portable ZIP contains the same app. Each release includes SHA-256 checksums; local packages are written to `dist/`.

The release is **ad hoc signed and not notarized**. macOS can block the first launch of a downloaded copy. After checking the source and release, use the app-specific **Open Anyway** control in System Settings → Privacy & Security if you choose to proceed. Do not disable Gatekeeper globally. Fresh installation and reboot/login acceptance remain unverified; the deployment target does not establish macOS 13 runtime validation.

## Updates

Orange 0.1.5 adds [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0) updates. Optional background checks run on a daily schedule and can be disabled in Settings. A newer release makes an **Update** button available; scheduled checks do not open a window over Finder. You can also choose **Check for Updates…** from Orange's menu.

Downloading and installation require your action. Orange verifies both the HTTPS update feed and downloaded archive with its embedded Ed25519 public key before installation; there are no silent installs. Installation waits for active work before relaunching. Checks contact GitHub Pages, and requested downloads contact GitHub Releases. These services receive ordinary network-request information, including your IP address; Orange disables Sparkle system profiling. File contents and file paths are not included in update requests.

Versions through 0.1.4 have no updater. Install the latest version once to receive future updates through Orange. An update signature does not make this release notarized.

## Current features

| Area | Behavior |
| --- | --- |
| Wheel | Rounded sectors, 252 pt default, 220–560 pt size, Glass/Solid with Reduce Transparency fallback, fixed targets, original tones, optional subtle hover haptics (default on), keyboard/accessibility selection |
| Menus | Command tools configurable per image/video/audio/PDF family; common Control actions configured once. Shift conversions always show all actually supported routes, with paging when needed |
| Images | Native JPEG/PNG/HEIC/TIFF/BMP/GIF/AVIF where encoders exist; WebP native or bundled libwebp; image-to-PDF, rotation, OCR, QR and selected metadata removal |
| Resize/crop | Pixel dimensions and actual temporary-encoding size estimates; aspect presets and draggable crop selection. Originals remain unchanged |
| Image compression | JPEG/HEIC quality selection with measured savings. Same pixel dimensions; unchanged/larger results are rejected |
| PDFs | Merge, explicit split-after-page or custom range partitions, TXT/MD with local OCR fallback, every-page image export, selected document-information removal |
| PDF reduction | DPI/quality presets and estimated size; explicit consent required because pages become images and searchable text, vectors, links, forms, annotations, tags and signatures are lost |
| Video/audio | Available FFmpeg conversions; snapshot frame preview/timeline, trim range with playback, speed preview/output duration, quality controls, extraction, normalization and metadata removal |
| Details | General file information plus bounded image/PDF/media metadata; explicit copy button and multi-file selector |
| Actions | AirDrop chooser, floating shelf, Copy, Copy Path, Move, Terminal at selected/containing folder; Create ZIP for multiple items |
| Archives | ZIP/TAR from files or folders, including selections from different folders with unique entry names; single-file GZIP. No extraction |
| Documents | Native TXT/Markdown/RTF/DOC/DOCX imports and TXT/MD/HTML/RTF/DOCX exports; quoted CSV/TSV and SRT/VTT conversion |

**Compress versus Resize:** Resize reduces pixel dimensions. Image Compress keeps dimensions and changes encoding quality, trading fidelity for bytes. An already efficiently encoded image may save little; Orange now previews actual output size and refuses a successful-looking copy with no savings. PNG has no JPEG-style quality control. Media compression can produce a larger file and reports the actual result rather than promising a target size.

The public AppKit haptic API provides a pattern, not an intensity control. Orange requests the alignment pattern with a rate gate; perceived strength depends on the hardware. Physical feel and sound latency still need user acceptance.

## Files, privacy and resource controls

Conversions and previews run locally. There are no Orange accounts, file uploads, analytics or automatic backend downloads. Update checks and user-requested update downloads use the network as described above. AirDrop is an explicit user sharing action. Conversion/tool outputs preserve sources and use same-folder staging plus exclusive atomic publication; filename collisions get numbered suffixes. **Move changes source locations** and reports partial completion if a later move fails.

Saved jobs and heavyweight image/PDF/media previews share a **two-worker limit**. Preview sliders debounce work, reject stale results and clean isolated temporary workspaces. Closing or quitting cancels work; termination waits for retired workers before exiting. FFmpeg decoder/encoder threads are bounded to at most four per job, with two filter threads. Capability probes are cached. Finder observation uses event notifications rather than a recurring scan; sound engines and media observers stop when their panels close. Optional update checks have a separate daily schedule.

These are specific controls, not a guarantee of low energy use for every workload or absence of security flaws. See [verification](docs/verification-0.1.4.md) for measured evidence and [architecture](docs/architecture.md) for file-format limits and trust boundaries. Native decoders still process untrusted content; broad fuzzing and an independent security audit have not been completed.

## Build and test

Requires macOS 13+ and a Swift 6 compiler; the package currently uses Swift 5 language mode. Runtime checks have been performed on macOS 27.0.1, not macOS 13. The build targets the host architecture.

```sh
bash scripts/build.sh
open build/Orange.app
PATH="$PWD/.cache/tools/bin:$PATH" bash scripts/test.sh
```

The 0.1.4 fully enabled local suite passed **198 tests, zero failures and zero skips**, without compiler warnings; the final PDF text layout received focused checks and a native recheck. This is historical evidence for that version, not a test result for later changes. See [verification](docs/verification-0.1.4.md) and each release's notes for subsequent checks. Caches and test fixtures stay inside the repository. Native Vision/CoreVideo/audio integration needs normal macOS service access. Without FFmpeg, media integration coverage explicitly skips unavailable routes. The [CI workflow](.github/workflows/ci.yml) runs tests, a release build, signing verification and self-check; a workflow file is not a hosted pass.

The app includes the repository-local backend when available. `bash scripts/build-ffmpeg.sh` explicitly downloads pinned official sources and builds FFmpeg/libwebp inside Orange. See [backend build notes](docs/ffmpeg-build.md). The application itself never downloads converters.

```sh
bash scripts/package.sh
# Or package the already verified bundle without rebuilding:
bash scripts/package.sh --no-build
```

Packaging validates app integrity, source/license materials, ZIP and DMG integrity, and writes checksums. It refuses to replace existing artifacts. Preserve the previous `SHA256SUMS` under a versioned name before making another release.

Optional Developer ID signing/notarization uses configured `ORANGE_SIGN_IDENTITY` and `ORANGE_NOTARY_PROFILE`. A notary profile explicitly authorizes an Apple submission. Local packaging does not publish a release; ad hoc signing does not imply notarization.

## Boundaries and remaining work

- The latest 0.1.4 user check passed Shift/Command/Control on the first attempt. The intermittent 0.1.3 failure was not captured or causally diagnosed. Repeated Finder reliability, full reference parity, edge/multi-display behavior and installation/login acceptance remain unqualified; injected tests cannot prove native event delivery. The user confirmed haptic output feels click-like and requested keeping it; it is not a custom vibration.
- No matched-quality Tangerine performance comparison or long-duration battery qualification. A previous synthetic 4K image diagnostic reached about 1.15 GB peak RSS; RSS differs from charged footprint. See [benchmark evidence](docs/benchmarks/2026-10-21-arm64-v5-detached.json).
- File extension recognition does not prove decodability. Menus check real native/backend capabilities. Animated and multipage images are rejected.
- PDF OCR exports plain text, not an editable Office reconstruction or searchable PDF. Reduction is destructive rasterization, not a lossless optimizer. Metadata removal does not guarantee all embedded metadata is absent.
- Rich document layout is not guaranteed; Markdown is treated as source text. No HTML import, Pages/EPUB/PowerPoint/XLSX/ODS conversion, archive extraction, or complete image/video/audio editor.
- Speed conversion scales average frame cadence; variable-frame-rate timing preservation is not qualified. Media routes select applicable streams without promising every track/chapter/attachment.
- No durable job recovery, accurate percentage progress, Intel/universal release or validated notarization. Background update checks can be disabled, and installing an update requires user action.

## Code and contributions

`Sources/Orange/` contains native lifecycle, focused editing coordinators, state models and views. `Sources/OrangeCore/` contains converters, capability routing and output/process boundaries; `Sources/OrangeArtwork/` contains original segmented artwork. Generated-fixture core/app tests live in `Tests/`. Changes use focused, truthful commits with recorded verification; see [contributing](CONTRIBUTING.md), [architecture](docs/architecture.md) and [changelog](CHANGELOG.md).

Orange source and original assets use [MIT](LICENSE). No Tangerine code, artwork or sound is included, and Orange is not affiliated with Tangerine. Apple frameworks remain platform dependencies. Sparkle and its bundled components retain their upstream notices. Bundled FFmpeg retains LGPL terms; libwebp retains its BSD license and patent notice. Matching source, configuration and notices travel with the packaged app. See [third-party notices](THIRD_PARTY_NOTICES.md), the [security policy](SECURITY.md) and [code of conduct](CODE_OF_CONDUCT.md).
