# Troubleshooting

## CodexSwap is not in the Dock

CodexSwap is a menu-bar application. Look for the circular-arrow icon in the macOS menu bar. Open `/Applications/CodexSwap.app` again if it is not running.

## Routed Codex requests cannot connect

Open CodexSwap before starting Codex. In **Settings → General**, confirm that routing is enabled and in **Advanced** confirm that the proxy reports `127.0.0.1:58432`. **Launch CodexSwap at Login** is independent and never changes when routing is enabled; turn it on yourself if routed sessions should work immediately after signing in to the Mac.

Existing Codex sessions must be restarted once after routing is enabled or disabled because they load provider configuration at startup.

## Codex history disappears while routing is enabled

Earlier CodexSwap routing changed provider identity to a custom `codexswap` provider. That could hide the history belonging to the built-in `openai` provider, but it did not delete the history. Repaired routing preserves `model_provider = "openai"` and changes only model `openai_base_url`; identity and history remain on Codex's normal ChatGPT backend and stay tied to the account signed in to Codex.

Use these safe recovery steps:

1. Open **Settings → General** and read the routing status.
2. If it says repair is needed, read the displayed reason, choose **Repair Routing…**, and wait for routing to report enabled.
3. Quit and reopen Codex once so it reloads the repaired provider configuration.
4. Confirm Codex is signed in to the same account that owns the missing history.

Never copy, edit, replace, or otherwise mutate Codex history databases. Do not delete or rewrite `~/.codex`, Codex application data, or CodexSwap's support directory while troubleshooting history visibility.

## Settings says routing needs repair

CodexSwap detected that its managed block in `~/.codex/config.toml` changed outside the app. Choose **Repair Routing…** to restore the expected local endpoint. CodexSwap will not silently replace an externally edited block.

Configuration backups and the restoration manifest are stored in:

```text
~/Library/Application Support/CodexSwap/config-backups/
~/Library/Application Support/CodexSwap/routing-restore.json
```

These files may contain displaced Codex configuration and should not be shared publicly.

## No accounts appear

For CodexBar-managed accounts, open CodexBar and use **Add Account** there. Return to **Settings → Accounts** in CodexSwap; the roster is watched automatically. Choose **Rescan Accounts** if the account does not appear.

Without CodexBar, choose **Add Standalone…**, finish the Terminal login, then rescan. Each attempt uses a fresh private home; only a successful login with a valid account credential is imported. Keep the home shown by the launcher for that account's native lifecycle. Do not copy an `auth.json` file into an issue or support message.

An unreadable or malformed CodexBar roster is not treated as an empty account list. CodexSwap preserves its existing managed accounts until it can read a valid snapshot. An explicitly valid empty roster still reflects removal through CodexBar.

## An account says sign-in is required

Check the error in the application that owns the account. For a CodexBar-managed account, use CodexBar. A stored authentication flag alone does not prove a fresh provider revocation. For an isolated standalone account, use its exact Codex home, or explicitly complete a new **Add Standalone…** login and rescan. An unscoped `codex login` targets the normal native home instead. Removing an account from CodexSwap does not revoke its OpenAI session.

Do not migrate existing CodexBar accounts to standalone login expecting a guaranteed cure. Separate homes prevent shared-login replacement but do not implement background renewal. Re-adding an identity already managed by CodexBar does not silently transfer its ownership to CodexSwap.

If the account still works through its owner, choose **Rescan Accounts**. CodexSwap verifies blocked accounts against the read-only usage endpoint using that same source. A successful check can clear a stale sign-in flag even when the token's expiry has not increased. A failed check leaves the flag intact; a concurrent sign-out, pause, removal, or credential change prevents an older check from re-enabling the account. This does not refresh or repair a revoked session.

## A request reports credential renewal is required

CodexSwap does not refresh imported OAuth sessions or write their source auth files. Competing refresh writers can leave another application holding stale credentials. CodexSwap instead reads updates from the known source and checks that they belong to the same account.

If the owner has not supplied a usable update, the proxy may use an eligible alternative within the request's account scope. A targeted warm-up never changes accounts. When no alternative is available, the proxy returns HTTP 503 rather than declaring the account signed out. This does not mean your account was removed or its session was revoked.

Open the account through its existing owner so native Codex can renew it. Use **Rescan Accounts** to update older imports with source information. If the owner itself reports a revoked session, sign in there once and rescan. Do not copy auth files between homes, repeatedly force refresh, or start extra Codex processes against the same home as a workaround.

Automatic renewal still belongs to the owner; the proxy does not create a background login process. See [the credential ownership investigation](AUTH-OWNERSHIP-INVESTIGATION.md) for the verified defect, upstream evidence, and remaining limits.

For future incidents, the bounded privacy-safe routing log records authentication categories, account correlation IDs, and timestamps. Expired access tokens, generic unauthorized responses, explicit invalidation codes, owner recovery, and unavailable renewal are distinguishable; raw tokens, response bodies, and account aliases are not recorded. Native/CodexBar errors that bypass the proxy still require the owner's error message. Never paste an auth file into a report.

