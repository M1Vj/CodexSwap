import AppKit
import XCTest
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
}
