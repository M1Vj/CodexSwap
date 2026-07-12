# Native Settings and Account Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native macOS Settings window, reduce the status menu to operational actions, prefer CodexBar-managed onboarding, and move shim maintenance under Advanced.

**Architecture:** Keep the existing AppKit status item and `AppEngine`. Add a SwiftUI settings surface hosted by a single-instance `NSWindowController`, with a main-actor view model that bridges engine snapshots, persisted settings, ServiceManagement, CodexBar availability, and shim maintenance.

**Tech Stack:** Swift 6, AppKit, SwiftUI, ServiceManagement, Swift Package Manager, XCTest.

---

### Task 1: Add testable account ownership and shim maintenance services

**Files:**
- Create: `Sources/SwapKit/AccountOwnership.swift`
- Create: `Sources/SwapKit/ShimManager.swift`
- Modify: `Sources/SwapKit/CodexBarBridge.swift`
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing ownership and shim tests**

Add tests that create temporary managed homes, assert `AccountOwnership.classify(account:)` returns `.codexBarManaged` only for accounts carrying a managed home, and assert `ShimManager` reports absent, installs the exact `RuntimeHandoff.shimScript()` with mode `0755`, then uninstalls it.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `rtk swift test --filter 'AccountOwnershipTests|ShimManagerTests'`

Expected: compilation fails because the new types do not exist.

- [ ] **Step 3: Implement the minimal services**

Define:

```swift
public enum AccountOwnership: String, Sendable {
    case codexBarManaged
    case standalone

    public static func classify(account: Account) -> Self {
        account.managedHomePath == nil ? .standalone : .codexBarManaged
    }
}

public struct ShimManager: Sendable {
    public let url: URL
    public func isInstalled() -> Bool
    public func install() throws
    public func uninstall() throws
}
```

Use atomic writes, create `~/.local/bin` with mode `0700`, set the shim to `0755`, and remove only the configured shim path.

- [ ] **Step 4: Run focused tests**

Run: `rtk swift test --filter 'AccountOwnershipTests|ShimManagerTests'`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

Run: `rtk git add Sources/SwapKit Tests/SwapKitTests && rtk git commit -m 'feat: add settings support services'`

### Task 2: Add the settings view model and action boundary

**Files:**
- Create: `Sources/CodexSwapApp/SettingsViewModel.swift`
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`

- [ ] **Step 1: Define one settings action boundary**

Create `SettingsActions` closures for refresh, switch, priority, remove, routing, repair, strategy, warm-up, import, CodexBar launch, standalone login, shim install/uninstall, and launch-at-login changes. This keeps SwiftUI independent of `AppDelegate` selectors.

- [ ] **Step 2: Implement observable state**

Create a `@MainActor @Observable` view model exposing:

```swift
var snapshot: EngineSnapshot
var settings: Settings
var codexBarInstalled: Bool
var shimInstalled: Bool
var message: String?
```

Provide `update(snapshot:settings:)` so every existing engine event refreshes both the menu and an open settings window.

- [ ] **Step 3: Build to validate actor isolation**

Run: `rtk swift build`

Expected: build completes without actor-isolation warnings or errors.

- [ ] **Step 4: Commit**

Run: `rtk git add Sources/CodexSwapApp && rtk git commit -m 'feat: add settings state bridge'`

### Task 3: Build the native Settings window

**Files:**
- Create: `Sources/CodexSwapApp/SettingsView.swift`
- Create: `Sources/CodexSwapApp/SettingsWindowController.swift`

- [ ] **Step 1: Implement a single-instance window coordinator**

Use `NSHostingController(rootView:)` inside an `NSWindow` titled `CodexSwap Settings`, with minimize and zoom disabled. Reuse and activate the same window on subsequent `show()` calls.

- [ ] **Step 2: Implement four settings panes**

Build a sidebar `NavigationSplitView` with stable pane identifiers:

```swift
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, accounts, automation, advanced
}
```

General contains routing, repair, Launch at Login, and rotation strategy. Accounts contains ownership badges, usage, active state, priorities, remove/rescan, `Open CodexBar to Add Account…`, and `Add Standalone Account…`. Automation contains quota warm-up and notifications. Advanced contains proxy diagnostics plus shim explanation and Install/Uninstall.

- [ ] **Step 3: Make onboarding behavior explicit**

When CodexBar is installed, activate `/Applications/CodexBar.app`, show `In CodexBar, choose Add Account. CodexSwap will import it automatically.`, and keep the roster watcher authoritative. When unavailable, disable that button and keep standalone login enabled.

- [ ] **Step 4: Build the UI**

Run: `rtk swift build`

Expected: build completes.

- [ ] **Step 5: Commit**

Run: `rtk git add Sources/CodexSwapApp && rtk git commit -m 'feat: add native settings window'`

### Task 4: Slim the status menu and connect Settings

**Files:**
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`

- [ ] **Step 1: Add the Settings command**

Add `Settings…` with selector `showSettings`, key equivalent `,`, and Command modifier. Ensure it appears immediately above Quit.

- [ ] **Step 2: Remove persistent configuration from the menu**

Remove rotation strategy, Import Accounts, Add Account, shim installation, routing toggle, Notifications, automatic warm-up toggle, and Launch at Login from `rebuildMenu()`. Keep status, account switching, Refresh Usage, manual Warm Quota Windows, Settings, and Quit.

- [ ] **Step 3: Connect all settings actions**

Move reusable action logic out of selector-only functions so menu selectors and SwiftUI closures call the same async operations. Update the settings view model after every `refreshSnapshot()`.

- [ ] **Step 4: Run the complete tests and build**

Run: `rtk summary swift test`

Expected: all tests pass.

Run: `rtk swift build -c release`

Expected: release build completes.

- [ ] **Step 5: Commit**

Run: `rtk git add Sources/CodexSwapApp && rtk git commit -m 'feat: streamline the status menu'`

### Task 5: Document, package, and verify the installed app

**Files:**
- Modify: `README.md`
- Modify: packaging inputs only if the existing packaging script requires new resources

- [ ] **Step 1: Update user documentation**

Document the compact menu, four Settings panes, CodexBar-first onboarding, standalone fallback, and why the shim is optional.

- [ ] **Step 2: Run static and test verification**

Run: `rtk summary swift test`

Expected: all tests pass.

Run: `rtk swift build -c release && rtk git diff --check`

Expected: release build succeeds and diff check is clean.

- [ ] **Step 3: Package and install reversibly**

Use the repository packaging script to build `dist/CodexSwap.app`, ad-hoc sign it, preserve the current `/Applications/CodexSwap.app` in `/tmp`, replace it, and relaunch cleanly so the fixed proxy port is not retained by an old process.

- [ ] **Step 4: Verify runtime behavior**

Confirm the installed signature, listener on `127.0.0.1:58432`, a single settings window on repeated Settings selections, pane navigation, CodexBar activation guidance, and shim status behavior.

- [ ] **Step 5: Commit**

Run: `rtk git add README.md && rtk git commit -m 'docs: explain native settings workflow'`