## An account says Routing Disabled

You paused this account in **Settings → Accounts**. The pause persists until you choose **Enable Routing**. CodexSwap retains its OAuth credentials, account record, and saved Task Board account choices.

The account cannot serve new chats, the next request on an existing interactive or Task Board run pin, an actual-429 alternative, Task Board scheduling, warm-up, or automatic reset. This administrative pause overrides a sticky pin on the next request. Percentage and quota displays still do not switch pins.

CodexSwap does not cancel a request that reached the upstream service before the pause or a Task Board runner that already started. On its next request, the proxy rebinds to an eligible account or reports that no account is eligible. The runner can remain alive while its requests use another eligible account.

You can still choose **Use Reset…** and confirm a manual reset for the paused account. Automatic reset remains opt-in and skips paused accounts. **Warm all accounts now…** also skips them.

## Quota information looks stale

Choose **Refresh Usage** from the menu. Usage polling reads the service's current quota response but does not itself start a quota timer. Optional warm-up makes a real request and consumes a small amount of quota; it cannot guarantee how OpenAI will represent every five-hour or weekly reset window.

CodexSwap does not switch because a displayed usage percentage is high and does not use idle time as a switch trigger. Active interactive turns and Task Board runs remain pinned. OpenAI's Codex protocol documents active-turn continuation state, but it does not promise continuity after stopping a turn or starting a new one.

Only a semantic upstream `usage_limit_reached` response invokes the configured exhaustion policy. Interactive Codex and Task Board policies are separate, and each can be **Reset Current First**, **Switch First**, or **Stop & Notify**. CodexSwap makes one policy decision and retries at most once for that response.

## Reset credits are unavailable or not used

Automatic reset-credit use is off until **Automatically Use Reset When Exhausted** is enabled. **Protect from Automatic Reset** blocks only automatic use; it does not disable the manual **Use Reset…** action. Manual use always presents a confirmation, and CodexSwap chooses the earliest-expiring usable credit when more than one exists.

Reset-credit access relies on an undocumented internal endpoint that may change without notice. A read or consume failure does not mean ordinary routing or account history is broken. Do not repeatedly submit a reset action after an ambiguous network failure; refresh the account state first.

## Homebrew cannot find the cask

Confirm the tap is present and update it:

```bash
brew tap M1Vj/CodexSwap https://github.com/M1Vj/CodexSwap
brew update
brew install --cask codexswap
```

The cask becomes available only after the first signed and notarized GitHub release and its generated cask update are published.

## Safe reset or uninstall

Before deleting the app, disable routing in **Settings → General** so CodexSwap restores the prior `~/.codex/config.toml` values. Then quit the app and uninstall it.

Deleting `~/Library/Application Support/CodexSwap/` removes imported account state, settings, backups, and warm-up history. It does not remove Codex, CodexBar accounts, or OpenAI sessions.

## Reporting a problem

Use the repository's bug-report template and include the CodexSwap version, macOS version, Mac architecture, and sanitized reproduction steps. Report potential credential exposure or routing vulnerabilities through [GitHub private vulnerability reporting](https://github.com/M1Vj/CodexSwap/security/advisories/new), not a public issue.

## Bridged (non-Codex) models

**Codex says a model is "not supported when using Codex with a ChatGPT account."**
The request reached OpenAI's backend instead of the bridge. For subagent roles
(`~/.codex/agents/*.toml`), pin the provider explicitly so role application cannot
lose the runtime base URL:

```toml
model_provider = "codexswap"

[model_providers.codexswap]
name = "CodexSwap"
base_url = "http://127.0.0.1:58432/backend-api/codex"
wire_api = "responses"
```

**A bridged model is not offered in Codex's model picker.**
Add it to your `model_catalog_json` overlay (`~/.codex/model-catalogs/*.json`)
with `visibility: "list"`, then restart Codex.

**Bridged requests fail with `bad_bridged_base_url`.**
The entry's Base URL in Settings → Advanced is empty or not a valid URL. It should
end at the version segment, e.g. `https://opencode.ai/zen/v1`.

**Tool calls never fire on a bridged model.**
Check that the upstream gateway emits standard Chat Completions `tool_calls` deltas;
the translator forwards them as Responses `function_call` items.

**Bridged model replies but never uses tools ("one message then stops").**
Check the proxy verbose log for `request tools=NONE`. A catalog flag can suppress
Codex's tool surface entirely — `use_responses_lite: true` on a custom catalog
entry did exactly that. Remove the flag, restart Codex, and confirm the log shows
`raw tools=N` with N > 0 and `request tools=<k>` names listed.

**Every tool call aborts or reports "exec cell not found" on a bridged model.**
`tool_mode: "code_mode_only"` in the catalog routes all tools through the JS
runtime (`node_repl`). If that runtime is not running inside your host
(IDE app-server, headless exec), every call dies regardless of translation
correctness. Remove `tool_mode` from the catalog entry to fall back to
classic shell function tools, which work through any Responses<->Chat bridge.
