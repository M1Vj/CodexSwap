# Automatic Routing and Quota Warm-Up Design

## Objective

Make CodexSwap usable without typing `codexswap` for every session. The menu-bar app will offer persistent, reversible routing for normal Codex clients and optional quota-window warm-up across all eligible accounts.

## Current behavior

CodexSwap starts a loopback proxy on a random port and writes that URL to its application-support directory. The installed `codexswap` shell shim reads the URL and supplies per-launch Codex configuration overrides. Normal `codex` commands and Codex desktop sessions do not use the proxy automatically.

The engine polls the undocumented ChatGPT usage endpoint for the active account every 60 seconds. `Refresh usage now` polls all accounts. These status requests do not make model calls and cannot be treated as starting a five-hour or weekly usage window.

## Research findings

- Current Codex configuration supports user-level `chatgpt_base_url`, `model_provider`, and custom `model_providers` entries in `~/.codex/config.toml`.
- Provider and authentication-routing keys must live in user-level configuration; project `.codex/config.toml` files cannot override them.
- Current Codex profiles are explicit launch-time overlays. They cannot be selected persistently from the base configuration, so a profile alone cannot implement automatic routing.
- Official Codex source implements quota status as `GET /wham/usage`. No public or source-supported quota-start ping exists.
- OpenAI does not document a guarantee that one request starts both the five-hour and weekly windows. CodexSwap must report observed reset data rather than claim an unverified timer transition.

Primary references:

