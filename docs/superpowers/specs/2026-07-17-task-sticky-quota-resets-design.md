# Task-Sticky Quota Routing and Reset Controls

## Goal

Preserve an in-progress Codex task on one account, remove percentage- and idle-gap-based account switching, and give the user explicit, separate control over interactive Codex and Task Board behavior after a real quota exhaustion response.

## Evidence and design boundary

OpenAI does not document a continuation-grace entitlement. A user report indicates that an already-running task may continue after the displayed quota is consumed and lose that behavior after interruption, so CodexSwap must treat grace as observed behavior rather than an API guarantee.

Codex does document stronger request boundaries. Interactive requests carry canonical turn metadata and, after the first response, the server-issued `x-codex-turn-state` sticky-routing token. Task Board runs already carry `X-CodexSwap-Task-Run` for the lifetime of one `codex exec` process. These are the routing boundaries CodexSwap will honor.

## Routing behavior

- Never switch accounts because a usage window reaches 95%, 98%, 99%, 100%, or any other displayed percentage.
- Remove proactive percentage switching from the usage poller.
- Remove the six-second idle-gap rule as an account-switch trigger.
- Pin every interactive Codex turn to the account selected for its first model request. Use canonical turn metadata as the first-request key and `x-codex-turn-state` when available.
- Pin every Task Board `codex exec` run to its selected account until that process terminates.
- Background quota refresh may update displays and future selection, but it must never move an active turn or run.
- Account priority or round-robin selection applies only when choosing the first account for a new turn or run.
- A real upstream `usage_limit_reached` response is the only mid-task condition that may invoke the configured exhaustion action.

## Exhaustion policies

Interactive Codex and Task Board have independent settings with the same choices:

1. `resetCurrentFirst`: if automatic reset is enabled and the account is not protected, reset the current account and retry once on it; otherwise check alternatives and switch.
2. `switchFirst`: refresh eligible alternatives and switch to a freshly verified account; if none is usable, try an allowed automatic reset of the current account.
3. `stopAndNotify`: forward the exhaustion result, emit a notification, and spend no reset credit.

Defaults are conservative:

- Interactive Codex: `resetCurrentFirst`.
- Task Board: `stopAndNotify`.
- Automatic reset: off.

An automatic action is attempted at most once per exhausted request. Failure, ambiguity, `nothingToReset`, `noCredit`, or `alreadyRedeemed` triggers a fresh read of usage and reset-credit state before any fallback. CodexSwap never loops between accounts or consumes multiple credits for one request.

## Reset credits

- Read reset credits per account from the ChatGPT WHAM reset-credit endpoint.
- Model credit ID, status, grant time, expiry time, title, and description separately from usage windows.
- Select an available credit explicitly by earliest `expiresAt`; credits without expiry sort last, with stable ID as the final tie-breaker.
- Generate and persist a redemption UUID before sending a consume request. Retries reuse the same UUID.
- Never print or persist access tokens, account IDs, or credit IDs in user-facing logs.
- After a confirmed reset, refresh the account's quota and credit snapshot, clear only cooldowns contradicted by the fresh quota response, and retry the rejected request once on the same account when policy requires it.
- Never auto-redeem solely because a credit is close to expiry.

## Manual and protected behavior

- Each account row shows reset-credit availability and the earliest expiry.
- `Use Reset…` is available when a credit is usable and always opens a confirmation that names the account and expiry.
- Manual reset is allowed for a protected account because the user is explicitly confirming it.
- `Protect from Automatic Reset` blocks only automatic redemption.
- Automatic redemption requires both the global `Automatically Use Reset When Exhausted` toggle and an unprotected account.

## Settings information architecture

The sidebar contains five panes:

- **General:** model routing and Launch at Login.
- **Accounts:** account identity, active state, priority, reset-credit status, manual reset, and per-account auto-reset protection.
- **Quota & Resets:** account warm-up, global automatic-reset toggle, interactive Codex exhaustion policy, and quota notifications.
- **Task Board:** task automation enablement, allowed accounts, maximum concurrency, banked-window policy, and Task Board exhaustion policy.
- **Advanced:** proxy diagnostics and the optional terminal shim.

The current Accounts button labeled `Use` becomes `Make Active`. The active account shows a non-button `Active` status so both state and action are unambiguous.

## Failure handling

- Credit reads are read-only and may fail without blocking ordinary model routing.
- Unknown or stale alternative quota is not treated as proof that an account is usable.
- Consume timeouts are ambiguous: CodexSwap re-reads credits with the same persisted idempotency record before deciding whether a fallback is safe.
- Manual actions report `reset`, `nothingToReset`, `noCredit`, `alreadyRedeemed`, authorization failure, or network failure distinctly.
- Automatic actions notify on failure and stop after the configured single fallback path.

## Verification

- Unit tests cover settings migration/defaults, turn/run pinning, removal of threshold and idle-gap switching, credit parsing and earliest-expiry selection, idempotent consume behavior, protected-account gates, and each exhaustion-policy branch.
- Integration tests use an ephemeral proxy and fake upstream to prove one account serves a whole turn/run, displayed 100% does not switch it, and actual 429 behavior follows the selected policy without double redemption.
- UI tests or presentation tests cover the five settings panes, `Make Active` wording, manual confirmation inputs, and separate interactive/Task Board policies.
- Final gates are `swift test`, `swift build --target CodexSwapApp`, release-tool tests, app packaging, and a live ephemeral Codex request through `swapd`.

## Primary sources

- Codex turn-state routing contract: https://github.com/openai/codex/blob/315195492c80fdade38e917c18f9584efd599304/codex-rs/core/src/client.rs#L260-L286
- Codex request metadata: https://github.com/openai/codex/blob/315195492c80fdade38e917c18f9584efd599304/codex-rs/core/src/responses_metadata.rs#L210-L267
- Reset consume schema: https://github.com/openai/codex/blob/315195492c80fdade38e917c18f9584efd599304/codex-rs/app-server-protocol/schema/json/v2/ConsumeAccountRateLimitResetCreditParams.json
- Observed continuation behavior, not an official contract: https://github.com/openai/codex/issues/25937
