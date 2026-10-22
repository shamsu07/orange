# Tangerine reference and Orange parity contract

Reference checked: **21 October 2026**. This document distinguishes public marketing/demo evidence, limited authorized native inspection, and Orange implementation. None establishes complete 1:1 parity.

## Evidence and limitations

| Source | Evidence used | Limitation |
| --- | --- | --- |
| [Mac App Store](https://apps.apple.com/in/app/tangerine-file-converter/id6813034065?mt=12) | Listing, version history, platform requirements | Listing prose conflicts with newer website controls |
| [Product website](https://tangerineformac.com/) | Format summary and interactive category menus | The website explicitly describes its operations as simulated |
| [File tools](https://tangerineformac.com/tools) | Tool names and public window descriptions | Not a complete native-app specification |
| [Press kit](https://tangerineformac.com/press) | Workflow and product screenshots | Its version field says 1.4; App Store reports 2.0.1 |
| Installed native `Tangerine.app`: read-only bundle metadata and General/Formats windows | `Info.plist` identified version **2.0.2**; visible native settings recorded below | Controls were observed, not their output semantics; remaining tabs are not fully inspected |
| User-provided native held-drag screenshot | Seven-option reference image wheel, ordering and pixel geometry, alongside the older Orange wheel | One real held-drag state, not a complete drop/conversion test; point size is inferred from stated display scale |
| Orange native onboarding, Settings and preview inspection | Setup UI, 252-point size control, seven labels; Right Arrow changed selection to WEBP with center-pill and highlighted/scaled wedge updates | Limited Orange preview validation; no completed Finder drag, output conversion, audible sound check or login registration |

The website advertises **275 conversion paths, 26 tools, and 6 actions**. The full directed graph of 275 paths is not published. Do not manufacture it by taking the Cartesian product of format names. Container support also does not establish every codec, profile, bit depth, animation, metadata, or malformed-input case.

## Native settings observed

The following observations came from the installed native **2.0.2** application on 21 October 2026, rather than the simulated website. Reading its bundle metadata and settings windows did not change the reference application's files.

| Native surface | Visible evidence | What remains unknown |
| --- | --- | --- |
| General appearance | Glass/Solid segmented choice; dark native grouped form layout | Exact rendering, blur, dimensions, spacing and behavior in other appearance modes |
| General behavior | Launch at login and feedback checkbox | Login registration and actual feedback behavior |
| Drag shortcuts | Configurable modifiers showing Shift for conversion, Command for tools and Control for actions | Complete reference modifier inventory, collision handling and real drag activation/release behavior |
| Float | A `Create New Float` choice | Shelf reuse, lifetime and destination behavior |
| Terminal | Application chooser | Supported applications and opening behavior |
| Formats | Per-format side list; visible quality `Balanced`, `Preserve metadata`, compression `Balanced`/`Strong`, and `Keep original dimensions` controls | Whether each control applies to every format, exact parameter values, persistence and output semantics |

Native automation initially failed with pipe-connection errors, then recovered after reset. Those errors are historical, not a current inspection blocker. Neither application has been benchmarked against the other; complete native tool/output and Orange end-to-end acceptance remain outstanding.

## Native wheel evidence

A user-provided screenshot captured the reference wheel during a real held file drag, rather than a website simulation. The observed PNG conversion wheel has seven labels: **JPG at the top, then clockwise WebP, HEIC, TIFF, AVIF, BMP and PDF**, omitting PNG itself. Rounded annular segments, a transparent center and a small central label pill are visible.

The reference circle spans approximately **504 pixels**, compared with **772 pixels** for the older Orange circle in the same reported 2× capture. Dividing by that scale gives **252 points** for the reference and 386 points for the old Orange wheel. This is a screenshot-derived estimate, not a verified numeric Tangerine preference or API value. Exact shadows, colors, segment radii, animation curves, sound, hit regions and other display scales remain unqualified. One held-drag image does not establish key-release or completed-drop behavior.

## Orange 0.1.1 corrections

User testing of 0.1.0 reported click-like haptics, disappearing menus, blocked setup and nonworking actions. Version 0.1.1 deliberately changes Orange's confirmation workflow: drag, tap the modifier, release over the wheel, then click. It removes hover haptics and target scaling, keeps the picker open after release, makes login setup nonblocking, and retains AirDrop presentation and errors. These are usability fixes; they are not claimed to match an unobserved reference confirmation policy. The updated suite passed 77 tests (62 core, 15 app) on 22 October 2026, including view dispatch and real image-tool jobs. Real device transfer, installed login/reboot, and full Finder acceptance still need evidence.

## Orange 0.1.2 follow-up

The unlocked-Mac follow-up completed a local image rotation through Orange's main window, opened and cancelled the system AirDrop chooser without sending, opened a floating file shelf, and verified fixed-target WEBP preview selection. The user confirmed that the Shift wheel stays open after releasing the mouse and modifier; a valid 256 × 256 WebP output was also observed in this session. The user then reported sound suppression during the held gesture. Version 0.1.2 enables held-drag feedback and prepares output audio before hover. It also fixes repeated-selection and preview-close lifecycle errors, rejects stale drag payloads, and cancels mismatched native drops. Its suite passed **91 tests, zero failures and zero skips** (67 core and 24 app). These results do not establish perceived audio latency, complete Finder acceptance, device transfer, real login/reboot or reference parity. See [0.1.2 verification](verification-0.1.2.md).

## Orange 0.1.3 activation correction

The user confirmed 0.1.2 held-drag tones but reported that first activation could fail when switching files or returning to Finder. Version 0.1.3 removes the named-pasteboard freshness gate and binds files from the actual native destination's pasteboard and sequence. Gesture identities protect deferred callbacks, event snapshots avoid mixing old events with current pointer state, and deactivation/missing-release recovery clears obsolete overlays. The suite passed **111 tests** (69 core and 42 app), including 18 controller regressions, without failures, skips or compiler warnings. **Native acceptance failed:** the user still reported at least one first-attempt failure. A subsequent diagnostic attempt worked and did not establish the cause. The intermittent activation issue remains unresolved; see [0.1.3 verification](verification-0.1.3.md).

## Orange settings and interaction status (0.1.0 observations)

Orange has separate **General, Formats, Compatibility and About** preferences, with persisted Glass/Solid appearance, diameter, feedback, Finder-wheel enablement, Finder reveal and three configurable shortcuts. Each shortcut offers eight combinations: Shift, Command, Control, Option, Option + Shift, Command + Shift, Control + Shift, and Option + Command. Conversion quality, metadata removal, image size, trim range and speed remain shared session defaults rather than native per-format policies.

The rewritten wheel defaults to **252 points**, with Orange-defined bounds of **220...560 points**, rounded annular sectors, transparent center and a central pill. Image options follow the observed clockwise order and omit a shared source format, filtering real capabilities. Up to eight choices fit a page; retapping its active shortcut cycles pages. Glass/Solid backgrounds, original alternating synthesized selection feedback and spring selection with Reduce Motion support are implemented. Paging, limits, audio and animation are not verified reference behavior, and exact visuals remain unproven.

The current Orange native UI was inspected: onboarding, Settings showing 252 points, and the seven-label preview were visible. Right Arrow selected WEBP and updated the central label plus orange/scaled wedge. The wheel's JPEG route now displays JPG while manual operation labels remain JPEG. Preview selection alone does not establish conversion. Separately, four targeted WebP tests and two real media tests passed against the updated FFmpeg/libwebp backend, followed by the full **54-test run with zero failures and zero skips on 22 October 2026 at 00:01 GST**. Broad WebP/color/native parity remains unqualified. Playback was requested without an audible sound check. First-launch setup and actual login registration were left for the user rather than performed on the development account.

First-launch onboarding now connects an explicit **Enable Orange** action to wheel activation and optional `SMAppService` launch-at-login registration, including pending-approval handling. Later background launches remain in the menu bar; jobs use a small activity panel. Login/setup integration is implemented, but fresh-install, approval, login and Finder end-to-end behavior are not yet accepted. Folder policies, per-format conversion policies, Float target selection, Terminal application selection and full native tool parity remain incomplete. Orange omits an unimplemented Folders tab rather than presenting inert controls.

## Observed workflow

The [press kit](https://tangerineformac.com/press) describes a radial menu at the dragged file, contextual formats/tools, a menu that remains after releasing the activation key, local processing, and new converted/edited copies beside the input. It also identifies folder and mixed-selection support for actions.

The [App Store listing](https://apps.apple.com/in/app/tangerine-file-converter/id6813034065?mt=12) describes a menu-bar resident app, compatible multi-file jobs, a small progress window per job, and Finder reveal after completion. Its platform floor is Apple silicon and macOS 13. The trial allowance and purchase system are reference commercial behavior; Orange does not need a paywall to reproduce conversion workflows.

| Interaction | Current website / press kit | App Store description | Orange decision |
| --- | --- | --- | --- |
| Conversion wheel | Tap Shift during drag | Hold Shift during drag | Configurable binding implemented; default Shift observed in native General; complete activation/release/drop sequence unverified |
| Tool wheel | Tap Command during drag | Hold Option + Shift | Configurable binding implemented; default Command observed in native General; complete activation/release/drop sequence unverified |
| Action wheel | Tap Control during drag | Added in 2.0 release notes | Configurable binding implemented; default Control observed in native General; complete activation/release/drop sequence unverified |
| Key release | Wheel persists until drop/cancel | Not specified | Keep activation separate from modifier-held state |

The [website demo](https://tangerineformac.com/) additionally exposes keyboard navigation and configurable keys. Native General settings separately establish visible modifier pickers; neither observation proves native global keyboard behavior during an actual drag.

## Public format matrix

**U = Orange/native parity unverified.** Named sets below reproduce public labels, not an assertion of bidirectional support. An arrow means the website explicitly describes the route or shows that representative input's outputs. Every unlisted directed pair remains unknown. JPG/JPEG and MD/Markdown are label aliases, not extra paths.

Source for every row: [supported formats and category demos](https://tangerineformac.com/).

| Family / representative input | Public formats or explicit output routes | Status |
| --- | --- | --- |
| Images | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP; SVG input only; PDF export | U |
| JPG demo | → PNG, WebP, HEIC, TIFF, AVIF, BMP, PDF | U |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA | U |
| MP3 demo | → M4A, WAV, FLAC, OGG, Opus, AIFF, WMA | U |
| Video | MP4, MOV, MKV, WebM, AVI, WMV, GIF; MP3 export | U |
| MOV demo | → MP4, MKV, WebM, AVI, WMV, GIF, MP3 | U |
| PDF | → DOCX, PAGES, PPTX, XLSX, JPG, PNG, EPUB, TXT, MD | U |
| DOCX demo | → PAGES, PDF, TXT, MD, HTML, EPUB, PNG, JPG | U |
| Documents, additional inputs | Markdown, TXT, EPUB; RTF, RTFD, text clippings input | U |
| Slides | PPT/PPTX → PDF, JPG, PNG; PPT input only | U |
| Spreadsheets | XLSX, ODS, CSV, TSV; PDF export; XLS input only | U |
| EPUB demo | → PDF, DOCX, PAGES, TXT, MD, HTML | U |
| Subtitles | SRT ↔ VTT; TXT export | U |
| Archives | ZIP, TAR, GZIP; RAR input only | U |

PDF image export specifies every page at 300 DPI. The website also describes local OCR for scanned PDF text exports; document-layout preservation must be measured independently.

Orange's PDF page PNG/JPEG export now defaults to 300 DPI independently of image resizing, subject to a separate 10,000-pixel long-edge ceiling and a 40-megapixel rejection limit. Its A4 regression fixture expects approximately 2,481 × 3,508 pixels; these safety bounds can reduce or reject unusually large page rasters and are not a verified reference behavior.

Orange now implements TXT/MD export with page-level local OCR fallback when a page has no nonblank text layer. It rasterizes at up to 150 DPI/2,400 pixels on the long edge, uses accurate Vision recognition with the shared acceleration/CPU fallback, and preserves page order. This is an implemented subset, not measured OCR parity: language coverage, degraded scans and recognition accuracy remain unqualified. Searchable-PDF generation, layout reconstruction and editable Office output from PDFs remain unavailable.

The older App Store format summary names SVG and GIF among images without specifying their directions and omits several newer formats. Use the explicit website direction restrictions when planning, and keep SVG export / animated GIF-image conversion unsupported until independently established.

## Public tools and actions

These are **requirements awaiting parity evidence**, not implemented-feature claims.

| Family | Detailed public tools |
| --- | --- |
| Shared | Compress; edit metadata |
| Images | Edit; annotate; background; crop; redact; collage |
| Video | Trim; crop; speed; join; frames; split; redact |
| Audio | Normalize; visualizer; trim; channels; bleep |
| PDF | Merge; organize |

The [tool page](https://tangerineformac.com/tools) documents these 22 windows. Observable option boundaries include target-size/percentage compression; image pixel dimensions; blur/solid redaction; frame/timecode trimming; pitch-preserving speed; mixed-video joins to MP4; PNG snapshots; loudness/true-peak normalization; mono/stereo channel controls; and page rotation, duplication, removal, and reordering. Defaults, ranges, precision, preview rendering, and failure behavior remain unverified.

Additional [homepage demos](https://tangerineformac.com/) show image selection → PDF, video muting, and PDF splitting. QR reading appears in the [App Store listing](https://apps.apple.com/in/app/tangerine-file-converter/id6813034065?mt=12). Together these names reach the advertised count of 26, but that arithmetic does not prove the native app uses this exact inventory.

The [press kit](https://tangerineformac.com/press) names six actions: **AirDrop, Float, Copy, Move, Copy Path, Terminal**. The website describes a floating shelf, destination-based moving, line-separated paths, and Terminal/iTerm2 opening. Their native edge cases remain unverified. Move is the one advertised operation that changes the original file location; it must not inherit the copy-producing conversion contract.

## Missing evidence needed for an exact replica

- Native reference captures: the held-drag image establishes one seven-label image-wheel order and approximate pixel size. Exact typography, colors, shadows, hit regions, animation, hover timing, display edges, other scales and light/dark behavior still require evidence; 252 points remains an inference.
- Native workflows: onboarding, remaining settings tabs, per-format policy behavior, launch at login, folder policies, permissions, unavailable formats, mixed inputs, folder recursion, name collisions, cancelled drags, destination failures, progress, cancellation, and recovery.
- Orange acceptance: completed Finder drags, configurable shortcuts, paging, appearance/feedback, fresh setup, login approval, preference persistence and complete native UI flow still require end-to-end verification; macOS 13 runtime validation remains outstanding. The source suite has 54 passes/zero failures/zero skips, including nine geometry and four WebP tests; this does not establish GUI installation, login or full native parity.
- Conversion semantics: complete directed route graph; codec defaults; image orientation/color/alpha; document fonts/layout/tables; PDF OCR languages; archives, symlinks and permissions; metadata preservation/removal.
- Action semantics: float lifetime, clipboard representation, multi-item move conflicts, AirDrop errors, Terminal quoting and folder selection.
- Performance: reference hardware, fixtures, cold/warm timings, peak memory, energy use, idle behavior, and equal-output-quality comparisons.

No statement of “exact 1:1 parity” is justified until these gaps have evidence.

## Phased acceptance

| Phase | Deliverable | Required evidence before claiming completion |
| --- | --- | --- |
| 0 — Evidence | Versioned reference corpus | Native screenshots/recordings, input/output fixtures, and a directed capability manifest with unknowns retained |
| 1 — Interaction | Menu-bar app, contextual wheels, drop lifecycle, local job UI | Finder-originated drags; key down/up; Escape; batching; multi-display edges; permission-denied behavior; no source modification |
| 2 — Conversion core | Verified image, PDF-page, audio/video, subtitle and archive routes | Each enabled route round-trips or passes output validation; cancellation, collisions, unsupported codec, bad input and partial-batch failures are tested |
| 3 — Editing/actions | Every established tool and action | Reference-matched defaults and controls; output semantics; accurate progress; destructive move behavior explicitly separated |
| 4 — Office/OCR | Document, presentation, spreadsheet and EPUB routes | Layout/table/formula fidelity corpus, local OCR accuracy, fonts, multipage behavior, deterministic dependency availability |
| 5 — Parity/performance | Visual and behavioral parity report | Fixed reference version; measured differences; matched-quality benchmarks; peak memory, idle cost, startup and cancellation measurements; no silent unsupported features |

Until a route/tool passes its gate, show it as **unsupported**, **unavailable on this system**, or **experimental**. Never present a placeholder menu option as a working conversion.

## Architectural consequences for Orange

These are implementation recommendations derived from the scope above:

1. Store capabilities as directed routes with explicit input conditions, output semantics, availability checks, and a provider. Menus must derive from this registry, never extension substitution.
2. Keep drag/overlay work on the UI thread short. Run conversion, probing and previews off that thread, with bounded concurrency and cancellable jobs. Measure latency before selecting optimization targets.
3. Separate native macOS integration from conversion engines. Finder drags, global modifier observation, overlay routing, clipboard, AirDrop, shelf and Terminal behavior require native acceptance tests; a web simulation cannot establish them.
4. Use source-preserving, atomic output writes with collision handling, explicit temporary-file ownership, and cleanup after cancellation. Treat a multi-file job as a set of outcomes, not a single success boolean.
5. Probe actual decoder/encoder capabilities. HEIC/AVIF, WMV/WMA, legacy Office, Pages, OCR and RAR are separate engineering constraints; a format label is not a working engine.
6. Track tool/provider licenses and redistribution conditions independently. An open-source application can call proprietary OS APIs, but that does not make those APIs or installed external applications open source. Avoid making paid Office/iWork installation an undocumented prerequisite.
7. Define performance with fixtures and output-quality constraints. Faster output with lost pages, damaged color, dropped audio, erased formulas or weaker compression is a regression, not optimization.

