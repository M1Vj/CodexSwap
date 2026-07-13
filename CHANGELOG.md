# Changelog

All notable changes to CodexSwap are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Kanban task board (To Do / In Queue / In Progress / Done) with drag-and-drop, per-task editor, and clipboard prompt export.
- Quota-driven task automation: queued tasks run as sandboxed non-interactive `codex exec` sessions the moment quota returns on an enabled account, with plan-first documents (`.codexswap/tasks/<slug>/PLAN.md`) so unfinished work resumes on the next window.
- Proxy task mode (`X-CodexSwap-Task-Accounts`) that rotates only within a task's allowed accounts and never changes the interactive active account.
- Per-task settings: repository folder, branch, model, reasoning effort, sandbox network access, and account override.
- Automation controls in Settings and on the board: master switch, account checklist, max concurrent runs, banked-window consumption, and task notifications.
- Menu-bar running indicator and task started/completed/waiting/failed notifications.

### Fixed

- A failed proxy port bind no longer crashes the app on AsyncHTTPClient shutdown.

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
