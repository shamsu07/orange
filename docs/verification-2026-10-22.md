# Orange 0.1.0 local build verification

Verified on 22 October 2026, Apple silicon, macOS 27.0.1. macOS 13 remains the deployment target; its runtime has not been tested.

- Full source suite: **54 passed, zero failures, zero skips**. Includes real FFmpeg audio/video, native OCR/PDF, WebP alpha and quality, literal percent-pattern paths, cancellation, output collision protection and wheel geometry.
- Release `Orange.app`: compilation and strict deep signature verification passed. Signing is ad hoc, not Developer ID signing or notarization.
- DMG and ZIP: integrity checks and SHA-256 verification passed. Read-only DMG mount stayed inside the repository and was detached after verification. The Applications shortcut points to `/Applications`.
- Packaged executable matches the build executable byte for byte. Packaged self-check finds FFmpeg and FFprobe; packaged FFmpeg lists the `libwebp` encoder. Bundled FFmpeg/libwebp source archive hashes, configuration and license/patent materials were verified.
- Native UI: first-launch setup and Settings rendered; size control stopped at 220 pt after repeated decrements, and Reset restored 252 pt. Seven preview items appeared in the observed reference order. Right Arrow selected WEBP; the TIFF accessibility action selected and highlighted TIFF and updated the center pill. Escape dismissed the preview. Development app was closed after checks; login registration and setup completion were left to the user.

| Artifact | SHA-256 |
| --- | --- |
| `Orange-0.1.0-macos-arm64.dmg` | `8537746529d686d8f7d07c4f746a6409b0159120c510342c657d06778dc36682` |
| `Orange-0.1.0-macos-arm64.zip` | `6cfd3d1f23f636940d8c462c505670050afc116c79a8991c82b2704c03dfd803` |

Still unverified: fresh GUI installation and Gatekeeper flow, login approval/reboot, new-renderer Finder drop/cancel lifecycle, audible feedback, multi-display behavior, broad format/color fidelity, exact reference parity and comparative performance. CI configuration is present; hosted CI has not run. No release was published or submitted for notarization.
