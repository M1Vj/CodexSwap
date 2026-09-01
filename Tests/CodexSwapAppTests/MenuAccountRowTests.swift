import AppKit
import XCTest
import SwapKit
@testable import CodexSwapApp

@MainActor
final class MenuAccountRowTests: XCTestCase {
    func testDoubleClickUsesStickyActionWithoutSingleClickAction() throws {
        var singleClicks = 0
        var doubleClicks = 0
        let row = MenuAccountRow(
            rank: 1,
            alias: "account",
            isActive: true,
            isSticky: false,
            isEnabled: true,
            needsLogin: false,
            isDraining: false,
            cooldownUntil: nil,
            windows: [],
            costEstimate: nil
        )
        let container = MenuRowContainer(
            row: row,
            width: 340,
            isEnabled: true,
            onSelect: { singleClicks += 1 },
            onDoubleClick: { doubleClicks += 1 }
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 0
        ))

        container.mouseDown(with: event)

        XCTAssertEqual(singleClicks, 0)
        XCTAssertEqual(doubleClicks, 1)
    }

    func testCapPausedRowBlocksSingleClickButKeepsDoubleClickOverride() throws {
        var singleClicks = 0
        var doubleClicks = 0
        let row = MenuAccountRow(
            rank: 1,
            alias: "capped",
            isActive: false,
            isSticky: false,
            isEnabled: true,
            needsLogin: false,
            isDraining: false,
            cooldownUntil: nil,
            windows: [UsageWindow(label: "5h", usedPercent: 80, windowSeconds: 18_000, resetAt: nil)],
            costEstimate: nil,
            usageLimitSettings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        )
        let container = MenuRowContainer(
            row: row,
            width: 340,
            isEnabled: true,
            onSelect: { singleClicks += 1 },
            onDoubleClick: { doubleClicks += 1 }
        )
        let singleClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))
        let doubleClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 2,
            pressure: 0
        ))

        container.mouseDown(with: singleClick)
        container.mouseDown(with: doubleClick)

        XCTAssertEqual(singleClicks, 0)
        XCTAssertEqual(doubleClicks, 1)
    }

    func testCappedAccountMayBeActivatedOnlyWhenStickyOverrideIsPresent() {
        XCTAssertFalse(AccountRoutingPresentation.canMakeActive(
            routingEnabled: true,
            usageLimitReached: true,
            stickyOverride: false
        ))
        XCTAssertTrue(AccountRoutingPresentation.canMakeActive(
            routingEnabled: true,
            usageLimitReached: true,
            stickyOverride: true
        ))
        XCTAssertTrue(AccountRoutingPresentation.canMakeActive(
            routingEnabled: true,
            usageLimitReached: false,
            stickyOverride: false
        ))
    }

    func testStickyCapRowRetainsSingleClickSelection() throws {
        var singleClicks = 0
        let row = MenuAccountRow(
            rank: 1,
            alias: "pinned-cap",
            isActive: true,
            isSticky: true,
            isEnabled: true,
            needsLogin: false,
            isDraining: false,
            cooldownUntil: nil,
            windows: [UsageWindow(label: "5h", usedPercent: 80, windowSeconds: 18_000, resetAt: nil)],
            costEstimate: nil,
            usageLimitSettings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        )
        let container = MenuRowContainer(
            row: row,
            width: 340,
            isEnabled: true,
            onSelect: { singleClicks += 1 }
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 0
        ))

        container.mouseDown(with: event)

        XCTAssertEqual(singleClicks, 1)
    }
}
