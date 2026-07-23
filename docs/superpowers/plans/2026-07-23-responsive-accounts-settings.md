# Responsive Accounts Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Accounts Settings vertically scrollable and keep every account control readable and usable when the window is narrow.

**Architecture:** Add a small presentation policy in `SwapKit` that selects wide or compact account-row layout from the available detail width. `AccountsSettingsView` reads its rendered width, owns the vertical scroll container, and delegates each account to a wide or compact composition built from shared identity and control subviews.

**Tech Stack:** Swift 6, SwiftUI, AppKit hosting, XCTest, macOS 14

---

### Task 1: Add a testable account-row layout policy

**Files:**
- Modify: `Sources/SwapKit/SettingsPresentation.swift`
- Test: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write the failing boundary test**

Add this test to `SettingsInformationArchitectureTests`:

```swift
func testAccountRowsUseCompactLayoutBelowWideControlRequirement() {
    XCTAssertEqual(AccountSettingsLayoutPresentation.rowLayout(availableWidth: 919), .compact)
    XCTAssertEqual(AccountSettingsLayoutPresentation.rowLayout(availableWidth: 920), .wide)
    XCTAssertEqual(AccountSettingsLayoutPresentation.rowLayout(availableWidth: 1_200), .wide)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```sh
rtk proxy swift test --filter SettingsInformationArchitectureTests/testAccountRowsUseCompactLayoutBelowWideControlRequirement
```

Expected: compilation fails because `AccountSettingsLayoutPresentation` does not exist.

- [ ] **Step 3: Implement the minimal presentation policy**

Add this beside `AccountRoutingPresentation`:

```swift
public enum AccountSettingsRowLayout: Sendable, Equatable {
    case wide
    case compact
}

public enum AccountSettingsLayoutPresentation {
    public static let wideRowMinimumWidth: CGFloat = 920

