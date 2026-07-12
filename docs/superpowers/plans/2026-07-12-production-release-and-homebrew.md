# Production Release and Homebrew Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a trustworthy, versioned, licensed, documented, CI-verified macOS release pipeline with a custom Homebrew cask.

**Architecture:** Keep local builds ad-hoc and separate from public distribution. A root version contract drives universal bundle assembly; tag-triggered CI imports Developer ID credentials, signs, notarizes, staples, verifies, and publishes a ZIP/checksum pair. Homebrew consumes only that verified GitHub Release artifact.

**Tech Stack:** Swift Package Manager, Bash, Apple codesign/notarytool/stapler, GitHub Actions, Homebrew Cask, Markdown.

---

### Task 1: Establish project governance and trust documents

**Files:**
- Create: `LICENSE`
- Create: `SECURITY.md`
- Create: `PRIVACY.md`
- Create: `CONTRIBUTING.md`
- Create: `CODE_OF_CONDUCT.md`
- Create: `CHANGELOG.md`

- [ ] **Step 1: Add the MIT license**

Use the standard MIT text with `Copyright (c) 2026 VJ Mabansag` and no additional restrictions.

- [ ] **Step 2: Add security and privacy boundaries**

Document GitHub private vulnerability reporting, supported release policy, local credential paths, loopback-only proxying, OpenAI network destinations, CodexBar integration, no telemetry, and safe deletion boundaries.

- [ ] **Step 3: Add contribution and community documents**

Document macOS 14, Swift toolchain, `rtk swift test`, atomic commits, pull-request expectations, security-sensitive token handling, and the Contributor Covenant 2.1 contact path through repository maintainers.

- [ ] **Step 4: Start the changelog**

Use Keep a Changelog sections for `Unreleased`, `0.2.0`, and the existing `0.1.0` local prototype. Describe native Settings, automatic routing, account warm-up, and production packaging without claiming an unpublished release exists.

- [ ] **Step 5: Verify and commit**

Run: `rtk git diff --check`

Expected: no whitespace errors.

Run: `rtk git add LICENSE SECURITY.md PRIVACY.md CONTRIBUTING.md CODE_OF_CONDUCT.md CHANGELOG.md && rtk git commit -m 'docs: establish project governance'`

### Task 2: Make versioning and app assembly deterministic

**Files:**
- Create: `VERSION`
- Create: `Scripts/version.sh`
- Create: `Scripts/test-release-tools.sh`
- Modify: `Scripts/build-app.sh`
- Modify: `.gitignore`

- [ ] **Step 1: Write a failing version-contract test**

`Scripts/test-release-tools.sh` must verify that `Scripts/version.sh` accepts `0.2.0`, rejects `v0.2.0`, rejects `0.2`, and that a built Info.plist contains the same short version and an integer build number.

- [ ] **Step 2: Run the test and verify failure**

Run: `rtk bash Scripts/test-release-tools.sh`

Expected: failure because `VERSION` and `Scripts/version.sh` do not exist.

- [ ] **Step 3: Implement the version reader**

Create `VERSION` containing `0.2.0`. `Scripts/version.sh` reads an optional file argument, trims one trailing newline, validates `^[0-9]+\.[0-9]+\.[0-9]+$`, and prints the version or exits nonzero.

- [ ] **Step 4: Refactor app assembly**

`Scripts/build-app.sh` must:

- Read `VERSION` through `Scripts/version.sh`.
- Accept `BUILD_NUMBER`, defaulting to `1`, and validate it as a positive integer.
- Accept `CODE_SIGN_IDENTITY`, defaulting to `-` for local builds.
- Build both executables using an overridable `BUILD_PRODUCTS_DIR`.
- Write the bundle version values with PlistBuddy.
- Sign nested executables before signing the app.
- Use hardened runtime and secure timestamps only for non-ad-hoc identities.
- Verify the resulting signature and plist.

- [ ] **Step 5: Run the contract and Swift tests**

Run: `rtk bash Scripts/test-release-tools.sh && rtk summary swift test && rtk Scripts/build-app.sh`

Expected: version-contract checks pass, Swift tests pass, and `dist/CodexSwap.app` reports version `0.2.0`.

- [ ] **Step 6: Commit**

Run: `rtk git add VERSION Scripts .gitignore && rtk git commit -m 'build: make app versioning deterministic'`

