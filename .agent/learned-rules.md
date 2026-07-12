# Learned Rules — CodexSwap

## Codex / auth
1. Stock Codex caches auth in memory; mid-session `auth.json` swap does NOT take effect (401-reload skips on `account_id` mismatch). Seamless switching requires a proxy, not file-swapping.
2. To route Codex through the proxy: `codex <subcommand> -c chatgpt_base_url="http://127.0.0.1:PORT/backend-api" -c 'model_providers.codexswap={ name="CodexSwap", base_url="http://127.0.0.1:PORT/backend-api/codex", wire_api="responses", requires_openai_auth=true }' -c model_provider="codexswap"`.
3. The `-c` overrides are honored ONLY when placed AFTER the subcommand token (`codex exec -c …`). Before the subcommand (via posix_spawn) Codex silently falls back to `provider: openai`. `CodexLauncher.launchArgs` splices config args after the subcommand for this reason.
4. `chatgpt_base_url` must be a quoted TOML string value.
5. Access-token JWT `exp` is a **string**, and email lives under the `https://api.openai.com/profile` claim (not top-level `email`). Parse `exp` as Int|Double|String or staleness misfires and every request force-refreshes.

## Token lifecycle
6. Refresh tokens are single-use/rotating. Only ONE tool may own refresh for an account, or the loser gets "refresh token already used". CodexSwap is the sole owner; codex-auth was removed from this machine.
7. On import, when merging a duplicate account, keep the token bundle with the later JWT expiry so a stale on-disk copy never clobbers a fresher live one.

## CodexBar coexistence
11. CodexBar (com.steipete.codexbar) manages accounts with per-account CODEX_HOME dirs at `~/Library/Application Support/CodexBar/managed-codex-homes/<uuid>/auth.json`, mapped by email/providerAccountID in `managed-codex-accounts.json` (version 3). It keeps these tokens fresh. CodexSwap reuses them: import sets `managedHomePath`; the proxy hydrates the freshest token from that home per request; on our own refresh we write the rotated tokens BACK to the managed home so CodexBar stays in sync. This revives accounts whose `~/.codex/accounts/` copies went stale and gives correct per-account usage. Requires CodexBar installed/running; degrade gracefully when absent.

## Usage API
8. `wham/usage` and friends are undocumented internal endpoints; poll conservatively (active account ~60s, backoff on 401) — aggressive polling risks account restrictions.

## Build
9. Swift 6 strict concurrency: no shared non-Sendable statics (formatters, JSONEncoder/Decoder) — use computed factories.
10. Don't block the Swift concurrency executor with `Process.waitUntilExit()` while a NIO proxy Task must serve — await via `terminationHandler` + continuation.
