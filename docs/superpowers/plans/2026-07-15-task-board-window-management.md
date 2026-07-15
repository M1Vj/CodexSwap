# Task Board Window Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native full-screen, macOS Space-safe placement persistence, and physical-display movement to the single existing Task Board window without affecting task state.

**Architecture:** `SwapKit` owns deterministic frame geometry; `TaskBoardWindowController` converts that geometry to AppKit operations and defers moves requested during full screen; `TaskBoardView` exposes the actions through one compact native menu. The existing `TaskBoardViewModel` remains the only task-state owner.

**Tech Stack:** Swift 5/6-compatible code, SwiftUI, AppKit, XCTest, Swift Package Manager.

---

### Task 1: Prove window placement geometry

**Files:**
- Create: `Sources/SwapKit/TaskBoardReopenPolicy.swift`
- Create: `Sources/SwapKit/TaskBoardWindowPlacement.swift`
- Create: `Tests/SwapKitTests/TaskBoardWindowPlacementTests.swift`

- [ ] **Step 1: Write failing tests for movement, fitting, recovery, and display selection**

```swift
func testMovePreservesRelativeCenterAcrossDisplays() {
    let moved = TaskBoardWindowPlacement.move(
        frame: .init(x: 200, y: 100, width: 800, height: 600),
        from: .init(x: 0, y: 0, width: 1_200, height: 800),
        to: .init(x: 1_200, y: 0, width: 1_600, height: 1_000)
    )
    XCTAssertEqual(moved.midX, 2_000, accuracy: 0.001)
    XCTAssertEqual(moved.midY, 500, accuracy: 0.001)
}

func testMoveFitsWindowInsideSmallerDisplay() {
    let target = TaskBoardWindowFrame(x: -900, y: 0, width: 900, height: 650)
    let moved = TaskBoardWindowPlacement.move(
        frame: .init(x: 0, y: 0, width: 1_400, height: 760),
        from: .init(x: 0, y: 0, width: 1_440, height: 900),
        to: target
    )
    XCTAssertTrue(target.contains(moved))
}

func testRecoverCentersFrameWhenSavedDisplayIsGone() {
    let recovered = TaskBoardWindowPlacement.recover(
        frame: .init(x: 4_000, y: 2_000, width: 900, height: 600),
        visibleFrames: [.init(x: 0, y: 0, width: 1_200, height: 800)],
        fallbackIndex: 0
    )
    XCTAssertEqual(recovered, .init(x: 150, y: 100, width: 900, height: 600))
}

func testCenterClampsOversizedWindowToVisibleFrame() {
    let visible = TaskBoardWindowFrame(x: 100, y: 50, width: 700, height: 500)
    let centered = TaskBoardWindowPlacement.center(
        frame: .init(x: 0, y: 0, width: 1_400, height: 900),
        in: visible
    )
    XCTAssertEqual(centered, visible)
}

func testNextDisplayRequiresAtLeastTwoDisplays() {
    XCTAssertNil(TaskBoardWindowPlacement.nextDisplayIndex(currentIndex: 0, displayCount: 1))
    XCTAssertEqual(TaskBoardWindowPlacement.nextDisplayIndex(currentIndex: 1, displayCount: 3), 2)
    XCTAssertEqual(TaskBoardWindowPlacement.nextDisplayIndex(currentIndex: 2, displayCount: 3), 0)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter TaskBoardWindowPlacementTests`

Expected: compilation fails because `TaskBoardWindowPlacement` and `TaskBoardWindowFrame` do not exist.

- [ ] **Step 3: Implement positive, clamped, relative frame geometry**

```swift
public struct TaskBoardWindowFrame: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(_ other: Self) -> Bool {
        other.x >= x && other.y >= y
            && other.x + other.width <= x + width
            && other.y + other.height <= y + height
    }
}

public enum TaskBoardWindowPlacement {
    public static func move(frame: TaskBoardWindowFrame, from source: TaskBoardWindowFrame, to target: TaskBoardWindowFrame) -> TaskBoardWindowFrame
    public static func center(frame: TaskBoardWindowFrame, in visibleFrame: TaskBoardWindowFrame) -> TaskBoardWindowFrame
    public static func recover(frame: TaskBoardWindowFrame, visibleFrames: [TaskBoardWindowFrame], fallbackIndex: Int) -> TaskBoardWindowFrame
    public static func nextDisplayIndex(currentIndex: Int, displayCount: Int) -> Int?
}
```

All returned widths and heights are clamped to at least `1` and at most the target visible frame. Origins are clamped so `target.contains(result)` is true. `recover` keeps a frame on the display with the largest positive intersection and centers it on the fallback display when there is no intersection.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `swift test --filter TaskBoardWindowPlacementTests`

Expected: all placement tests pass.

### Task 2: Connect native AppKit window behavior

**Files:**
- Create: `Sources/CodexSwapApp/TaskBoardWindowCommands.swift`
- Modify: `Sources/CodexSwapApp/TaskBoardWindowController.swift`

- [ ] **Step 1: Add a weak command bridge and native window capabilities**

