import XCTest
@testable import SwapKit

final class TaskBoardWindowPlacementTests: XCTestCase {
    func testReopeningWindowlessMenuBarAppShowsTaskBoard() {
        XCTAssertTrue(TaskBoardReopenPolicy.shouldShowBoard(hasVisibleWindows: false))
        XCTAssertFalse(TaskBoardReopenPolicy.shouldShowBoard(hasVisibleWindows: true))
    }

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
        XCTAssertEqual(moved.width, target.width)
        XCTAssertEqual(moved.height, target.height)
    }

    func testMoveExpandsTinyWindowToUsableMinimum() {
        let target = TaskBoardWindowFrame(x: 1_440, y: 0, width: 1_200, height: 800)

        let moved = TaskBoardWindowPlacement.move(
            frame: .init(x: 500, y: 350, width: 240, height: 160),
            from: .init(x: 0, y: 0, width: 1_440, height: 900),
            to: target,
            minimumWidth: 840,
            minimumHeight: 560
        )

        XCTAssertEqual(moved.width, 840)
        XCTAssertEqual(moved.height, 560)
        XCTAssertTrue(target.contains(moved))
    }

    func testCenterClampsOversizedWindowToVisibleFrame() {
        let visible = TaskBoardWindowFrame(x: 100, y: 50, width: 700, height: 500)

        let centered = TaskBoardWindowPlacement.center(
            frame: .init(x: 0, y: 0, width: 1_400, height: 900),
            in: visible
        )

        XCTAssertEqual(centered, visible)
    }

    func testRecoverCentersFrameWhenSavedDisplayIsGone() {
        let recovered = TaskBoardWindowPlacement.recover(
            frame: .init(x: 4_000, y: 2_000, width: 900, height: 600),
            visibleFrames: [.init(x: 0, y: 0, width: 1_200, height: 800)],
            fallbackIndex: 0
        )

        XCTAssertEqual(recovered, .init(x: 150, y: 100, width: 900, height: 600))
    }

    func testRecoverKeepsVisibleFrameInsideItsCurrentDisplay() {
        let visible = TaskBoardWindowFrame(x: 0, y: 0, width: 1_200, height: 800)
        let recovered = TaskBoardWindowPlacement.recover(
            frame: .init(x: 900, y: 650, width: 500, height: 300),
            visibleFrames: [visible],
            fallbackIndex: 0
        )

        XCTAssertTrue(visible.contains(recovered))
        XCTAssertEqual(recovered, .init(x: 700, y: 500, width: 500, height: 300))
    }

    func testRecoverExpandsTinyPersistedFrameToUsableMinimum() {
        let visible = TaskBoardWindowFrame(x: 0, y: 0, width: 1_440, height: 900)

        let recovered = TaskBoardWindowPlacement.recover(
            frame: .init(x: 500, y: 350, width: 240, height: 160),
            visibleFrames: [visible],
            fallbackIndex: 0,
            minimumWidth: 840,
            minimumHeight: 560
        )

        XCTAssertEqual(recovered.width, 840)
        XCTAssertEqual(recovered.height, 560)
        XCTAssertTrue(visible.contains(recovered))
        XCTAssertEqual(recovered.midX, 620, accuracy: 0.001)
        XCTAssertEqual(recovered.midY, 430, accuracy: 0.001)
    }

    func testManualFrameNormalizationOnlyAppliesWhenSafeAndNecessary() {
        let current = TaskBoardWindowFrame(x: 500, y: 350, width: 135, height: 76)
        let recovered = TaskBoardWindowFrame(x: 147, y: 108, width: 840, height: 560)

        XCTAssertTrue(
            TaskBoardWindowNormalization.shouldApply(
                current: current,
                recovered: recovered,
                isFullScreen: false,
                isFullScreenTransitioning: false,
                isInteracting: false
            )
        )
        XCTAssertFalse(
            TaskBoardWindowNormalization.shouldApply(
                current: recovered,
                recovered: recovered,
                isFullScreen: false,
                isFullScreenTransitioning: false,
                isInteracting: false
            )
        )
        XCTAssertFalse(
            TaskBoardWindowNormalization.shouldApply(
                current: current,
                recovered: recovered,
                isFullScreen: true,
                isFullScreenTransitioning: false,
                isInteracting: false
            )
        )
        XCTAssertFalse(
            TaskBoardWindowNormalization.shouldApply(
                current: current,
                recovered: recovered,
                isFullScreen: false,
                isFullScreenTransitioning: false,
                isInteracting: true
            )
        )
        XCTAssertFalse(
            TaskBoardWindowNormalization.shouldApply(
                current: current,
                recovered: recovered,
                isFullScreen: false,
                isFullScreenTransitioning: true,
                isInteracting: false
            )
        )
        XCTAssertFalse(
            TaskBoardWindowNormalization.shouldApply(
                current: .init(x: 100.1, y: 80.1, width: 840, height: 560),
                recovered: .init(x: 100.2, y: 80.2, width: 840, height: 560),
                isFullScreen: false,
                isFullScreenTransitioning: false,
                isInteracting: false
            )
        )
    }

    func testNextDisplayRequiresAtLeastTwoDisplaysAndWraps() {
        XCTAssertNil(TaskBoardWindowPlacement.nextDisplayIndex(currentIndex: 0, displayCount: 1))
        XCTAssertNil(TaskBoardWindowPlacement.nextDisplayIndex(currentIndex: 0, displayCount: 0))
        XCTAssertEqual(TaskBoardWindowPlacement.nextDisplayIndex(currentIndex: 1, displayCount: 3), 2)
        XCTAssertEqual(TaskBoardWindowPlacement.nextDisplayIndex(currentIndex: 2, displayCount: 3), 0)
    }
}
