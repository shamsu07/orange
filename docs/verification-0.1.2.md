# Orange 0.1.2 verification

Historical release report. The user subsequently confirmed held-drag tones but reported intermittent first-drag activation after file/app changes. The native-session replacement and its acceptance status are recorded in [0.1.3 verification](verification-0.1.3.md).

Date: 22 October 2026. Host: Apple silicon, macOS 27.0.1. Deployment target: macOS 13; runtime behavior there remains unverified.

## Changes

The [0.1.1 corrections](verification-0.1.1.md) remove hover haptics and moving targets, add release-then-click confirmation, make optional login registration nonblocking, retain native sharing sessions, and replace the spoke icon with original segmented orange artwork. This release includes those changes and fixes found during unlocked-Mac verification:

- Preview clicks no longer dismiss the wheel because an event lacks a window identity; outside dismissal uses screen coordinates and applies to a real picker.
- Reopening the same file selection restores interaction after dismissal. An unchanged capability refresh preserves the selected page.
- Closing a preview resets its controller so it cannot suppress later Finder drags.
- Each file capture requires a stable drag-pasteboard update after the current mouse down. Drag and modifier events can retry an incomplete read. Previously captured files cannot supply a new drag.
- A native drop with missing or different URLs cancels the picker. A later drop cannot replace the selection after release.
- The main File menu exposes Open Orange and Choose Files with their keyboard shortcuts.
- Following the user's live feedback, selection tones also play during the held drag. The previous explicit drag-phase suppression is removed. Two short precomputed buffers use an output-only audio engine prepared before hover; dismissal stops/releases the engine. The 45 ms gate limits jitter without queuing delayed feedback. No microphone or audio-input node is used.

## Automated checks

**91 tests passed, zero failures and zero skips: 67 core tests and 24 app tests.** The run used the local source-built FFmpeg/libwebp backend and normal macOS Vision, media, audio, clipboard and window services.

The suite covers actual image rotation, resize, recompression and metadata-removal outputs, preserved originals, native OCR/PDF/media operations, safe publication, cancellation, all three wheel confirmation modes, fixed hover geometry, repeat selection, preview closing, page preservation, fresh drag capture and mismatched-drop cancellation. The held-drag view regression verifies changed-target feedback with Shift held, silence within the same target or empty center, no operation on hover/release, and deliberate click confirmation. Audio tests cover native output preparation without playing, reused preparation, timing without queued sounds, dismissal cleanup and unavailable-output recovery. Clipboard tests use a private pasteboard. AirDrop tests inject a sharing session, and login tests inject the OS service; those tests neither transmit files nor change real login settings.

The final run and release-build logs are repository-local generated artifacts:

- `.cache/tests-0.1.2-feedback.log`
- `.cache/build-0.1.2-feedback.log`
- `.cache/package-0.1.2-feedback.log`

## Native UI checks

After the user unlocked the Mac, computer-use checks against the correction-series development app observed:

- A click on WEBP kept the preview open, updated its center label and left target sizes fixed.
- A PNG selected from `build/verification/sample.png` completed Rotate 90° through the main window. Activity reported success and Finder revealed `sample-rotated.png` beside the preserved original.
- AirDrop opened the actual macOS chooser for the fixture. It reported no nearby people. The chooser was cancelled without sending a file.
- Float opened a file shelf containing `sample.png`.
- The redesigned icon appeared in the native UI and AirDrop chooser.
- The final build launched quietly after completed setup; reopening it displayed Settings with the 252-point default, 220-point minimum and Shift/Command/Control bindings.
- The user-assisted Finder Shift check confirmed that the wheel stays open after releasing both mouse and modifier. Live activity also showed a completed WebP job, and FFprobe verified `build/verification/sample.webp` as a valid 256 × 256 WebP. The original fixture still matches the generated source image byte-for-byte.
- The user heard selection sound after release but reported silence while holding the initial gesture. That report led to the held-drag audio correction above. The final native preview also presented and changed selection successfully with the prepared audio path enabled.

These checks establish the main-window dispatch path, preview and one user-assisted Shift-release case. They do not establish all Finder modes, cancellation sequences, repeated native drags or perceived audio latency.

## Packaged artifacts

Release build, strict deep signature checks, ZIP/DMG integrity, SHA-256 checks and bundled backend/source checks passed. The DMG was mounted read-only inside `.cache/`; its app executable and icon matched the tested build byte-for-byte, its Applications shortcut was verified, and the mount was detached. The extracted ZIP app also passed signature and executable/icon comparisons. The mounted app's command-line self-check reported version 0.1.2 with FFmpeg and FFprobe available.

| Artifact | SHA-256 |
| --- | --- |
| `Orange-0.1.2-macos-arm64.dmg` | `f789c5c8113ce8c3a26db72ed4a1f7570054e98707d32f8f260249019ee512ef` |
| `Orange-0.1.2-macos-arm64.zip` | `bbceb5bb5932bca1e92f0b66f5f7f3352adf2ada2421d6f4fde9f59632bc1ba0` |

Signing is ad hoc. No Developer ID signing, notarization, publication or Gatekeeper installation acceptance is claimed. Previous release archives remain in `dist/`.

## Remaining acceptance

Complete Finder modifier timing, installed login registration/approval/reboot, device-to-device AirDrop transfer, multiple displays, Gatekeeper installation, macOS 13 runtime, full reference parity and matched-output performance remain unverified. Subjective smoothness and output latency of the final audio change are not established by the automated checks. The fresh-capture guard intentionally declines a gesture when it cannot establish a new drag payload rather than using old file URLs.

To update, quit the installed Orange, replace it with the app from the 0.1.2 disk image and open it from Applications. Existing completed setup remains completed. If launch at login was disabled during the earlier setup, retry it in General settings. For the wheel, drag a file, tap a modifier, release over the wheel, then click an option. Run one converter's drag wheel at a time.