```swift
@MainActor
final class TaskBoardWindowCommands {
    weak var controller: TaskBoardWindowController?
    func toggleFullScreen() { controller?.toggleFullScreen() }
    func moveToNextDisplay() { controller?.moveToNextDisplay() }
    func centerOnCurrentDisplay() { controller?.centerOnCurrentDisplay() }
}
```

Create the commands before the hosting controller, let the SwiftUI view retain the bridge, assign its weak controller after `super.init`, include `.miniaturizable`, insert `.fullScreenPrimary`, and use the frame autosave name `CodexSwapTaskBoardWindow`.

- [ ] **Step 2: Restore and recover a persisted frame**

After applying the initial screen-aware content size and minimum, center the window, enable `setFrameAutosaveName`, then convert the restored `NSRect` and all `NSScreen.visibleFrame` values through `TaskBoardWindowPlacement.recover`. Expand tiny stored frames to the target screen's usable minimum and immediately save the normalized result.

- [ ] **Step 3: Implement safe full-screen and display actions**

```swift
private enum PendingPlacement { case moveToNextDisplay, centerOnCurrentDisplay }

func toggleFullScreen() { window?.toggleFullScreen(nil) }

func moveToNextDisplay() {
    performAfterLeavingFullScreen(.moveToNextDisplay)
}

func windowDidExitFullScreen(_ notification: Notification) {
    performPendingPlacement()
}
```

`moveToNextDisplay` uses `NSScreen.screens` and `nextDisplayIndex`; with one display it returns without changing the frame. `centerOnCurrentDisplay` uses the current screen or `NSScreen.main`. Both apply `TaskBoardWindowSizing.resolve` to the target display and set only valid frames.

- [ ] **Step 4: Build the app target**

Run: `swift build --target CodexSwapApp`

Expected: build succeeds with no warnings from the new command bridge.

### Task 3: Add accessible board window controls

**Files:**
- Modify: `Sources/CodexSwapApp/TaskBoardView.swift`
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`

- [ ] **Step 1: Inject the command bridge without changing task actions**

```swift
struct TaskBoardView: View {
    @ObservedObject var model: TaskBoardViewModel
    let windowCommands: TaskBoardWindowCommands
}
```

Keep every existing task action bound to `model.actions`; window commands remain separate.

Add `applicationShouldHandleReopen` so reopening a windowless menu-bar app calls `showTaskBoard()`, while an already visible CodexSwap window remains unchanged.

- [ ] **Step 2: Add one compact native menu to header actions**

```swift
Menu {
    Button("Toggle Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
        windowCommands.toggleFullScreen()
    }
    Button("Move to Next Display", systemImage: "display.2") {
        windowCommands.moveToNextDisplay()
    }
    Button("Center on Current Display", systemImage: "scope") {
        windowCommands.centerOnCurrentDisplay()
    }
} label: {
    Label("Window", systemImage: "macwindow")
}
.controlSize(.small)
.help("Full screen or reposition the Task Board")
```

Place it between `Logs` and `Add Task`. Retain `ViewThatFits` so the header continues wrapping on compact displays, and align the view minimum with the existing `640 × 480` window fallback.

- [ ] **Step 3: Build and run focused board tests**

Run: `swift build --target CodexSwapApp && swift test --filter TaskBoardCockpitTests && swift test --filter TaskBoardWindowPlacementTests`

Expected: app builds and both focused suites pass.

### Task 4: Verify, release, and monitor

**Files:**
- Modify only if verification finds a defect.

- [ ] **Step 1: Run complete quality gates**

Run: `swift test`

Run: `Scripts/test-release-tools.sh`

Run: `Scripts/test-repository-config.sh`

Run: `swift build -c release`

Expected: every command exits `0`, no tests are skipped, and the release build succeeds.

- [ ] **Step 2: Commit and push conventional changes**

```bash
git add Sources/SwapKit/TaskBoardWindowPlacement.swift Tests/SwapKitTests/TaskBoardWindowPlacementTests.swift Sources/CodexSwapApp/TaskBoardWindowCommands.swift Sources/CodexSwapApp/TaskBoardWindowController.swift Sources/CodexSwapApp/TaskBoardView.swift docs/superpowers/specs/2026-07-15-task-board-window-management-design.md docs/superpowers/plans/2026-07-15-task-board-window-management.md
git commit -m "feat(board): add native window management"
git push origin main
```

- [ ] **Step 3: Rebuild and reinstall the app**

Run: `Scripts/build-app.sh`, verify the app signature, replace `/Applications/CodexSwap.app`, and launch the installed copy.

Expected: the installed process runs from `/Applications/CodexSwap.app/Contents/MacOS/CodexSwap`.

- [ ] **Step 4: Verify native behavior and isolation**

Open the board, confirm the `Window` menu is keyboard-accessible, toggle full screen, return to windowed mode, center it, reopen it, and confirm its frame persists. If multiple physical displays are connected, move it and confirm the relative position is retained. Confirm the scheduler's task counts are identical before and after all window operations.

- [ ] **Step 5: Clean and resume monitoring**

Remove `dist`, temporary app backups, and test-result artifacts; verify the repository is clean and `HEAD == origin/main`; then resume the scheduler and unified fault streams.
