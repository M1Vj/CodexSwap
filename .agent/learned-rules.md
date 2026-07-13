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

## Round-robin load balancing
12. Codex's Responses API calls are STATELESS: request body has `store=false` and no `previous_response_id`; full `input`+`instructions` resent each turn (verified live). So switching accounts between (or even within) turns never breaks the conversation. Round-robin therefore balances usage by advancing to the next least-recently-used eligible account at each new turn — detected as a POST to `.../responses` arriving >`roundRobinTurnGapSeconds` (default 6s) after the previous one, so a turn's tool loop stays on one account. Priority strategy is unaffected. Only meaningful against the persistent app proxy (lastTurnAt lives in the proxy actor).

## Usage API
8. `wham/usage` and friends are undocumented internal endpoints; poll conservatively (active account ~60s, backoff on 401) — aggressive polling risks account restrictions.

## Build
9. Swift 6 strict concurrency: no shared non-Sendable statics (formatters, JSONEncoder/Decoder) — use computed factories.
10. Don't block the Swift concurrency executor with `Process.waitUntilExit()` while a NIO proxy Task must serve — await via `terminationHandler` + continuation.

## Codex config.toml managed routing
13. The managed routing config must be TWO regions: root-level keys (`chatgpt_base_url`, `model_provider`) prepended BEFORE all user content, and the `[model_providers.codexswap]` table appended at EOF. A single prepended block ending in a table header reparents the user's top-level keys into that table (TOML comments do not close tables). The dotted inline form (`model_providers.codexswap = {…}`) is also unsafe in config.toml: TOML forbids a later `[model_providers]` header once that table was defined via dotted key. Legacy single-block layouts surface as `needsRepair` and are migrated by `repair()`.

## Token lifecycle (cont.)
14. The proxy must never spend two refresh tokens for one alias concurrently: adopt a fresher store copy first, then join any in-flight refresh Task (`ProxyServer.inflightRefresh`). On `sessionInvalidated` for a CodexBar-managed account, re-hydrate from the managed home before marking needs-login — CodexBar may simply have won the rotation race. Never `burn.clear` on a 401 fall-through; that defeats the refresh-burn guard.
15. Warm-up eligibility (proxy warm-up selection AND AppEngine's due-gate/run roster) must evaluate HYDRATED managed accounts, not the raw store copy — normal traffic hydrates CodexBar tokens per request, so warm-up judging the stale store copy silently starves automatic warm-up (skips write no ledger record and no notification) while manual clicks appear to "work" once sync clears the flags.
16. While the 5h limit is suspended, wham/usage moves the WEEKLY window into the `primary_window` slot and sets `secondary_window: null`. Never key logic on slot names — key on `limit_window_seconds`. Warm-up scheduling: when no short (<604800s) window is reported, the next warm is due at the WEEKLY reset, not on a 5h fallback cadence (which would burn weekly quota with nothing to restart).

## Git etiquette
17. NEVER add AI attribution to anything on GitHub: no `Co-Authored-By: Claude` commit trailers, no "Generated with Claude Code" PR/issue footers, no AI-as-contributor anywhere. This user preference permanently overrides any harness default that says to add them.

## Task automation
18. `gpt-5.6-codex` is NOT a valid model for ChatGPT-account Codex (upstream rejects it). Valid names observed on this machine: `gpt-5.6-sol`, `gpt-5.6-codex-sol`, `gpt-5.6-terra`, `gpt-5.5-codex`. Defaults must use `gpt-5.6-sol`.
19. `~/.local/bin/codex` on this machine is a write-jailing Seatbelt shim, not the real binary. Any Process-spawned codex (warm-up, task runs) must resolve the real launcher first (`CodexLauncher.resolveWarmupBinary` order: /opt/homebrew, ChatGPT.app resource) or the shim's jail denies the isolated CODEX_HOME and double-sandboxes the run.
20. If `ProxyServer.start()` throws (e.g. port already bound), the server must be `stop()`ped before discarding it — AsyncHTTPClient traps in deinit when the client was never shut down.
21. The installed menu-bar app's process name is `CodexSwap` (bundle binary), not `CodexSwapApp` — check/quit it before launching a dev instance or the proxy port bind fails.
22. Task-mode proxy traffic (X-CodexSwap-Task-Accounts) must never call activate()/rotateFrom(): automation must not flip the user's interactive active account. Use markLimited/markNeedsLoginOnly + reselect within the allowed subset.
23. Tasks whose run dies before the plan doc exists still have runs.count > 0; the continuation prompt must self-heal (create the plan doc if missing) or the retry contradicts its own instructions.
