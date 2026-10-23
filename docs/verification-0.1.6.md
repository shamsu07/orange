# Orange 0.1.5–0.1.6 release verification

Date: 2026-10-23. Distribution target: Apple silicon, macOS 13 or later. These checks ran on the development Mac; the deployment target is not a macOS 13 runtime test.

## Automated checks

- Full local suite with the shipped media backend on PATH: 212 tests, zero failures, zero skips, no compiler warnings (108 core, 104 app).
- Release tooling: 10 tests passed, including real Sparkle/CryptoKit signing, tampered-feed rejection, wrong embedded public-key rejection and preservation of the prior feed after signing failure.
- Refactored PDF options/workflows: 16 focused tests passed. The image-preview tests passed five consecutive runs after replacing timing assumptions with task completion boundaries.
- [Hosted release-source CI](https://github.com/shamsu07/orange/actions/runs/39919775973) passed both jobs. Native CI executed 212 tests with 10 optional-media skips; the local shipped-backend run had no skips. The macOS signing integration also passed. The initial hosted runs exposed a PDF ViewBuilder compiler limit, a short test deadline and Bash 3.2 empty-array behavior; each received a focused fix.
- Static website: 3 pages and 60 references checked for local destinations, fragments and basic accessible markup. Desktop and 390-pixel responsive layouts were inspected in Chrome; the wheel illustration switches tools. A console error came from an installed browser extension, not Orange's script.
- The packaged 0.1.6 ZIP matched all 150 files and symbolic links in the built application. ZIP integrity, DMG checksums, nested code signatures, bundled backend source hashes and license materials passed packaging checks.
- The command-line self-check loaded the bundled framework and reported the signed update configuration and both media executables available.

## Native checks

- The 0.1.5 app read the real signed GitHub Pages feed and displayed the expected up-to-date dialog.
- The 0.1.6 app displayed the same refactored PDF reduction controls, measured a 508 KB fixture to 265 KB, and kept saving disabled until flattening consent. The test was cancelled without saving a new PDF.
- A successful current-version check in 0.1.6 left Settings without an error message.
- A copy of the public 0.1.5 ZIP was launched inside the repository. Its updater found the public 0.1.6 release, downloaded it, reached Ready to Install, installed and relaunched successfully. The new Settings pane showed 0.1.6; a second live check reported it up to date without an error. The installed bundle passed deep signature verification, and its executable matched the tested 0.1.6 build byte for byte.
- The site screenshots are native Orange windows using repository-owned synthetic fixtures. The hero wheel is explicitly an interactive illustration.

## Resource spot check

With 0.1.5's windows closed, a 30.01-second idle sample recorded 0.00 seconds of additional CPU at the process counter's resolution. RSS remained 171,917,312 bytes. This checks one idle interval after adding Sparkle; it is not all-day battery evidence or a matched comparison with Tangerine.

## Distribution and trust

The project source and existing history were pushed without rewriting earlier commits. Dependencies and third-party Actions are pinned. Private vulnerability reporting is enabled. The signing key remains local in an owner-only, ignored directory; it was not exported to GitHub Actions. The optional hosted signing workflow fails early when no signing secret is configured.

The public 0.1.5 DMG and ZIP were downloaded anonymously and matched the local release checksums. The live site, guide and feed matched their committed files; the live feed signature verified. The public 0.1.6 stable DMG alias and versioned ZIP also matched the tested files byte for byte. Its deployed appcast matched source and its signature verified. The [Pages deployment](https://github.com/shamsu07/orange/actions/runs/39920393160) passed.

## Remaining boundaries

The app is ad hoc signed and not notarized. Fresh browser-download Gatekeeper behavior, reboot/login acceptance, repeated Finder activation, multi-display behavior, physical sound/haptic feel, long-duration battery use, full file-format parity and independent security review are not established by these checks. The earlier user accepted all three first-attempt wheels in 0.1.4; that observation does not prove every future drag succeeds.
