# Changelog

All notable changes to CodexSwap are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - Unreleased

### Added

- Native four-pane Settings window.
- Production release, notarization, Homebrew, and repository-governance infrastructure.
- Menu-controlled automatic Codex routing and reversible config management.
- CodexBar-first account onboarding with a standalone fallback.
- Automatic and manual account quota warm-up.
- Launch at Login and notification preferences.
- Optional terminal shim installation and safe removal.

### Changed

- Simplified the menu-bar menu around status and immediate actions.
- Stabilized the loopback proxy on port `58432`.

### Security

- Restricted targeted warm-up routing to loopback requests.
- Protected Codex configuration backups, manifests, and the optional shim from unsafe overwrites.

## [0.1.0] - 2026-07-11

### Added

- Local menu-bar prototype, multi-account store, proxy routing, usage refresh, priority rotation, and round-robin rotation.

[Unreleased]: https://github.com/M1Vj/CodexSwap/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/M1Vj/CodexSwap/releases/tag/v0.2.0