### Task 3: Add universal packaging, notarization, and verification

**Files:**
- Create: `Scripts/build-universal.sh`
- Create: `Scripts/package-release.sh`
- Create: `Scripts/notarize-release.sh`
- Create: `Scripts/verify-release.sh`
- Create: `CodexSwap.entitlements`
- Modify: `Scripts/test-release-tools.sh`

- [ ] **Step 1: Add failing release-tool contract checks**

Extend the shell test to assert every release script supports `--help`, rejects a tag/version mismatch, and refuses notarization when required credential names are unset.

- [ ] **Step 2: Verify the checks fail**

Run: `rtk bash Scripts/test-release-tools.sh`

Expected: failure because the release scripts do not exist.

- [ ] **Step 3: Implement universal build and packaging**

`build-universal.sh` builds arm64 and x86_64 products into isolated scratch paths, combines matching executables with `lipo`, then calls `build-app.sh` with the universal product directory. `package-release.sh` creates `dist/CodexSwap-v0.2.0-macOS-universal.zip` using `ditto` and writes a matching `.sha256` file.

- [ ] **Step 4: Implement fail-closed notarization**

`notarize-release.sh` requires `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`, submits the pre-notarization ZIP with `xcrun notarytool --wait`, staples `CodexSwap.app`, validates stapling, and rebuilds the final ZIP/checksum. It never echoes credentials.

- [ ] **Step 5: Implement artifact verification**

`verify-release.sh` verifies the ZIP checksum, extracted bundle version, bundle identifier, both Mach-O architectures, nested and outer signatures, stapled ticket when `REQUIRE_NOTARIZATION=1`, and Gatekeeper assessment when `REQUIRE_GATEKEEPER=1`.

- [ ] **Step 6: Exercise the local ad-hoc path**

Run: `rtk bash Scripts/test-release-tools.sh && rtk Scripts/build-universal.sh && rtk Scripts/package-release.sh && rtk env REQUIRE_NOTARIZATION=0 REQUIRE_GATEKEEPER=0 Scripts/verify-release.sh`

Expected: all script contracts pass and the local universal ZIP verifies without pretending it is notarized.

- [ ] **Step 7: Commit**

Run: `rtk git add Scripts CodexSwap.entitlements && rtk git commit -m 'build: add verified macOS release packaging'`

### Task 4: Add Homebrew cask generation and validation

**Files:**
- Create: `Casks/.gitkeep`
- Create: `Scripts/render-cask.sh`
- Create: `Scripts/verify-cask.sh`
- Create: `Casks/codexswap.rb.template`
- Modify: `Scripts/test-release-tools.sh`

- [ ] **Step 1: Add a failing cask-render test**

The test renders a cask with version `0.2.0` and a known 64-character SHA-256, then asserts the GitHub Release URL, `app "CodexSwap.app"`, Sonoma dependency, and safe `zap` paths. It must reject a missing or malformed checksum.

- [ ] **Step 2: Verify the test fails**

Run: `rtk bash Scripts/test-release-tools.sh`

Expected: failure because the cask tools do not exist.

- [ ] **Step 3: Implement deterministic cask rendering**

`render-cask.sh` reads `VERSION`, requires a SHA-256 argument or checksum file, and writes `Casks/codexswap.rb`. The generated cask points to `https://github.com/M1Vj/CodexSwap/releases/download/v#{version}/CodexSwap-v#{version}-macOS-universal.zip`, installs the app, requires Sonoma, and zaps only CodexSwap-owned support/preferences files.

- [ ] **Step 4: Validate cask syntax and style**

`verify-cask.sh` runs `ruby -c`, verifies no `:no_check`, validates the release URL shape, and uses `brew style --cask` when Homebrew is available. Online audit is enabled only when `CASK_ONLINE_AUDIT=1` after the release exists.

- [ ] **Step 5: Verify and commit the release tooling**

Run: `rtk bash Scripts/test-release-tools.sh`

Expected: all cask renderer tests pass. Do not commit a generated cask with a fabricated checksum; only the template and generator are committed before the first notarized release.

Run: `rtk git add Casks Scripts && rtk git commit -m 'feat: add Homebrew cask release tooling'`

### Task 5: Add CI, release automation, and repository templates

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`
- Create: `.github/CODEOWNERS`
- Create: `.github/PULL_REQUEST_TEMPLATE.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Create: `.github/ISSUE_TEMPLATE/config.yml`

