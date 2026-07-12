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

## Packaging
- [x] .app bundle + ad-hoc code sign (Scripts/build-app.sh); notarize pending (needs Developer ID)
- [ ] Distribution (brew cask / release)
