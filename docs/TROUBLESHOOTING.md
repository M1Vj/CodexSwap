# Troubleshooting

## CodexSwap is not in the Dock

CodexSwap is a menu-bar application. Look for the circular-arrow icon in the macOS menu bar. Open `/Applications/CodexSwap.app` again if it is not running.

## Routed Codex requests cannot connect

Open CodexSwap before starting Codex. In **Settings → General**, confirm that routing is enabled and in **Advanced** confirm that the proxy reports `127.0.0.1:58432`. Enable **Launch CodexSwap at Login** if routed sessions should work immediately after signing in to the Mac.

Existing Codex sessions must be restarted once after routing is enabled or disabled because they load provider configuration at startup.

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

## Quota information looks stale

Choose **Refresh Usage** from the menu. Usage polling reads the service's current quota response but does not itself start a quota timer. Optional warm-up makes a real request and consumes a small amount of quota; it cannot guarantee how OpenAI will represent every five-hour or weekly reset window.

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
