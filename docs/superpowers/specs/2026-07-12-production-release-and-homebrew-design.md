# Production Release and Homebrew Design

## Goal

Turn CodexSwap from a locally built application into a maintainable public macOS project with clear licensing, trustworthy release artifacts, automated quality gates, documented security and privacy behavior, and a supported Homebrew installation path.

## Distribution Position

CodexSwap will use a custom Homebrew tap stored in this repository. Homebrew users will tap the repository explicitly and install the `codexswap` cask. This is appropriate before the project has the release history and notability expected by the official `homebrew-cask` repository.

The cask installs a versioned ZIP from GitHub Releases. It does not build from source, bypass quarantine, or disable Gatekeeper. Public release artifacts must be Developer ID signed, use the hardened runtime, be notarized by Apple, and have the notarization ticket stapled before publication.

Local development builds remain ad-hoc signed. The release workflow fails closed when signing or notarization credentials are absent; it never silently publishes an ad-hoc build as production.

## Version and Artifact Contract

- The next release version is `0.2.0`, stored in a root `VERSION` file.
- Git tags use `v<version>`, for example `v0.2.0`.
- The app bundle reads its short version from `VERSION` and its build number from CI or an explicit environment variable.
- The public archive is named `CodexSwap-v<version>-macOS-universal.zip`.
- The archive contains `CodexSwap.app` with both arm64 and x86_64 slices.
- Each release includes a SHA-256 checksum file.
- A release verification script checks bundle identifiers, version agreement, architectures, signatures, Gatekeeper assessment, and ZIP contents.

## Build and Signing

The build scripts separate concerns:

1. Build universal Swift executables.
2. Assemble the application bundle and Info.plist.
3. Sign nested executables, then the app bundle.
4. Package a ZIP suitable for Apple notarization.
5. Submit with `notarytool`, wait for success, staple the app ticket, and rebuild the final ZIP.
6. Verify the final artifact before uploading it.

The signing workflow imports a base64-encoded Developer ID Application certificate into an ephemeral keychain. Notarization uses an Apple ID, Team ID, and app-specific password supplied only through GitHub Actions secrets. No credential values are logged or committed.

## Homebrew

`Casks/codexswap.rb` declares:

- The current stable version and exact SHA-256.
- The matching GitHub Release URL.
- `CodexSwap.app` as the installed artifact.
- macOS Sonoma 14 or newer.
- A `zap` stanza for CodexSwap application-support and preference data, without deleting Codex or CodexBar credentials.

The checksum must be updated only after a verified, notarized release exists. Until the first production release is published, the cask remains release-ready but is not represented as a working download.

## Repository Quality Gates

Pull requests and pushes run:

- Swift tests.
- Debug and release builds.
- Strict configuration and packaging checks.
- Shell syntax checks.
- Homebrew cask style/audit checks that do not require an unpublished asset.
- Secret-pattern and whitespace checks.

The release workflow runs only for `v*` tags and verifies the tag exactly matches `VERSION` before signing.

## Project Governance and Trust

The repository adds:

- MIT `LICENSE` under VJ Mabansag.
- `SECURITY.md` with private vulnerability-reporting guidance.
- `PRIVACY.md` explaining local token storage, network destinations, and the absence of telemetry.
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, and `CHANGELOG.md`.
- Issue and pull-request templates plus code ownership.
- `docs/RELEASING.md` documenting credentials, tag creation, cask checksum updates, rollback, and verification.

The README becomes user-first: what CodexSwap does, security model, requirements, Homebrew/direct/source installation, first-run setup, account ownership, quota warm-up caveats, troubleshooting, development, release status, and license.

## Security Boundaries

- CodexSwap binds only to loopback.
- Account tokens and settings remain in the user's local application-support and Codex/CodexBar homes.
- No telemetry or remote CodexSwap service is introduced.
- The release pipeline never prints signing material.
- The Homebrew `zap` stanza does not remove `~/.codex`, CodexBar-managed homes, or unrelated credentials.
- Release failure at signing, notarization, stapling, Gatekeeper assessment, checksum, or version verification blocks publication.

## Verification

- Run the full Swift test suite and both build configurations.
- Build and validate a local ad-hoc universal artifact without publishing it.
- Validate scripts with shell syntax checks.
- Validate the cask syntax and style locally.
- Exercise installation from the locally built ZIP in a temporary Homebrew tap when possible.
- Review all documentation against actual paths and behavior.
- Push through a pull request and merge only after CI passes.

## Known External Requirement

A Developer ID Application certificate and Apple notarization credentials are external prerequisites. The repository can be fully prepared and verified without them, but a trusted public release and live Homebrew download cannot be truthfully completed until the credentials are configured in GitHub Actions.
