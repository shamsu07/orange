# Orange architecture

Orange is a native macOS application with a UI-independent conversion library. It targets macOS 13 or later, requires a Swift 6 compiler, and currently compiles in Swift 5 language mode. Development builds have been performed on a macOS 27 host; the deployment target is not evidence of validated macOS 13 runtime behavior.

The public Tangerine reference describes contextual drag wheels and local, source-preserving conversion in its [App Store listing](https://apps.apple.com/in/app/tangerine-file-converter/id6813034065?mt=12) and [website](https://tangerineformac.com/). Orange's implemented subset and unverified requirements are separated in the [parity contract](reference-parity.md). Exact parity and superior performance are goals, not current results.

## Components

| Component | Responsibility |
| --- | --- |
| `Sources/Orange/OrangeApp.swift` | AppKit entry point, menu-bar item, main/preferences windows, graceful termination, floating shelves, original artwork |
| `Sources/Orange/AppModel.swift` | Main-actor state, selected inputs, capability snapshots, two-job limiter, activity state, settings, explicit file actions |
| `Sources/Orange/DragWheelController.swift` | Event snapshots, gesture generations, native-session binding, contextual wheel lifecycle and overlay presentation |
| `Sources/Orange/DragWheel.swift` | Wheel geometry/layers, native dragging destination callbacks and deliberate option confirmation |
| `Sources/Orange/MainView.swift` | SwiftUI file selection, conversion/tools/actions choices, activity, settings, backend information |
| `Sources/Orange/PreferencesView.swift` | Separate native General/Formats/Compatibility/About settings window; real preference bindings, shared conversion defaults and backend information |
| `Sources/Orange/OnboardingView.swift` | First-launch explanation, explicit Enable Orange action and optional login registration/approval flow |
| `Sources/Orange/LaunchAtLogin.swift` | macOS `SMAppService.mainApp` state, explicit registration/unregistration and Login Items approval handling |
| `Sources/Orange/ActivityPanel.swift` | Small nonactivating job panel with state, cancellation and Finder reveal |
| `Sources/Orange/WheelFeedback.swift` | Precomputed original tones and an output-only audio engine active only while the wheel is visible |
| `Sources/OrangeCore/FileDragCapture.swift` | Fixed file URLs bound to an actual native dragging sequence; released selections reject new drag data |
| `Sources/OrangeCore/WheelInteraction.swift` | Explicit drag, picker, preview and confirmation state transitions |
| `Sources/Orange/FileActionCoordinator.swift` | Retained AirDrop sessions, clipboard actions and Terminal result feedback |
| `Sources/OrangeArtwork/OrangeIcon.swift` | Shared original segmented artwork for app, generated ICNS and menu bar |
| `Sources/OrangeCore/WheelGeometry.swift` | Pure bounded annular geometry, clockwise sector ordering and hit testing |
| `Sources/OrangeCore/Models.swift` | File families, output formats, tool/action identifiers, settings, results and errors |
| `Sources/OrangeCore/ConversionEngine.swift` | Route selection, intersection of selection capabilities, grouped PDF merge/archive jobs |
| `Sources/OrangeCore/ImageConverter.swift` | ImageIO/Core Graphics still-image processing; Vision text and QR recognition |
| `Sources/OrangeCore/DocumentConverter.swift` | PDFKit/Core Graphics PDFs, local Vision OCR fallback, native attributed-string documents, subtitle and delimited-text parsing |
| `Sources/OrangeCore/ArchiveConverter.swift` | Direct ZIP/TAR/GZIP utility invocation for archive creation, without extraction |
| `Sources/OrangeCore/MediaConverter.swift` | Optional FFmpeg/ffprobe discovery, stream inspection, encoder checks and media operations |
| `Sources/OrangeCore/ProcessRunner.swift` | Direct executable invocation, concurrent pipe draining, bounded diagnostics, cancellation, optional probe timeouts |
| `Sources/OrangeCore/OutputWriter.swift` | Same-directory staging, nonempty output check and exclusive atomic publication |
| `Tests/OrangeCoreTests/` | Generated fixtures and core verification; fixtures live under `.cache/tests/` |
| `scripts/` | Local app bundling/signing, icon generation and isolated test/build cache locations |

## Selection and job flow

1. The user selects files through the main window or an observed drag. The UI records file URLs, not uploaded content.
2. A detached worker computes capabilities. Image routes check decodability and installed ImageIO encoders; media routes inspect real streams and FFmpeg encoders. The main actor receives a completed capability snapshot.
3. Compatible outputs/tools are intersected for multiple inputs. Ordinary conversions become individual jobs; PDF merging and archive creation receive a grouped selection.
4. A global actor admits at most two conversion jobs, including across separate batches. Each job captures the current conversion settings and performs blocking native or subprocess work in a detached task.
5. The converter stages and validates output, publishes it without replacing existing files, and returns output URLs plus any fidelity limitation. The UI records completion/failure/cancellation and optionally reveals the results in Finder.

The wheel observes a left-drag plus configured modifier, then arms a native destination under that event's pointer location. Only `NSDraggingInfo.draggingPasteboard` supplies file URLs; its sequence number binds one selection. A named pasteboard change is neither a gate nor a fallback. This replaces 0.1.2's invalid assumption that a copied global mouse-down event always precedes Finder publishing its drag data. Each gesture has an identity that guards deferred releases and capability results. Event snapshots carry their own timestamps, modifiers and coordinates; older copies cannot mutate a later gesture. A temporary movement monitor recovers a consumed mouse-up only while the receiver is armed. Returning to another app dismisses a released picker without canceling a Finder-owned drag. See [0.1.3 verification](verification-0.1.3.md).

Verified native drag files latch after release and require a fresh matching mouse-down/up or explicit keyboard/accessibility confirmation. Hover and drag release never run an operation. Missing/changed native files or an unexpected replacement session cancel instead of using cached inputs; known retired callbacks are ignored. Destination callbacks never return move/delete operations. Reopening the same selection restores interaction after reset; unchanged capability refreshes preserve the current page. Preview closing resets its controller state. Dialogs and sharing are deferred until the drag callback returns. AirDrop sessions retain their service and source window until a delegate result; clipboard actions report success and sharing/Terminal failures are surfaced.

The wheel uses passive event monitoring rather than suppressing or rewriting Finder drag events. Default shortcuts are Shift/Command/Control for conversion/tools/actions. Each is configurable among eight combinations: Shift, Command, Control, Option, Option + Shift, Command + Shift, Control + Shift, and Option + Command. A wheel shows at most eight choices per page; retapping its active shortcut cycles pages.

The rewritten overlay uses rounded annular sectors, a transparent center, a small central label pill and a 252-point default diameter, clamped to 220...560 points. That default is inferred from a user-provided 504-pixel native reference capture at 2× scale, not from a verified numeric reference preference. For image conversions, wheel choices use the observed clockwise ordering JPEG/PNG/WebP/HEIC/TIFF/AVIF/BMP/PDF, omit a shared source format and filter actual capabilities; thus a PNG input presents JPG at the top, followed by WebP/HEIC/TIFF/AVIF/BMP/PDF when available. The wheel uses the JPG label; manual operation labels retain JPEG. The manual converter retains its full supported-output list.

Glass/Solid appearance controls the background. A color fade highlights fixed targets and honors Reduce Motion. There are no alignment haptics. Original soft alternating tones work during the held drag, picking and preview. The wheel prepares two PCM buffers and an output-only AVAudioEngine before highlighting, then schedules buffers without file access or waveform generation on hover. Dismissal stops/releases the engine. A 45 ms rate gate suppresses boundary jitter without queuing delayed feedback; repeated updates within one target are silent. Native output preparation passed, but perceived latency and reference sound/timing parity remain unmeasured.

Native user evidence includes a reference wheel shown during a real held drag. Earlier Orange checks observed onboarding, the 252-point Settings slider, fixed-target preview selection, a completed image rotation, a floating shelf and the system AirDrop chooser, cancelled without sending. The user confirmed held-drag tones and release persistence in 0.1.2, then found unreliable activation. The 0.1.3 controller has separate regression coverage; actual repeated/app-switch routing is a native acceptance check. Real login approval/reboot, display edges and multiple displays remain unverified. See the current [verification report](verification-0.1.3.md).

## Backend boundaries

ImageIO/Core Graphics provide still-image decoding, orientation handling, encoding and PDF creation. Availability is queried rather than inferred from names. WebP uses a native encoder when present, otherwise a verified FFmpeg/libwebp fallback; that fallback limits each side to 16,383 pixels and removes descriptive metadata. Four targeted WebP tests passed, with broad color/metadata qualification still incomplete. Animated and multipage sources are rejected. Vision handles image text recognition and QR reading. PDF text export reuses the shared Vision execution helper, which attempts acceleration and supported CPU/revision fallback paths.

PDFKit loads PDF documents and supports text-layer extraction, page copying, merge/split, and rewriting. Core Graphics renders each exported image page sequentially at 300 DPI, independently of the image Resize setting. `ConversionSettings.pdfMaxDimension` defaults to 10,000 pixels on the long edge, with a hard 10,000-pixel per-side ceiling and 40-million-pixel limit. A smaller explicit PDF bound reduces the raster resolution; the 40-megapixel check rejects oversized page rasters. Exported images include the effective DPI metadata. A default A4 page is approximately 2,481 × 3,508 pixels. The shared renderer applies the PDF drawing transform, including page rotation.

For TXT/MD export, a nonblank page text layer is used directly. Otherwise the page is rasterized at up to 150 DPI with a 2,400-pixel long-edge bound and processed by an accurate local Vision text-recognition request. Pages are processed sequentially with per-page autorelease pools; text and OCR results retain page order, including blank-page separators. Entirely unreadable/blank documents fail before output publication. This is page-level fallback: a page containing some digital text does not also OCR its embedded images. OCR can contain errors, and this does not reconstruct layout, generate a searchable PDF, or produce editable Office documents. No model download is requested by the converter.

Metadata removal clears selected document-information fields and reopens the output to verify their absence; embedded metadata can remain. PDF compression is not advertised because rewriting alone does not establish a meaningful size reduction.

Native attributed strings import TXT/Markdown, RTF, DOC and DOCX and export TXT/MD/HTML/RTF/DOCX. HTML import is intentionally unavailable because native HTML importing can involve WebKit, remote resources, and main-thread constraints. Markdown is treated as source text. Rich office layout fidelity is not guaranteed. Pages, EPUB, presentations and binary spreadsheet formats have no backend.

Subtitle parsing validates timestamps, supports long-hour timestamps and preserves cue payloads. VTT exports include the required header. VTT-to-SRT reports loss of positioning, identifiers, style and region metadata that SRT cannot represent. TXT exports omit timing/structural blocks. CSV/TSV parsing recognizes quoted fields, escaped quotes and embedded line breaks, rejecting malformed quoting instead of silently splitting data.

Archive creation calls macOS `zip`, `tar` or `gzip` directly, with argument arrays and a controlled working directory. ZIP/TAR multi-item creation requires a shared parent. Relative entry names avoid recording absolute source paths. Symbolic links are archived as links rather than followed into external directory trees. GZIP operates on a staged copy. No archive is extracted or executed, and archive-to-archive transcoding is unavailable.

The backend build now includes source-built FFmpeg 9.0.2, ffprobe and libwebp 1.6.0, with matching archives, configurations, LGPL/BSD and patent notices copied under `Contents/Resources/Tools/share/`; see [backend build notes](ffmpeg-build.md). Native image/document work remains usable without it in a source-only build. Discovery prioritizes an explicit absolute `ORANGE_BACKEND_DIR`, then bundled tools, then PATH/standard locations. The application does not download or install converters. The explicit backend build script downloads pinned official archives.

Menus depend on real encoders and available audio/video streams. The bundled build disables network, GPL/nonfree components and external codec autodetection; MP3/Opus/WebM output is not guaranteed. A media conversion selects the first applicable streams rather than promising every track, subtitle, attachment or chapter. Native Vorbis output explicitly uses stereo. Technical container fields can remain after descriptive metadata removal. Third-party licenses remain separate from Orange's MIT license.

## Resource limits and cancellation

Two jobs can run simultaneously. Each FFmpeg job uses a decoder/encoder thread limit of `min(4, max(1, activeProcessorCount / 2))` and two filter threads. Encoder and media probes are cached; probe subprocesses have ten-second timeouts. Image and video frame sizes are bounded to 40 million pixels, with a 32,768-pixel per-side limit. PDF pages have their separate rendering limits above.

Text/subtitle/delimited-text readers and native RTF/DOC/DOCX import preflight a regular input file with a maximum size of 128 MiB before loading or invoking the native importer. The plain-text reader checks the loaded byte count again before decoding. A generated sparse-file test covers oversized text, CSV, RTF and DOCX rejection without a large fixture allocation. These converters are in-memory implementations; the byte cap is not a streaming guarantee or an exact bound on decoded rich-document memory, including compressed DOCX expansion.

`ProcessRunner` launches executable URLs without a shell, drains stdout and stderr concurrently, and retains bounded diagnostics. Task cancellation terminates the child process and escalates to a kill if it ignores termination. Native converters check cancellation at safe boundaries; a synchronous platform call cannot always be interrupted immediately. App termination cancels and awaits queued/running conversions and capability tasks before replying to the termination request.

These controls prevent unbounded job and thread creation; they do not establish target performance. The [v5 synthetic image diagnostic](benchmarks/2026-10-21-arm64-v5-detached.json) recorded 1,152,040,960 bytes peak RSS, with charged physical footprint of 8,193,416 bytes after JPEG work and 9,487,440 bytes at the end. RSS and charged footprint are different metrics; this is not evidence of a 1 GB leak or proof of memory behavior across workloads. No matched-quality Tangerine, photographic, energy or long-running UI comparison has been completed.

## Output and source integrity

`OutputWriter` allocates a unique hidden stage beside the input. A converter writes only to that stage. After a nonempty-output check and cancellation check, a hard link publishes the completed file atomically. Existing destinations are never replaced; a numeric suffix resolves collisions. A `defer` removes the stage after publication or failure. Some providers additionally reopen, inspect or integrity-test output; validation is provider-specific, not a universal round-trip fidelity guarantee.

PDF multi-output operations track newly published page files and clean them up if the remaining operation fails. Original conversion inputs are preserved. The explicit Move action changes source locations, checks destination collisions before starting, and reports possible partial completion after a later filesystem failure. Clipboard copy stores file references; it does not create another filesystem copy.

## Privacy, state and packaging

Conversion is offline. The application has no accounts, uploads, analytics, automatic converter installation or update downloader. AirDrop invokes the user's selected macOS sharing action; Terminal opens folders through the system workspace API.

Setup completion, Finder-wheel enablement, automatic Finder reveal, Glass/Solid appearance, wheel diameter, feedback and the three modifier bindings persist through `UserDefaults`. Selection feedback uses soft original synthesized tones without trackpad haptics; successful jobs retain their separate completion sound. Metadata removal, quality, image dimension, trim range and speed are session defaults. Jobs and floating shelves are not durable state; published outputs remain ordinary files.

First launch shows onboarding. Optional login registration cannot block the setup completion callback; .notFound attempts OS registration instead of displaying the incorrect reopen-app error. Wheel monitoring starts only after the explicit Enable Orange flow completes. The user can request launch at login during setup or Settings; merely reading login status does not register the app. `SMAppService` registration, pending approval and errors are reflected from macOS, with an explicit link to Login Items Settings. Once setup is complete, background launches stay in the menu bar. File jobs use a small nonactivating activity panel rather than opening the main converter for every job.

The separate preferences window has General, Formats, Compatibility and About tabs, including size/preview and login controls. Formats edits shared session defaults. Reference per-format policies, folder policies, Float target selection and Terminal application selection remain incomplete. The native form styling and Orange artwork are original; exact visual matching is unverified.

`bash scripts/build.sh` builds a host-architecture release bundle at `build/Orange.app`, generates original artwork, and signs locally. `open build/Orange.app` launches it. `bash scripts/test.sh` runs core tests. Scripts keep caches in `.cache/` and `.build/`. They do not produce a notarized universal release or establish a passing test result merely by existing.

Orange source and original assets use [MIT](../LICENSE). Apple frameworks remain platform dependencies. No Tangerine source, artwork or sound is included. FFmpeg retains LGPL terms; libwebp retains its BSD license and patent notice. Packaging copies the complete app and verifies matching FFmpeg source/licenses/hash. When the FFmpeg configuration enables libwebp, it also requires libwebp source, COPYING/PATENTS/AUTHORS, configuration, URL and verified source checksum. Packaging does not silently notarize the result.

## Acceptance still required

Authorized read-only inspection on 21 October 2026 identified native Tangerine 2.0.2 and its General/Formats controls. A later user screenshot established a seven-option reference image wheel during a real held drag; its 504-pixel circle compared with the old Orange circle's 772 pixels at the stated 2× scale. The 252-point reference diameter is an inference. Automation recovered after the earlier connection failures. Remaining tabs, complete drag/drop/action flows and exact tool behavior still need evidence.

The 0.1.3 suite passed **111 tests, zero failures and zero skips**, on **22 October 2026**: 69 core tests and 42 app tests, without compiler warnings. Eighteen controller regressions cover activation and lifecycle boundaries that the earlier suite missed. Native OCR/PDF/media, audio preparation, output safety and cancellation coverage passed. These results do not establish reliable Finder routing or visual parity by themselves. Current evidence is recorded in [0.1.3 verification](verification-0.1.3.md). Still required: complete Finder end-to-end tests, fresh installation/login approval, macOS 13 runtime validation, remaining reference behavior, broad color/metadata qualification and matched-output performance measurements. Missing implementations include per-format/folder policies, editable-office PDF conversion, general page editing, additional image/audio/video tools, archive extraction, durable recovery and precise progress. See the [parity contract](reference-parity.md).
