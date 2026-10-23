# Contributing to Orange

Orange is a native macOS file converter under active development. The target is a fully open-source implementation of Tangerine's workflows, but [exact parity is not established](docs/reference-parity.md). Contributions should improve a working route or close a documented gap with evidence.

## Development

Use macOS with a Swift 6 compiler; the package uses Swift 5 language mode and targets macOS 13. Runtime validation currently covers macOS 27.0.1 on arm64, so report older-system and Intel results explicitly.

```sh
bash scripts/build.sh
open build/Orange.app
```

Swift Package Manager resolves the pinned Sparkle dependency during the build. `Package.resolved` is committed; review dependency changes together with their source revision, release notes and license. Conversion itself does not fetch packages or converters.

For the source-built media backend:

```sh
bash scripts/build-ffmpeg.sh
PATH="$PWD/.cache/tools/bin:$PATH" bash scripts/test.sh
```

The backend build is an explicit source download/build step. Its pin, configuration and license materials are described in [FFmpeg build notes](docs/ffmpeg-build.md). Tests can run without that backend, but media coverage then differs. Vision/CoreVideo tests require normal macOS service access; a restricted automation sandbox can block those services. Record the exact command, platform, backend and any skipped tests.

[Default CI](.github/workflows/ci.yml) uses a GitHub-hosted macOS runner to run source tests, build the release bundle, verify its signature and run the command-line self-check. It does not compile the optional FFmpeg backend from source. The media tests check backend/encoder availability and skip explicitly when unavailable; installed runner tools can affect coverage. This does not replace the locally enabled media suite or native GUI acceptance. [Runner images change](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), so use each job's recorded OS, architecture, Swift version and test skips when assessing a result. A workflow file is not evidence of a successful hosted run.

Keep generated fixtures and caches inside this repository. Tests generate their inputs under `.cache/tests/`; do not depend on personal files, another application's installed assets, or a developer's home directory.

## Code and behavior

- Follow the existing Swift style: four-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, explicit names and small focused functions. No formatter or linter is configured as a required repository tool.
- Keep UI work on the main actor short. Perform conversion and capability probing off the UI thread, respect the global job bound, and check cancellation at meaningful boundaries.
- Add a format only when its actual decoder/encoder and input conditions are verified. Derive menus from real capabilities. Renaming an extension is not conversion.
- Preserve source files and publish through `OutputWriter`. Explicit Move is the documented exception. Test collisions, bad inputs, cancellation and partial-output cleanup when relevant.
- Keep subprocess invocation shell-free through `ProcessRunner`. Do not add automatic downloads, telemetry, external services or unbounded worker creation to a local conversion path.
- Keep update transport separate from conversion. Update checks must not send selected file information, open windows during Finder interactions, silently install an update or weaken the feed/archive signature requirements. Keep work completion and shutdown event-driven.
- Name fidelity limits plainly. Text OCR is not editable-Office layout reconstruction; container support is not every codec, track, animation, color or metadata case.

## Verification

Run tests appropriate to the change and report their actual result. Add meaningful generated-fixture coverage for changed behavior; avoid tests that only repeat implementation details. Documentation-only changes do not need a Swift rebuild.

For UI changes, describe the native workflows exercised: file selection, Finder-originated drag, modifier press/release, paging, cancellation, actions and preferences as applicable. A screenshot, headless self-check, or passing core suite does not establish the full interaction flow.

For an intermittent wheel failure, use the optional local diagnostics build:

```sh
CONFIGURATION=debug ORANGE_WHEEL_TRACE=1 bash scripts/build.sh
open build/Orange.app
```

The trace is `.cache/wheel-activation.jsonl`. It records input metadata, pointer positions, modifier/button state, receiver transitions and native callback metadata. It does not record file paths, file contents or arbitrary typed text. Preserve the trace before restarting the app: each run replaces it. Quit normally to flush pending records. Capture an actual failed gesture before attributing a cause; a successful debug attempt cannot qualify release reliability. Diagnostics add timing overhead and are disabled in ordinary release builds. Packaging rejects a diagnostics-enabled bundle.

For performance changes, record hardware/OS, build mode, fixtures, output settings, sample counts and output validation. Report RSS and charged physical footprint separately. RSS growth alone does not prove a leak. The [v5 synthetic measurements](docs/benchmarks/2026-10-21-arm64-v5-detached.json) are a diagnostic baseline, not a photographic workload or a Tangerine comparison.

## Pull requests

Keep one focused fix or feature per commit, with a short imperative message and its meaningful regression coverage. Inspect the staged tree so helper files are included and each commit remains buildable. Orange's first commit is a truthful snapshot of the existing prototype; earlier development was not reconstructed as invented history. Follow-up defects found during native checks receive their own fix commits. Generated caches, fixtures, app bundles and release archives remain ignored.

Keep a pull request focused. Explain the concrete problem, resulting behavior, relevant limits and validation. Use short imperative commit messages. Link the issue or parity requirement when one exists; include before/after native evidence for visual changes without claiming unmeasured exactness.

Orange source and original artwork use [MIT](LICENSE). Bundled FFmpeg retains its upstream LGPL terms and matching source/license materials. New dependencies need a documented source, version, license and redistribution approach. Do not submit proprietary reference-application code, copied product artwork, credentials or private test files.

Read the [code of conduct](CODE_OF_CONDUCT.md) before participating and the [security policy](SECURITY.md) before reporting a vulnerability. Use synthetic fixtures and remove private paths from screenshots and logs.

## Local packaging

```sh
bash scripts/package.sh
```

The packaging script builds the app and produces a DMG, ZIP and checksums in `dist/`. Use `--no-build` only to package an existing verified bundle. It refuses to overwrite prior release artifacts. Signing/notarization are optional explicit environment settings described in the [README](README.md); a locally generated package is not a published or notarized release merely because it exists.

The existing arm64 app has passed a `--no-build` packaging smoke, checksum verification and read-only image inspection, including its Applications link and bundled source/licenses. Normal macOS disk-image service access was required. Repeat packaging against the final app after source changes; the smoke does not qualify a later build automatically.

Ad hoc signature verification is an integrity check, not Gatekeeper approval. Downloaded ad hoc builds can require the user's explicit Privacy & Security approval on first launch. Do not describe a package as consumer-ready or notarized without validating its actual signing/ticket status and installation flow. The command-line self-check does not launch or validate the GUI.

## Release integrity

Release artifacts must come from the recorded source commit and verified final bundle. Keep previous artifacts, publish their exact checksums, and record the platform, backend versions, signing status and checks performed. Never replace an already published version with different app bytes.

Sparkle 2.10.0 uses an embedded public Ed25519 key to verify both the update feed and update archive. Treat the matching private key as a release credential: keep it out of source, logs, artifacts, issue attachments and pull requests. A new installation needs the same trusted key to accept later updates; rotating it requires an explicit migration plan. Sign the finalized feed bytes after the archive URL, size, signature and version are correct, and verify the result before publication. Do not modify signed feed bytes afterward.

Untrusted pull requests must not receive signing credentials or release-write permissions. Dependency and workflow revisions must be reviewed before a release. A signed update feed authenticates the publisher; it does not replace Developer ID signing, notarization, regression checks or an independent security review. See [third-party notices](THIRD_PARTY_NOTICES.md) for redistributed components.
