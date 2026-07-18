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

Without CodexBar, choose **Add Standalone…**, finish the standard `codex login` flow, then rescan. Do not copy an `auth.json` file into an issue or support message.

## An account says sign-in is required

Refresh or sign in through the application that owns the account. For a CodexBar-managed account, use CodexBar. For a standalone account, run the standard Codex login flow and rescan. Removing an account from CodexSwap does not revoke its OpenAI session.

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
