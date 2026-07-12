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

## Layout

- `Sources/SwapKit` — core engine: account store, rotation, JWT/identity, usage client, token refresher, and the SwiftNIO proxy.
- `Sources/swapd` — headless CLI for the engine (import/list/usage/priority/switch/proxy/run).
- `Sources/CodexSwapApp` — the macOS menu-bar app (in progress).

## Development

```
swift build
swift test
swift run swapd import        # detect + import accounts
swift run swapd list          # show accounts, priority, usage, cooldowns
swift run swapd run -- exec "…"   # launch codex through the proxy
```

Set `CODEXSWAP_VERBOSE=1` to log proxy request routing. macOS-only.
