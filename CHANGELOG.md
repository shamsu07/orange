# Changelog

## 0.1.5 — 2026-10-23

- Adds optional daily update checks, visible update controls, signed feed/archive verification and user-approved installation after active work finishes.
- Adds the product website, native screenshots, separate usage guide and stable download link.
- Adds contribution, security and conduct policies, dependency notices, pinned CI/Pages actions and signed release tooling. The release-signing key remains local.

See [release notes](docs/releases/0.1.5.md). This release targets Apple silicon/macOS 13+, is ad hoc signed and is not notarized. Earlier versions need one manual installation to enable future updates.


## 0.1.4 — 2026-10-23

- Add configurable tools per file family and shared action visibility; keep supported conversion choices fixed.
- Add optional alignment haptics, enabled by default, with rate limiting and fixed hover targets.
- Hide primary Orange windows when a Finder drag binds; release remains a deliberate picker step.
- Add image crop, explicit compression quality and real encoded-size previews for compression/resize. Reject unchanged/larger compression copies.
- Add PDF split-after-page and custom partitions, plus measured image-based reduction with explicit fidelity-loss consent.
- Add video frame selection, trim ranges, playback and speed controls; fix real low-frame-rate speed output timing.
- Add file Details and Create ZIP for multiple selected items, including distinct parent folders.
- Share the two-worker limit across expensive previews and saved jobs; retain and drain cancelled work on shutdown.
- Separate editing views, preview models, wheel value types and processing limits into focused files.
- Fix live Glass/Solid rendering and opaque Reduce Transparency fallback; preserve selection and Settings focus during visual changes.
- Reject unavailable choices, mixed-family compression and overlapping archive selections.
- Preflight DOCX package expansion, ZIP consistency, XML entities and external embedded resources before native import.

The final 0.1.4 user check passed first attempts for Shift, Command and Control. The earlier intermittent failure was not captured or causally diagnosed; repeated app/file-switch reliability remains unqualified. See [verification](docs/verification-0.1.4.md) for tested scope and remaining acceptance work. This is a local ad hoc signed build, not a notarized public release.
