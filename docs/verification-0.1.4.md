# Orange 0.1.4 verification

Date: 23 October 2026. Local Apple silicon release, Swift 6 compiler in Swift 5 language mode, macOS 27.0.1 host. This report distinguishes source tests, native checks and outstanding acceptance; it does not certify exact Tangerine parity, battery life or absence of vulnerabilities.

## Automated checks

- `PATH="$PWD/.cache/tools/bin:$PATH" bash scripts/test.sh`: **198 tests passed, zero failures, zero skips**, comprising 108 core and 90 app tests. No compiler warnings. Log: `.cache/tests-0.1.4-final.log`.
- A final text-wrapping/spacing adjustment in the PDF reduction view followed that full run. The focused `--filter PDFOptionsTests` run then passed all 8 tests, and the final release rebuilt successfully without compiler warnings. Log: `.cache/tests-pdf-final-layout.log`.
- Coverage includes real image dimensions/crop orientation/encoding savings, explicit PDF partitions and fidelity consent, selected snapshot time, all eight speed presets on a 1 fps source, audio/video timing, archives from different folders, collision handling, shutdown joining of retired encoders, cancellation/permit reuse, stale choice rejection and opaque appearance fallback.
- DOCX-specific coverage: 10 tests, including native export → guarded import, streaming payloads, false expanded sizes, CRC/header/descriptor mismatch, unsafe names, encryption/symlinks, external resources, XML declarations/entities and nonstandard XML part extensions.
- Injected Finder/controller tests verify state transitions and primary-window hiding. They do not prove actual first-attempt Finder event delivery, sound latency or haptic feel.

## Native application checks

Only generated files under `build/verification/` were used. App actions saved new outputs; original fixtures were retained.

| Check | Observed result |
| --- | --- |
| Glass/Solid | Distinct native preview surfaces; Solid center and sectors are opaque. Changing appearance while Settings was key left Settings in focus. Automated tests additionally cover both light/dark colors, Reduce Transparency fallback and page/keyboard selection preservation |
| PDF Split | Visible split-after-page field, stepper, custom-range disclosure and part cards. Changed a four-page source from the default cut at 2 to a cut at 1; saved 1-page + 3-page outputs in order, with 480 × 300 pt geometry and text retained |
| PDF reduction | Balanced preview: 508 KB → 265 KB, save disabled until consent. Saved 508,420 → 265,378 bytes, two pages with original geometry; output has raster content rather than the original text layer. Final UI check confirmed the entire fidelity warning wraps visibly |
| Video speed | Selected 2× for a four-second 1 fps clip. Saved `workflow-video-speed 1.mp4`: 2.000 seconds, four frames, 2 fps, 320 × 180 px. The earlier incorrect four-second output remains as diagnostic evidence |
| Details | Native retained panel showed exact bytes, path/type/dates/permissions, duration, dimensions, frame rate and codec; readable scrolling and explicit copy/close controls |
| Earlier same-feature image checks | Resize 512 × 320 → 256 × 160 px (673,449 → 33,424 bytes); JPEG compression kept 512 × 320 px (173,531 bytes); square crop saved 288 × 288 px. Estimates and final dimensions were checked |
| Earlier media timeline checks | Chose the blue frame at 1 second rather than the initial frame; saved 320 × 180 PNG. Trim 1–3 seconds saved a 2.000-second clip |