- [ ] **Step 1: Add CI**

CI runs on pushes and pull requests using macOS 14, executes the shell contract tests, full Swift tests, release build, local app assembly, shell syntax validation, cask-template validation, and `git diff --check`.

- [ ] **Step 2: Add fail-closed release automation**

The release workflow runs on `v*` tags, verifies tag equals `v$(cat VERSION)`, imports the Developer ID P12 into an ephemeral keychain, builds universal binaries, signs with hardened runtime, notarizes and staples, verifies with Gatekeeper required, renders the exact cask checksum, uploads ZIP/checksum/cask with `gh release create`, and deletes the keychain in an `always()` step.

- [ ] **Step 3: Add repository contribution templates**

CODEOWNERS assigns `@M1Vj`. Bug reports request macOS/Codex/CodexBar versions, reproduction steps, routing state, and sanitized logs. Templates explicitly warn against posting tokens or auth files.

- [ ] **Step 4: Validate YAML and commit**

Run: `rtk ruby -e 'require "yaml"; Dir[".github/workflows/*.yml", ".github/ISSUE_TEMPLATE/*.yml"].each { |f| YAML.load_file(f); puts f }'`

Expected: every YAML file parses.

Run: `rtk git add .github && rtk git commit -m 'ci: add quality and notarized release workflows'`

### Task 6: Rewrite public documentation

**Files:**
- Rewrite: `README.md`
- Create: `docs/RELEASING.md`
- Create: `docs/TROUBLESHOOTING.md`

- [ ] **Step 1: Rewrite README around user outcomes**

Include badges, a concise safety-aware overview, requirements, Homebrew installation contract, direct download, source build, first-run setup, CodexBar-first account onboarding, settings panes, routing architecture, quota warm-up warning, data/security model, troubleshooting links, development commands, contributing/security/license links, and an explicit release-status note until the first notarized artifact exists.

- [ ] **Step 2: Document maintainer release operations**

`docs/RELEASING.md` specifies all four GitHub secrets, certificate export/import, version bump, changelog update, signed tag, workflow verification, SHA/cask generation, Homebrew tap command, rollback, and the rule against publishing ad-hoc artifacts.

- [ ] **Step 3: Add troubleshooting**

Cover proxy port conflicts, routing repair, existing Codex session restart, CodexBar ownership, standalone imports, launch-at-login, quota warm-up, Gatekeeper, uninstall, and sanitized diagnostic commands.

- [ ] **Step 4: Check documentation and commit**

Run: `rtk grep -n 'PLACEHOLDER\|REPLACE_ME\|example.invalid' README.md docs SECURITY.md PRIVACY.md CONTRIBUTING.md CHANGELOG.md`

Expected: no placeholders or fake production links.

Run: `rtk git add README.md docs && rtk git commit -m 'docs: publish production user and release guides'`

### Task 7: Final verification, GitHub integration, and release readiness

**Files:**
- Modify only files required by review findings

- [ ] **Step 1: Run the complete local gate**

Run: `rtk bash Scripts/test-release-tools.sh && rtk summary swift test && rtk swift build -c release && rtk Scripts/build-universal.sh && rtk Scripts/package-release.sh && rtk env REQUIRE_NOTARIZATION=0 REQUIRE_GATEKEEPER=0 Scripts/verify-release.sh && rtk git diff --check`

Expected: every local gate passes.

- [ ] **Step 2: Conduct security and quality review**

Review credential handling, archive paths, cask zap paths, shell quoting, GitHub permissions, third-party action pinning, release failure behavior, README claims, and repository dead code. Fix all blocking findings in atomic commits.

- [ ] **Step 3: Push through a pull request**

Push `feature/production-release`, open a pull request to `main`, wait for CI, address failures, and merge only when required checks pass. Do not tag `v0.2.0` until Developer ID and notarization secrets are configured.

- [ ] **Step 4: Update GitHub repository metadata**

Set the public description to the README summary, add topics `codex`, `macos`, `menu-bar`, `swift`, `multi-account`, and `homebrew`, enable private vulnerability reporting when the GitHub API permits, and verify the repository license is detected as MIT.

- [ ] **Step 5: Report the exact external release blocker**

Report which credential categories remain absent without revealing values. Provide the next safe command only after confirming the merged remote state and CI result.
