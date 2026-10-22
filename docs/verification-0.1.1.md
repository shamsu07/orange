# Orange 0.1.1 corrections and verification

Historical release report. See [0.1.2 verification](verification-0.1.2.md) for the unlocked-Mac follow-up and additional fixes.

Date: 22 October 2026. Host: Apple silicon, macOS 27.0.1. Deployment target: macOS 13, not runtime-tested there.

## Reported issues and changes

1. Hover felt like a trackpad click and targets moved: removed alignment haptics and spring scaling. Selection now changes color with fixed drawing and hit geometry; optional original selection sounds are softer and rate-limited.
2. Setup displayed “Open the installed Orange.app…” with login enabled: this text came from Orange's incorrect `.notFound` precheck. That status now attempts registration. Optional registration failure or pending approval cannot block Enable Orange. Settings retains actual OS state, retry, an approval link and local error diagnostics.
3. Releasing the mouse closed the menu: a drag now captures the selection, and release keeps the picker open. A fresh mouse-down/up on the same option is required to execute it. Hover and the original drag release never execute anything. Return/Space or accessibility activation can also explicitly confirm after release. Escape and outside clicks dismiss.
4. Tools/actions appeared to do nothing: all wheel modes now use the same explicit commit path, deferred outside the drag callback. Real image-tool jobs and Control action dispatch have integration tests. AirDrop sessions retain the sharing service and source window through completion/failure; clipboard operations show feedback and Terminal/sharing errors are surfaced.
5. Icon looked like a circle with spokes: replaced it with original seven-segment orange wheel artwork and a center pill. App UI, generated ICNS and menu-bar template share the same drawing source in `Sources/OrangeArtwork/OrangeIcon.swift`.

## Verified

- **77 tests passed, zero failures and zero skips:** 62 core and 15 application tests. The suite used the bundled-source FFmpeg/libwebp and normal macOS Vision, media, clipboard and window services.
- Eight pure interaction tests cover drag release, explicit single confirmation, mismatched click positions, cancellation, gaps, keyboard confirmation and preview isolation.
- Native view tests confirm that drag release never invokes an operation, a fresh click dispatches each of Convert/Tools/Actions, and hovering never changes segment frames/transforms or invokes an operation.
- Application tests produce real rotate, resize, recompression and metadata-removal outputs, preserve the original JPEG, and verify clipboard/Float routing. Clipboard tests use a private pasteboard. AirDrop tests use an injected session and do not transmit files. Login tests use an injected OS service and do not change real login settings.
- Release build and strict deep code-signature verification passed. App version reports 0.1.1. Bundled-backend self-check finds both FFmpeg and FFprobe. Signing is ad hoc; no notarization or publication occurred.
- DMG/ZIP integrity and SHA-256 checks passed. Read-only DMG verification compared the app executable and redesigned icon byte-for-byte with the build, verified the app signature and Applications shortcut, and detached its repository-local mount.
- Generated 1024-pixel icon was visually inspected.

| Artifact | SHA-256 |
| --- | --- |
| `Orange-0.1.1-macos-arm64.dmg` | `a7c8173aa27de1cde2b13b41e8b8ba03926e25a9a4351b4ede346f1b3d3b15c1` |
| `Orange-0.1.1-macos-arm64.zip` | `c8ce28854b6019a15cc4319718abea51301a643fea38a0c51c50412ff6cc0653` |

## Remaining checks

The Mac was locked when computer-use verification attempted to open the updated app. The final live Finder drag/modifier/click and system AirDrop dialog checks could not be completed in this session. Device-to-device transfer, installed login approval/reboot, Gatekeeper installation, multiple displays, full reference parity and macOS 13 runtime remain unverified. The earlier restricted test attempt could not access native Vision/media/clipboard services; the successful normal-service run is the result reported above. A test-only window ownership crash was corrected before that passing run.

To update, quit the existing Orange, replace it from the 0.1.1 disk image and open it from Applications. Existing completed setup remains completed. Retry launch at login in General settings if the old setup choice was disabled. For the new wheel flow, release the mouse over the wheel before clicking an option. Run only one converter's drag wheel at a time.