    public static func rowLayout(availableWidth: CGFloat) -> AccountSettingsRowLayout {
        availableWidth >= wideRowMinimumWidth ? .wide : .compact
    }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the same filtered command. Expected: one test passes with zero failures.

- [ ] **Step 5: Commit the layout policy**

```sh
rtk git add Sources/SwapKit/SettingsPresentation.swift Tests/SwapKitTests/SwapKitTests.swift
rtk git commit -m "test(settings): define responsive account layout"
```

### Task 2: Add scrolling and adaptive account rows

**Files:**
- Modify: `Sources/CodexSwapApp/AccountsSettingsView.swift`

- [ ] **Step 1: Make the complete pane vertically scrollable**

Wrap the existing pane content in a width-reading root:

```swift
GeometryReader { proxy in
    ScrollView {
        content(
            rowLayout: AccountSettingsLayoutPresentation.rowLayout(
                availableWidth: proxy.size.width
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
    }
}
```

Move the existing description, `SettingsSection`, footer buttons, and CodexBar
notice into:

```swift
private func content(rowLayout: AccountSettingsRowLayout) -> some View {
    VStack(alignment: .leading, spacing: 16) {
        Text("CodexBar manages account credentials when available. CodexSwap imports its roster automatically.")
            .foregroundStyle(.secondary)

        SettingsSection(title: "Accounts") {
            if model.presentation.accounts.isEmpty {
                ContentUnavailableView(
                    "No Accounts",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Add an account through CodexBar or use the standalone fallback.")
                )
            } else {
                ForEach(model.presentation.accounts) { account in
                    AccountSettingsRowView(
                        account: account,
                        model: model,
                        layout: rowLayout
                    )
                    if account.id != model.presentation.accounts.last?.id {
                        Divider()
                    }
                }
            }
        }

        HStack {
            Button("Add in CodexBar…", action: model.actions.openCodexBar)
                .disabled(!model.codexBarInstalled)
                .accessibilityLabel("Open CodexBar to add an account")
            Button("Add Standalone…", action: model.actions.addStandaloneAccount)
                .accessibilityLabel("Add a standalone Codex account")
            Button("Rescan Accounts", action: model.actions.importAccounts)
        }

        if !model.codexBarInstalled {
            Label(
                "CodexBar is not installed. Standalone login remains available.",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
```

Pass `rowLayout` into every `AccountSettingsRowView`.

- [ ] **Step 2: Split the account row into shared subviews**

Add `layout: AccountSettingsRowLayout` and select the composition:

```swift
@ViewBuilder
var body: some View {
    switch layout {
    case .wide:
        wideRow
    case .compact:
        compactRow
    }
}
```

Keep these shared pieces:

```swift
private var identity: some View {
    HStack(alignment: .top, spacing: 12) {
        accountStatusImage
        accountDetails
    }
}

private var priorityControl: some View {
    Stepper(
        "Priority: \(account.priority)",
        value: priorityBinding,
        in: AccountPriority.allowedValues
    )
    .fixedSize()
}
```

Extract the current activation/routing decision into `activationControl`, the
enabled-account disable action into `routingControl`, and the reset/manage or
remove buttons into `secondaryActions`. Preserve their existing bindings,
disabled states, help, accessibility labels, and confirmation dialog.

- [ ] **Step 3: Compose wide and compact rows**

Use the existing desktop order in the wide row:

```swift
private var wideRow: some View {
    HStack(alignment: .top, spacing: 12) {
        identity
            .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
        priorityControl
        activationControl
        routingControl
        secondaryActions
    }
}
```

Use readable stacked controls in the compact row:

```swift
private var compactRow: some View {
    VStack(alignment: .leading, spacing: 12) {
        identity
        HStack(spacing: 12) {
            priorityControl
            Spacer()
            activationControl
        }
        HStack(spacing: 12) {
            routingControl
            secondaryActions
        }
    }
}
```

Make account metadata a joined, wrapping line rather than several competing
single-line `Text` views. Keep routing/sign-in warnings on their own orange line
so compact rows remain understandable.

- [ ] **Step 4: Build the application target**

Run:

```sh
rtk proxy swift build --target CodexSwapApp
```

Expected: build succeeds.

- [ ] **Step 5: Commit the SwiftUI repair**

```sh
rtk git add Sources/CodexSwapApp/AccountsSettingsView.swift
rtk git commit -m "fix(settings): make account rows responsive"
```

### Task 3: Verify and install the repair

**Files:**
- Modify: `docs/superpowers/plans/2026-07-23-responsive-accounts-settings.md`

- [ ] **Step 1: Run automated gates**

```sh
rtk git diff --check
rtk proxy swift test
rtk proxy swift build --target CodexSwapApp
rtk bash Scripts/test-release-tools.sh
rtk proxy env BUILD_NUMBER=4 Scripts/build-app.sh
rtk proxy codesign --verify --deep --strict --verbose=2 dist/CodexSwap.app
```

Expected: all commands exit zero and the full suite has zero failures.

- [ ] **Step 2: Back up and replace the installed app**

Preserve the installed bundle and mode-`0600` state files under
`/Users/vjmabansag/Applications/CodexSwap-backups/`, terminate CodexSwap
normally, move the old bundle intact into rollback storage, copy build 4 into
`/Applications`, and relaunch it. Do not invoke reset, warm-up, routing, or
account-management controls.

- [ ] **Step 3: Verify native constrained-window behavior**

Using read-only Mac UI control:

1. Open Accounts Settings.
2. Resize to the minimum supported window.
3. Confirm compact rows display complete action labels.
4. Scroll from the first account through the footer buttons.
5. Widen the window and confirm the desktop row presentation returns.
6. Confirm account count, enabled/paused counts, routing state, automatic-reset
   state, and Launch at Login are unchanged.

- [ ] **Step 4: Record evidence and commit**

Update this plan with the test count, build number, codesign result, installed
hashes, scroll/compact/wide UI evidence, rollback paths, and unchanged live
settings. Then:

```sh
rtk git add docs/superpowers/plans/2026-07-23-responsive-accounts-settings.md
rtk git commit -m "docs(settings): record responsive UI verification"
rtk git push origin fix/routing-preserve-history
```
