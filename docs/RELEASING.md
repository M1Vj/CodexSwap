# Releasing CodexSwap

Public releases are produced only by `.github/workflows/release.yml`. Local builds and pull-request builds are ad-hoc signed and must not be uploaded as production artifacts.

## One-time repository configuration

Configure these GitHub Actions secrets:

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded, passwordless Developer ID Application `.p12` certificate |
| `APPLE_API_KEY_P8_BASE64` | Base64-encoded App Store Connect API private-key file |

Configure these GitHub Actions variables:

| Variable | Purpose |
| --- | --- |
| `CODE_SIGN_IDENTITY` | Full `Developer ID Application: … (TEAMID)` identity |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer ID |

The certificate and API key are decoded only into permission-restricted files on the ephemeral macOS runner. The certificate is imported into a temporary keychain and all files and the keychain are removed in an `always()` cleanup step. The workflow intentionally uses a passwordless `.p12` stored as an encrypted GitHub secret so no certificate passphrase is exposed through a process argument.

Allow GitHub Actions to create and merge pull requests so the release workflow can publish the checksum-pinned Homebrew cask update. The workflow explicitly dispatches CI for the generated cask commit, waits for that exact run to pass, and then merges the cask PR.

## Prepare a release

1. Choose the next semantic version.
2. Set the exact `X.Y.Z` value in `VERSION`.
3. Move relevant entries from `Unreleased` to the versioned section in `CHANGELOG.md` and add the release date.
4. Run the complete local verification gate:

   ```bash
   bash Scripts/test-repository-config.sh
   bash Scripts/test-release-tools.sh
   swift test
   swift build -c release
   Scripts/build-universal.sh
   Scripts/package-release.sh
   REQUIRE_NOTARIZATION=0 REQUIRE_GATEKEEPER=0 Scripts/verify-release.sh
   git diff --check
   ```

5. Commit the version and changelog together and merge them to `main`.
6. Create and push an annotated tag that exactly matches `v$(cat VERSION)`.

Never reuse or move a published version tag.

## What the release workflow enforces

The tag workflow:

1. Confirms the annotated tag exactly matches `VERSION`, points to a commit on `main`, and reruns repository/tooling tests.
2. Refuses to continue when any Developer ID or notarization input is absent.
3. Builds `arm64` and `x86_64` products and combines them into one app.
4. Signs nested executables and the app with Developer ID, hardened runtime, and a secure timestamp.
5. Creates the ZIP, submits it to Apple's notary service, staples the ticket, and rebuilds the ZIP.
6. Verifies the checksum, bundle ID, version, architectures, code signature, stapled ticket, and Gatekeeper assessment.
7. Publishes the ZIP, checksum, and rendered cask as GitHub release assets.
8. Opens a cask-update PR containing the exact notarized artifact checksum, dispatches CI for it, and merges it only after that run passes.

Any failed validation through the public-artifact verification step stops the GitHub release from being published. The workflow does not fall back to ad-hoc signing, skip notarization, or use an unchecked Homebrew checksum.

The GitHub release is created before the generated cask PR is tested and merged. If that later cask step fails, the signed release remains valid and downloadable but Homebrew installation is not yet available. Do not delete or recreate the release. Retrieve its `codexswap.rb` release asset, open a cask-only PR against `main`, let CI pass, and merge that PR to complete Homebrew publication.

## Homebrew cask completion

After the generated cask PR passes CI and merges, verify from a clean tap:

```bash
brew untap M1Vj/CodexSwap 2>/dev/null || true
brew tap M1Vj/CodexSwap https://github.com/M1Vj/CodexSwap
brew install --cask codexswap
brew uninstall --cask codexswap
```

The cask's `zap` stanza deletes only CodexSwap preferences and application support. It must never remove `~/.codex`, CodexBar data, or unrelated authentication files.

## Failed or compromised release

- Stop and investigate rather than republishing a different artifact under the same tag.
- Delete an unpublished draft release if needed, fix the cause, and issue a new version.
- For a published bad build, mark the release and changelog clearly, revoke or remove the asset, and publish a patch version.
- Revoke and replace any exposed Developer ID certificate, App Store Connect key, or GitHub credential immediately.
- Use GitHub's security advisory process when user credentials or the request-routing boundary may be affected.
