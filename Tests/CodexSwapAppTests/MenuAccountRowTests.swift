import AppKit
import XCTest
import SwapKit
@testable import CodexSwapApp

@MainActor
final class MenuAccountRowTests: XCTestCase {
    private func menuAccount(_ alias: String, archivedAt: Date? = nil, routingEnabled: Bool = true) -> Account {
        Account(
            alias: alias,
            accountID: alias,
            accessToken: "token-\(alias)",
            routingEnabled: routingEnabled,
            archivedAt: archivedAt
        )
    }

    func testMenuDistinguishesLastRoutedAccountFromDefaultForNewTasks() {
        let presentation = AccountMenuSelectionPresentation.resolve(
            defaultAlias: "default",
            lastRoutedAlias: "routed",
            accounts: [menuAccount("default"), menuAccount("routed")]
        )

        XCTAssertEqual(presentation.displayedAlias, "routed")
        XCTAssertEqual(presentation.lastRoutedTitle, "Last routed: routed")
        XCTAssertEqual(presentation.defaultTitle, "Default for new tasks: default")
    }

    func testMenuFallsBackToDefaultWhenLastRoutedAccountIsArchived() {
        let presentation = AccountMenuSelectionPresentation.resolve(
            defaultAlias: "default",
            lastRoutedAlias: "archived",
            accounts: [menuAccount("default"), menuAccount("archived", archivedAt: Date(timeIntervalSince1970: 1))]
        )

        XCTAssertEqual(presentation.displayedAlias, "default")
        XCTAssertEqual(presentation.lastRoutedTitle, "Last routed: archived (archived)")
        XCTAssertEqual(presentation.defaultTitle, "Default for new tasks: default")
    }

    func testMenuSuppressesRemovedLastRoutedAccountAndKeepsDefault() {
        let presentation = AccountMenuSelectionPresentation.resolve(
            defaultAlias: "default",
            lastRoutedAlias: "removed",
            accounts: [menuAccount("default")]
        )

        XCTAssertEqual(presentation.displayedAlias, "default")
        XCTAssertEqual(presentation.lastRoutedTitle, "Last routed: none")
        XCTAssertEqual(presentation.defaultTitle, "Default for new tasks: default")
    }

    func testMenuDoesNotExpireLastRoutedPresentationByIdleAge() {
        let presentation = AccountMenuSelectionPresentation.resolve(
            defaultAlias: "default",
            lastRoutedAlias: "routed",
            accounts: [menuAccount("default"), menuAccount("routed")]
        )

        XCTAssertEqual(presentation.displayedAlias, "routed")
        XCTAssertEqual(presentation.lastRoutedTitle, "Last routed: routed")
    }

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

    func testCappedAccountCannotBeActivatedEvenWhenStickyOverrideIsPresent() {
        XCTAssertFalse(AccountRoutingPresentation.canMakeActive(
            routingEnabled: true,
            usageLimitReached: true,
            stickyOverride: false
        ))
        XCTAssertFalse(AccountRoutingPresentation.canMakeActive(
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

    func testStickyCapRowBlocksSingleClickButKeepsDoubleClickOverride() throws {
        var singleClicks = 0
        var doubleClicks = 0
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
            eventNumber: 3,
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
            eventNumber: 4,
            clickCount: 2,
            pressure: 0
        ))

        container.mouseDown(with: event)
        container.mouseDown(with: doubleClick)

        XCTAssertEqual(singleClicks, 0)
        XCTAssertEqual(doubleClicks, 1)
    }
}
