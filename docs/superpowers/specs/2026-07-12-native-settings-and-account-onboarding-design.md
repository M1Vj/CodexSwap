# Native Settings and Account Onboarding Design

## Goal

Make CodexSwap easier to understand and operate by keeping its menu-bar menu focused on live status and immediate actions, while moving persistent configuration, account onboarding, and maintenance into a native macOS Settings window.

## Design Principles

- The menu answers whether routing is working, which account is active, and what immediate action is available.
- Settings owns configuration that persists between launches.
- CodexBar remains the preferred owner for multi-account authentication when installed.
- CodexSwap retains a clearly labeled standalone login fallback.
- CodexSwap does not write CodexBar's private managed-account roster.
- Existing proxy, rotation, import, and warm-up behavior remains intact.

## Menu-Bar Menu

The primary menu contains, in order:

1. Proxy/routing status and active account.
2. Account rows for immediate switching.
3. Refresh Usage and Warm Quota Windows actions.
4. Settings with the standard Command-Comma shortcut.
5. Quit CodexSwap.

Rotation strategy, routing toggles, notification toggles, Launch at Login, account onboarding, account importing, and shim maintenance move out of the primary menu.

## Settings Window

CodexSwap adds one native, single-instance settings window with four panes.

### General

- Route Codex through CodexSwap.
- Launch at Login.
- Rotation strategy.
- Routing health or repair state when relevant.

### Accounts

- List imported accounts and identify each as CodexBar-managed or standalone.
- Show the active account, priority, usage state, and sign-in health.
- Allow switching, priority changes, removal, and rescanning/importing.
- Primary onboarding action: Open CodexBar to Add Account.
- Fallback onboarding action: Add Standalone Account.

Opening CodexBar activates the application and displays concise guidance because CodexBar 0.42.0 has no supported URL scheme, CLI subcommand, Apple event, or distributed action for opening its Add Account flow. CodexSwap continues watching CodexBar's managed roster and imports an account when CodexBar adds it.

If CodexBar is unavailable, the primary action is disabled or replaced by an installation explanation, while Add Standalone Account remains available. The standalone flow uses the current `codex login` behavior and tells the user to rescan afterward.

### Automation

- Automatically warm all accounts.
- Manual warm-up status and last-run summary.
- Notifications for account rotation, exhaustion, and quota resets.

### Advanced

- Proxy address and current listener state.
- Repair routing configuration when required.
- Install or uninstall the optional `codexswap` shim.
- Explain that the shim launches Codex through the proxy from Terminal and is generally unnecessary when automatic routing is enabled.

## Architecture

The existing AppKit `NSStatusItem`, menu construction, and `AppEngine` remain in place. A settings-window coordinator owns an `NSWindow` hosting a SwiftUI settings view. A shared observable view model translates engine snapshots and settings into UI state and exposes actions back to the existing engine.

This hybrid approach avoids rewriting the stable status-item lifecycle while enabling native forms, toggles, picker controls, account rows, and standard Settings-window behavior.

## Error Handling

- Settings actions report failures inline when practical and use system alerts for blocking errors.
- Opening CodexBar never mutates its storage; missing installation is explained clearly.
- Standalone login retains current binary discovery and reports when the Codex executable is unavailable.
- Shim install/uninstall reports its exact path and whether the operation succeeded.
- Routing repair remains deliberate and reversible.

## Verification

- Unit-test view-model state derivation and action routing without opening windows.
- Test CodexBar presence detection and standalone fallback labeling.
- Test shim status, install, and uninstall behavior using temporary directories.
- Run the complete Swift test suite and release build.
- Launch the packaged app, confirm the Settings menu item opens a single native window, verify each pane, and confirm the status-item menu remains operational.