- [Codex advanced configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)
- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Official Codex rate-limit status client](https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client/rate_limit_resets.rs)
- [Using Codex with a ChatGPT plan](https://help.openai.com/en/articles/11369540-codex-and-chatgpt-plan-usage-limits)

## Menu design

The main menu gains:

- `Route Codex through CodexSwap` — a checkable item reflecting verified configuration state.
- Existing `Launch at login` remains independently checkable.
- `Quota windows` submenu:
  - `Automatically warm all accounts` — persistent, opt-in, off by default.
  - `Warm all accounts now…` — manual action with confirmation.
  - A disabled last-result row such as `Last warm-up: 3 warmed · 1 skipped · 12m ago`.

Enabling automatic routing enables launch at login once. The user may later disable launch at login without disabling routing. When routing is active but launch at login is off, the menu displays `⚠ Routing requires CodexSwap to be running`.

The first enablement of automatic warm-up explains that each warm-up is a genuine Codex request and consumes a small amount of quota. Manual warm-up always confirms before sending requests.

## Persistent routing architecture

### Stable proxy address

The proxy binds only to `127.0.0.1` on a stable, app-owned high port. A stable port keeps existing Codex clients connected across an app restart and allows durable user-level configuration. If the port is occupied, CodexSwap leaves the Codex configuration unchanged and reports the conflict.

### Configuration ownership

A focused `CodexConfigManager` owns changes to `~/.codex/config.toml`. It manages only:

- `chatgpt_base_url`
- `model_provider`
- `model_providers.codexswap`

Before the first change, it writes a timestamped full-file backup under the CodexSwap support directory and records the exact displaced values/fragments in a restoration manifest. Enabling installs a clearly marked CodexSwap-managed block. Disabling removes the managed block and restores only displaced values, preserving unrelated configuration and later unrelated edits.

Configuration writes use a same-directory temporary file followed by an atomic replacement. File permissions are preserved. A malformed or ambiguous config is rejected without mutation.

The manager exposes a verified state rather than trusting the app setting alone:

- `disabled`
- `enabled`
- `needsRepair(reason)`

If the user or another tool replaces the provider while CodexSwap is enabled, startup does not silently overwrite that choice. The menu shows `Routing needs repair`; explicit re-enablement is required.

### Lifecycle

On application startup, CodexSwap binds the stable port and verifies routing state. If routing is enabled and intact, no config write occurs. On enablement it writes the routing config, enables launch at login, and asks the user to restart existing Codex sessions. On disablement it restores the prior provider settings and leaves launch-at-login unchanged.

## Quota warm-up architecture

### Why a real Codex request is required

Usage polling only observes server state. Warm-up therefore performs one minimal real Codex response request for each target account. The feature never labels a status poll as a successful warm-up.

### Forward-compatible request construction

`QuotaWarmupService` launches the installed Codex binary as a hidden, non-interactive subprocess for each account. Codex constructs its own current wire payload. The subprocess runs in an isolated temporary `CODEX_HOME` and empty working directory with ephemeral/read-only behavior, no repository context, and a fixed minimal prompt.

The temporary provider configuration points at an account-scoped loopback route and uses a disposable local credential value. The proxy strips the internal account selector before forwarding, replaces authentication headers with the selected account credentials, and never exposes the selector externally. The account-scoped route is accepted only on the loopback listener.

Warm-ups run sequentially. They do not change `activeAlias`, do not trigger round-robin advancement, and do not fail over to a different account. A warm-up failure therefore remains attributed to the intended account.

### Eligibility and scheduling

The service skips accounts that:

- need login;
- have no usable access or refresh credential;
- are in a known cooldown; or
- were already warmed for the currently recorded primary cycle.

Automatic warm-up runs after startup reconciliation and usage refresh, then continues from the existing poll loop. A per-account ledger records the last successful request time and the primary/secondary reset timestamps observed afterward. An account becomes eligible again only after the recorded primary window resets or the server reports a newer cycle. Restarting the app does not repeat a warm-up in the same recorded cycle.

When the app was not running at reset time, the next launch performs the overdue warm-up. The scheduler uses bounded retry delays for transient failures and never retries authentication, invalid-account, or usage-limit failures in a tight loop.

Manual warm-up bypasses the automatic schedule but still applies account eligibility and never sends duplicate concurrent requests. Its completion report distinguishes warmed, skipped, and failed accounts.

### Verification semantics

A successful model response means only that the warm-up request succeeded. CodexSwap immediately refreshes usage for that account and stores the server-observed window percentages and reset times. The UI does not promise that both timers started when the server does not expose evidence of that transition.

## Failure handling

- Stable-port conflict: proxy remains off, routing config is not enabled, and the notification identifies the occupied port.
- Config parse or write failure: original bytes remain intact and routing reports `needsRepair`.
- External provider change: CodexSwap preserves it and requires explicit repair.
- Missing Codex binary: routing continues to work, but warm-up reports that the binary is unavailable.
- Warm-up timeout or nonzero exit: terminate the isolated subprocess, capture a redacted diagnostic, and continue with the next account.
- Account 401: run the existing token-refresh path once; if invalidated, mark that account as needing login.
- Account 429: record the returned cooldown/reset without rotating or warming another account on its behalf.
- App termination: cancel pending automatic warm-ups and remove temporary warm-up directories.

Diagnostics never include access tokens, refresh tokens, authorization headers, raw account files, or user prompt history.

## Testing and verification

Unit tests cover:

- settings migration defaults for routing and warm-up fields;
- stable proxy configuration and port-conflict behavior;
- enabling, disabling, restoration, atomicity, malformed TOML, and external-edit detection;
- account-scoped routing without active-account mutation or round-robin advancement;
- warm-up eligibility, cycle deduplication, sequential execution, retry boundaries, and result summaries;
- menu state for enabled, disabled, warning, and repair conditions.

Integration tests use temporary Codex homes, temporary config files, a fake Codex executable, and mock upstream responses. They verify subprocess arguments and environment without sending real model requests.

Final verification includes `swift test`, a release build, packaged-app launch, menu interaction, launch-at-login toggling, routing through a fresh Codex session, disable/restore behavior, and a user-authorized live warm-up smoke test on at most one account before enabling automation for all accounts.

## Non-goals

- Automatically enabling full-access Codex permissions.
- Claiming undocumented OpenAI quota-window guarantees.
- Binding the proxy beyond loopback.
- Modifying project-local Codex configuration.
- Replacing the normal `codex` executable.
