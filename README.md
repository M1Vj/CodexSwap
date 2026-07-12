# CodexSwap

Seamless multi-account switching for the OpenAI Codex CLI on macOS. Rotate between multiple ChatGPT Plus accounts **without restarting Codex** — a local proxy injects the active account's credentials per request and rotates automatically when one hits its usage limit.

## Why a proxy

Stock Codex caches its auth in memory at startup and will not reload a different account mid-session (its 401-reload path skips on `account_id` mismatch). So file-swap switchers require a restart. CodexSwap instead points Codex at a loopback proxy (`chatgpt_base_url` + a custom `model_provider`). The proxy overwrites the `Authorization` and `ChatGPT-Account-Id` headers on every request with whichever account is currently active, so switching is instant and invisible to the running Codex process.

## Features

- **Auto-detect + import** the account Codex is logged in as, plus any existing account bundles under `~/.codex/accounts/`.
- **Priority ordering** — highest-priority eligible account is consumed first.
- **Round-robin** rotation as an alternative strategy.
- **Auto-switch on limit** — a `429 usage_limit_reached` disables that account until its window resets and rotates to the next eligible one, mid-session.
- **Proactive pre-switching** at configurable usage thresholds so a nearly-exhausted window doesn't waste a failed request.
- **Token refresh** handled inline (single owner of the refresh lifecycle — do not run another switcher's refresh daemon alongside it).
- Conservative usage polling of the undocumented `wham/usage` endpoint.
- **Terminal-free routing** — enable `Route Codex through CodexSwap` once in Settings to route normal Codex CLI and compatible desktop sessions through the proxy.
- **Optional quota warm-up** — automatically send one minimal request per eligible account when a new primary cycle is observed, or run `Warm all accounts now…` manually.

## Menu setup

Open the packaged CodexSwap app and choose **Settings…** (`⌘,`) from its menu-bar menu. The menu stays focused on live status, direct account switching, usage refresh, and manual quota warm-up.

Settings is organized into four panes:

- **General** — automatic Codex routing, Launch at Login, and rotation strategy.
- **Accounts** — account ownership, usage, priority, switching, onboarding, and rescanning.
- **Automation** — automatic quota warm-up and notifications.
- **Advanced** — proxy diagnostics and the optional terminal shim.

Enable **Route Codex through CodexSwap** in General. CodexSwap safely manages only its provider keys in `~/.codex/config.toml`, keeps a timestamped backup, and restores the previous values when routing is disabled. Existing Codex sessions must be restarted after enabling or disabling routing.

Enabling routing also enables **Launch at login** once so the local proxy is available after a Mac restart. Launch at login remains an independent setting and can be disabled later; when it is off, CodexSwap warns that routed Codex sessions require the app to be running.

The Automation pane contains:

- **Automatically warm all accounts** — opt-in and off by default. It sends one small, real Codex request per eligible account when the recorded 5-hour cycle becomes available.
- **Warm all accounts now…** — manually forces one request per eligible account after confirmation. The same immediate action remains in the menu-bar menu.
- A last-run summary with warmed, skipped, and failed counts.

Warm-up requests consume a small amount of quota. Usage polling alone does not start a quota window, and OpenAI does not publicly guarantee that one request starts every displayed window. CodexSwap therefore refreshes usage after each successful warm-up and reports the reset data actually returned by the server.

If the Codex provider config is edited externally while routing is enabled, CodexSwap does not overwrite it silently. General shows **Repair Routing…** so restoration remains deliberate and reversible.

## Adding accounts

CodexBar-managed accounts are preferred. In Settings → Accounts, choose **Open CodexBar to Add Account…**, then choose Add Account in CodexBar. CodexSwap watches CodexBar's managed roster and imports the new account automatically without copying ownership away from CodexBar.

If CodexBar is unavailable, choose **Add Standalone Account…**. This opens the standard `codex login` flow; return to Settings and choose **Rescan Accounts** afterward.

## Optional terminal shim

The `codexswap` shim at `~/.local/bin/codexswap` launches Codex through the local proxy from Terminal. Automatic routing makes it unnecessary for normal use, so install or uninstall it from Settings → Advanced only when you specifically want the wrapper command.

## Layout

- `Sources/SwapKit` — core engine: account store, rotation, JWT/identity, usage client, token refresher, and the SwiftNIO proxy.
- `Sources/swapd` — headless CLI for the engine (import/list/usage/priority/switch/proxy/run).
- `Sources/CodexSwapApp` — the macOS menu-bar app.

## Development

```
swift build
swift test
swift run swapd import        # detect + import accounts
swift run swapd list          # show accounts, priority, usage, cooldowns
swift run swapd run -- exec "…"   # launch codex through the proxy
```

Set `CODEXSWAP_VERBOSE=1` to log proxy request routing. macOS-only.
