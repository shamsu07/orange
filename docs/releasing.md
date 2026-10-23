# Releasing Orange

The default release process keeps the signing key local. The optional hosted workflow remains unavailable until a maintainer explicitly provisions its secret.

Orange releases are maintainer actions. A pull request never receives the update signing key or publishes an application. Review the source, run the native acceptance checks, then publish a version from `main`.

## Release identities

- Product site and signed feed: `https://shamsu07.github.io/orange/` and `appcast.xml`.
- Release assets: `https://github.com/shamsu07/orange/releases`.
- App identifier: `org.orange.converter`.
- Current distribution target: Apple silicon, macOS 13 or later. The Swift package and bundle minimum OS must agree.
- Public update verification key: `SUPublicEDKey` in `scripts/Info.plist`. This is public and belongs in source control.
- Private update signing key: `.orange-secrets/sparkle-ed25519.key`, ignored by Git, owner-only access. Never commit it, put it in an issue, print it to CI logs or attach it to a release.

The Ed25519 update key authenticates the appcast and update ZIP. It does not provide Apple Developer ID signing or notarization. The initial release is ad hoc signed and is not notarized. The hosted workflow retains that distribution model. Adding Developer ID signing requires a separate reviewed credential setup; do not describe these builds as Apple-notarized.

## Prepare a version

1. Increment `CFBundleShortVersionString` and `CFBundleVersion` in `scripts/Info.plist`. A public version uses three numeric components, for example `0.1.6`. The build number must increase for every published build, even when changing only packaging. The app reads its displayed version from the bundle.
2. Add `docs/releases/<version>.md` with concise user-facing changes, material limitations and the distribution signing state. It becomes both the GitHub release notes and the updater's plain text notes.
3. Run the relevant tests and `python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v`. Run `python3 site/check.py` to check local website assets, links and fragments.
4. Build the pinned FFmpeg/libwebp tools, then test with that exact backend. Run `scripts/build.sh`, verify the app's self-check, and perform native Finder acceptance checks on the build to be released. Automated tests cannot establish first-attempt Finder activation, focus behavior, sound latency or physical haptic feel.
5. Inspect and commit the changes in focused commits. Push reviewed `main` before publishing. Do not replace an existing version or move a published tag.

## Optional hosted signing

The repository must be public, GitHub Actions enabled, and Pages configured to use **GitHub Actions**. The `github-pages` environment deploys only from the intended branch. The product website workflow handles site changes on `main` and can also be run manually.

Create the update signing key once from the repository root:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" swift scripts/create-update-key.swift
```

This prints only the public key. Copy the printed public key into `SUPublicEDKey` before building the first updater-enabled release. Preserve a secure backup of the private key outside this checkout only when explicitly authorized. Losing the key prevents those installed applications from accepting updates signed by a replacement key; changing only the public key in a new build does not update the trust of installed copies.

A maintainer can provision the same key as the repository's encrypted Actions secret without placing it on a command line:

```sh
gh secret set SPARKLE_PRIVATE_KEY --repo shamsu07/orange < .orange-secrets/sparkle-ed25519.key
```

Configure that secret only from the intended private key file. Its name is `SPARKLE_PRIVATE_KEY`. It is read only in the signing step and written to an owner-only temporary file inside the checkout. Cleanup runs after success or failure. Contributors and pull request jobs do not need this secret.

The initial signed `site/appcast.xml` must be committed before the hosted release workflow is used. The first updater-enabled release is published locally so its real bundle, archive and feed can be verified together.

## Publish with GitHub Actions

Open **Actions → Publish release → Run workflow**, choose `main`, and enter the already committed version. The equivalent command is:

```sh
gh workflow run release.yml --repo shamsu07/orange --ref main -f version=0.1.6
```

The workflow:

1. Rejects a mismatched version, missing release notes, an existing release or a runner that is not arm64.
2. Builds the checksum-pinned FFmpeg/libwebp sources and runs native tests with those backends.
3. Builds and verifies the app, then packages that exact bundle as a DMG and ZIP.
4. Copies the DMG to the stable download filename `Orange-macos-arm64.dmg` and generates checksums for all three downloads.
5. Reads version, build, minimum OS and verification configuration from the packaged ZIP. It signs the ZIP, verifies it against the public key embedded in the app, then signs and verifies the appcast before replacing its public bytes.
6. Uploads a draft GitHub release, then publishes it. The release tag points to the reviewed workflow source commit.
7. Commits only the signed appcast to `main`, using the previous file SHA to reject a concurrent feed change. It fetches the current website and deploys that site plus signed feed to Pages explicitly. GitHub's built-in workflow token does not trigger a second Pages run when committing the feed.

The regular Pages workflow remains available for website changes and redeployment. All third-party actions are pinned to full official commit SHAs. Dependabot proposes pin updates for review.

If publishing the app succeeds but committing or deploying the feed fails, the release remains downloadable. Installed apps will continue using the previously published feed until the signed new feed is committed and Pages is deployed. Inspect the failed step, verify the release ZIP and signed `appcast.xml` asset, commit those exact feed bytes to `site/appcast.xml`, then run the Product website workflow. Do not regenerate or replace release binaries to repair a website deployment.

## Publish locally

Keep previous artifacts. `scripts/package.sh` refuses to overwrite `dist/SHA256SUMS` or an existing version. Move the previous checksum file to a versioned name before packaging a new release.

After building and accepting the app:

```sh
bash scripts/package.sh --no-build
python3 scripts/make-update-feed.py \
  --archive dist/Orange-0.1.5-macos-arm64.zip \
  --version 0.1.5 --build 6 \
  --notes docs/releases/0.1.5.md
```

The feed helper uses the resolved Sparkle `sign_update` tool in `.build/artifacts/`. It never falls back to a keychain key. It requires a private key file with owner-only permissions, rejects a version downgrade or conflicting build number, and preserves the prior feed if signing or verification fails. `scripts/verify-update-signature.swift` independently checks the archive using CryptoKit and the app's embedded public key. The feed's enclosure URL, signature and byte length correspond to that exact ZIP.

Never reformat or edit `site/appcast.xml` after signing; any byte change requires signing it again. Upload the versioned ZIP, DMG, stable DMG alias, checksums and signed appcast. Commit the feed only after the linked release assets exist. Push source and tags, then deploy Pages.

## Verify a public release

- Confirm the GitHub tag points to the intended source commit and all expected assets are present.
- Download the public DMG and ZIP and compare their SHA-256 checksums with the release checksum file.
- Confirm the site, guide, download button and signed feed are publicly reachable over HTTPS.
- Verify the downloaded appcast with the intended Sparkle key. Confirm its enclosure targets the published versioned ZIP and length.
- Test **Check for Updates** in the installed application. An installed current version should report that it is up to date. A real older updater-enabled installation should see the new version and complete the authenticated download and relaunch flow.
- Record exactly which updater steps were verified. Unit tests or a successful current-version check do not prove installation of a newer public version.

Updates are checked at most daily by default. Users can disable automatic checks and retain the manual command. Availability appears in Orange's UI; background checks do not open Settings or an update window during a Finder gesture. Downloading and installation require the user's update action. The updater waits for active jobs and moves before relaunching.