The user subsequently confirmed that Shift, Command and Control all opened on the first attempt in the final 0.1.4 build. This is a passing native check, not a repeated long-run reliability result. The user felt the alignment haptic as a click and requested keeping it if no distinct vibration option exists. [Apple’s documented trackpad patterns](https://developer.apple.com/design/human-interface-guidelines/playing-haptics) are alignment, level change and generic; the [AppKit performer API](https://developer.apple.com/documentation/appkit/nshapticfeedbackperformer) exposes pattern and timing, not a vibration waveform/intensity setting. The current feedback and toggle were retained.

Native PDF output inspection is recorded in `.cache/native-validation-0.1.4.txt`; FFprobe independently confirmed the corrected speed duration/frame count. Native checks of earlier image/timeline behavior preceded the final shared worker/lifecycle and file-organization changes; their core integration regressions passed afterward. The final PDF text layout was rechecked in the rebuilt bundle.

Terminal's existing behavior is intentional: a selected folder opens itself; a selected file opens its containing folder. User observation and dispatch tests support that route. No Terminal command or AirDrop transfer was sent during these checks. Create ZIP has real archive-content integration tests; the multiple-selection Control-wheel path has not been accepted through a real held Finder drag.

## Idle and resource evidence

The final release was left in the menu bar with all Orange windows/wheels closed, Finder monitoring enabled, no queued jobs, and sounds/haptics enabled. The 30-second `ps` sample is stored in [idle measurements](benchmarks/2026-10-23-arm64-idle.json). CPU time is quantized to 0.01 second; RSS is not physical footprint. The sample follows native PDF/media use.

Observed CPU time stayed at 1.71 seconds across 30.012 seconds: no measurable increase at 0.01-second resolution. RSS stayed at 158,662,656 bytes (151.3 MiB), and no child processes remained. This is one sample, not a zero-cost guarantee.

The architecture has no recurring idle polling timer. Global pointer recovery and keyboard monitoring exist only during their wheel lifecycle. Dismissal stops the audio engine; media observers run during playback and are removed on pause/close. Expensive option preparation and encoding previews share two permits with saved jobs; capabilities and AVPlayer have separate lifecycles. These controls and a short sample do not establish all-day energy usage, wakeup rate or peak memory behavior.

A prior synthetic 4K diagnostic reached roughly 1.15 GB peak RSS; charged physical footprint was much lower and is a different measurement. No matched-quality Tangerine comparison or long-duration memory/battery qualification has been completed.

## Security scope

The reviewed boundaries include shell-free child execution, bounded diagnostic capture, process cancellation/timeouts, local FFmpeg protocol/container allowlists, exclusive atomic output publication, archive creation without extraction, overlapping archive rejection and DOCX package validation. DOCX limits are 128 MiB actual total expansion, 16 MiB per XML part, 10,000 entries and 8 MiB central directory; no data is extracted to disk by that guard.

This is targeted hardening, not a comprehensive independent security audit. Native AppKit/PDFKit/ImageIO/FFmpeg parser vulnerabilities, legacy DOC/RTF embedded-resource behavior, broad fuzzing and concurrent source replacement between DOCX validation/import remain outside the established evidence. Ordinary external hyperlinks are retained in DOCX; non-hyperlink external embedded resources are rejected. Never interpret passing tests as a guarantee of no security issues.

## Packaging and acceptance

The release was built with `bash scripts/build.sh`; packaging uses `bash scripts/package.sh --no-build` so the tested app is not silently rebuilt. Previous versioned DMG/ZIP files and the 0.1.3 checksums are preserved. Packaging and verification passed. DMG and ZIP integrity/checksums passed, and complete bundle comparisons matched `build/Orange.app` in both the extracted ZIP and read-only mounted DMG. Both signatures verified. The mounted app self-check matched the build’s result with FFmpeg/ffprobe available; bundled FFmpeg/libwebp source hashes verified. The Applications shortcut was present. The image was detached and temporary verification copies removed. Logs: `.cache/package-0.1.4.log` and `.cache/package-verification-0.1.4.log`.

| Artifact | SHA-256 |
| --- | --- |
| `Orange-0.1.4-macos-arm64.dmg` | `994cdc957fa6fffe2c82db667c5be19e84c2cb7ddd0337bcc3069b45029f24dd` |
| `Orange-0.1.4-macos-arm64.zip` | `bd7059b4499a8b511fd04657ab6f1bd130648e8ee67c41a44aadcc1eea61ffec` |
| Executable in build, ZIP and DMG | `bee96e1ca8c1ca1da12ed748061a0e88157e5c7807cba95e29971bc41975cc4e` |

Outstanding native acceptance:

- The latest user check passed all three first attempts. The earlier intermittent failure was not captured or causally diagnosed; repeated app/file-switch reliability is not established by one passing check.
- Primary-window focus after release and perceived sound latency still need explicit final acceptance. Physical haptic output was confirmed, but the requested vibration sensation is not supplied by the documented trackpad patterns. No keyboard/mouse hold is simulated by the automation.
- Fresh Applications installation, macOS Login Items approval/reboot, multiple displays/edge placement, macOS 13 runtime, complete reference tools and variable-frame-rate cadence remain unqualified.
- App is ad hoc signed; no Developer ID/notarization, public upload or push was performed.
