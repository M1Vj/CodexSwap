# CodexSwap Build Checklist

## Core engine (SwapKit)
- [x] Codex auth.json model + atomic 0600 read/write
- [x] JWT identity/expiry decode (string-exp safe, profile-claim email)
- [x] Account model (priority, per-limit cooldowns, usage windows, needs-login)
- [x] AccountStore actor: priority + round-robin selection, rotate, needs-login, setActive, import upsert
- [x] TokenRefresher (auth.openai.com/oauth/token)
- [x] UsageClient (wham/usage parse: primary/secondary windows)
- [x] SwiftNIO reverse proxy: header injection, 401-refresh, 429-rotate, streaming
- [x] CodexLauncher config-arg builder (after-subcommand ordering)
- [x] AccountImporter (live auth.json + existing ~/.codex/accounts bundles)
- [x] Settings model (strategy, thresholds, poll interval, notifications, launch-at-login)

## Verification
- [x] Unit tests (19, passing): JWT, usage parse, limit detection, rotation, launcher
- [x] Live spike: real `codex exec` streamed through proxy with injected non-active account
- [ ] Live spike: mid-session hot-swap on 429 rotation
- [x] Live spike via app proxy + codexswap shim (exec turn)

## swapd CLI
- [x] import / list / usage / priority / switch / proxy / run

## Menu-bar app (CodexSwapApp)
- [x] Accessory-policy menu bar item (control panel, no usage-gauge duplication of CodexBar)
- [x] Account list with priority, active marker, per-window usage, cooldown timers
- [x] Manual switch
- [x] Background proxy lifecycle + usage poller
- [x] Proactive threshold pre-switch
- [x] Native notifications (rotate / exhausted / window-reset), toggleable
- [x] Launch at login (SMAppService) — needs packaged .app
- [~] Health checks (needs-login detection) done; usage history pending
- [x] Add-account flow via `codex login`
- [x] Settings via menu toggles + settings.json (dedicated UI optional)

## Task board automation (feat/task-board-automation)
- [x] AutomationTask model + TaskStore (tasks.json, tolerant decode, column ordering)
- [x] Plan-first prompt protocol (PLAN.md checklist + STATUS contract) + portable export prompt
- [x] Proxy task mode: X-CodexSwap-Task-Accounts subset selection/rotation, active alias untouched
- [x] TaskRunner: sandboxed codex exec (workspace-write, never danger), isolated CODEX_HOME, per-run logs, 6h backstop
- [x] AppEngine scheduler: quota-driven tick, pausedQuota resume, per-task account override, banked-window gate, usage-refresh retry
- [x] Kanban board window (To Do / In Queue / In Progress / Done, drag-drop, editor, export, run/stop, status indicators)
- [x] Menu-bar indicator + task notifications + Automation settings section
- [x] Unit tests (24 new; suite 87 green)
- [x] Live E2E through the packaged app on a scratch repo

## Packaging
- [x] .app bundle + ad-hoc code sign (Scripts/build-app.sh); notarize pending (needs Developer ID)
- [ ] Distribution (brew cask / release)

## Task Board v2 (2026-07-14)

- [x] Wave 1 — engine correctness: outcome reducer, completion gate, typed retries, auto-replan, repo lease (PR #12)
- [x] Wave 1b — native collab subagent contract in task prompts (PR #13)
- [x] Wave 2 — run-scoped proxy routing and quota events (PR #14)
- [x] Wave 3 — structured telemetry, headroom admission, model fallback, bounded history (PR #18)
- [x] Wave 4 — context lifetime: Handoff, WORKLOG, evergreen cycles, verification receipts (PR #16)
- [x] Wave 5 — board cockpit: inspector, live log, reasons, recovery actions, filters (PR #15)
- [x] Wave 6 — changes review, attribution, lane policy, archive, duplicate, notifications (PR #17)
- [x] Wave 7 — final adversarial audit, hardening (PRs #19, #20), live E2E on deployed build, docs/screenshot sync
