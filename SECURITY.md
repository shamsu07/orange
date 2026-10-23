# Security policy

Orange is an early-stage local file converter. Untrusted files reach macOS image, PDF, document and media parsers, and optional FFmpeg tools. Input limits and tests reduce specific risks; they do not establish that every format is safe or that the application has had an independent security audit.

## Supported versions

Security fixes target the latest public release and the current `main` branch. Older releases do not receive separate backports. Include the exact Orange version, macOS version, architecture and backend version when reporting a problem.

## Report a vulnerability

Do not put exploit details, private input files, credentials or another person's data in a public issue or pull request.

Use GitHub's private [Report a vulnerability](https://github.com/shamsu07/orange/security/advisories/new) form. Private vulnerability reporting is enabled for this repository. There is no separate security email or response-time guarantee currently published.

A useful private report includes:

- The affected version or commit and the smallest steps that reproduce the issue.
- The input format and a synthetic, non-private fixture or a description of how to generate it.
- The observed impact, relevant error output and any proposed fix.
- Whether the problem depends on a custom FFmpeg/backend configuration.

Maintainers should reproduce and assess reports privately, agree on a disclosure plan with the reporter, and publish a fix and advisory when appropriate. Do not attach confidential material to a public release or regression test.

## Trust boundaries and known limits

- Conversion outputs preserve original inputs and use same-folder staging with exclusive publication. The explicit Move action changes source locations. Preview workspaces are temporary and cleaned up; an interrupted operating system or filesystem can still prevent cleanup.
- FFmpeg subprocesses receive local file arguments, a restricted protocol/format list and bounded diagnostics. The bundled build disables network protocols. A user-selected backend is executable code and must come from a trusted source.
- DOCX imports preflight ZIP expansion, entry names, checksums and XML, and reject linked external resources. These controls do not replace security fixes in macOS's native importers.
- Optional update checks contact the HTTPS GitHub Pages feed; user-requested update downloads contact GitHub Releases. Selected file contents and paths are not sent. GitHub receives ordinary request metadata, including the client's IP address. Sparkle system profiling is disabled. AirDrop remains a separate, explicit user sharing action.
- Sparkle 2.10.0 verifies Ed25519 signatures for both feed metadata and update archives with an embedded public key. The configuration rejects unsigned feeds rather than falling back after an expiry interval. Downloading and installing require user action, and relaunch waits for active work. Compromise of the release signing key or a maintainer's release environment remains a critical trust boundary.
- Orange is not an isolation sandbox for hostile documents. Keep macOS and converter dependencies updated, and avoid opening untrusted files on systems containing sensitive data.
- A valid local signature or published checksum checks specific integrity properties. It is not a security audit or a notarization claim. Consult the release notes for each artifact's actual signing and notarization status.

For implementation details and remaining qualification gaps, see [architecture](docs/architecture.md) and the [verification reports](docs/verification-0.1.6.md). Ordinary feature requests and non-security bugs belong in [GitHub issues](https://github.com/shamsu07/orange/issues).
