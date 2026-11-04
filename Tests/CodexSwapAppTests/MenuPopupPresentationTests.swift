import AppKit
import SwiftUI
import XCTest
import SwapKit
@testable import CodexSwapApp

@MainActor
final class MenuPopupPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_750_400) // Nov 4, 2026 UTC

    private func context(_ locale: String = "en_US") -> UsageResetPresentation {
        UsageResetPresentation(
            now: now, locale: Locale(identifier: locale),
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func row(windows: [UsageWindow]? = nil, enabled: Bool = true, capped: Bool = false,
                     rank: Int = 1, alias: String = "Primary account", isActive: Bool = true, needsLogin: Bool = false) -> MenuAccountRow {
        MenuAccountRow(
            rank: rank, alias: alias, isActive: isActive, isSticky: false,
            isEnabled: enabled, needsLogin: needsLogin, isDraining: false, cooldownUntil: nil,
            windows: windows ?? [
                UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(7_200)),
                UsageWindow(label: "Weekly", usedPercent: 74, windowSeconds: 604_800, resetAt: now.addingTimeInterval(500_000))
            ], costEstimate: 12.34,
            usageLimitSettings: capped ? .init(enabled: true, fiveHourPercent: 20, weeklyPercent: 70) : .disabled,
            selectionLabel: "Last routed", resetContext: context()
        )
    }

    func testBothWindowsShowCalendarDateAndTimeWithFullAccessibleTimestamp() {
        for seconds in [18_000, 604_800] {
            let window = UsageWindow(label: "quota", usedPercent: 24, windowSeconds: seconds, resetAt: now.addingTimeInterval(7_200))
            let text = MenuAccountPresentation.resetCaption(for: window, context: context())
            XCTAssertTrue(text.contains("Nov"), text)
            XCTAssertTrue(text.contains("4"), text)
            XCTAssertTrue(text.contains(":"), text)
            XCTAssertFalse(text.contains("2026"), text)
            XCTAssertFalse(text.contains("…"), text)
            XCTAssertFalse(text.lowercased().contains("reset"), text)
            let columnWidth: CGFloat = (360 - 20 - 12) / 2
            XCTAssertLessThanOrEqual(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11)]).size().width, columnWidth)
            let help = MenuAccountPresentation.resetHelp(for: window, context: context())
            XCTAssertTrue(help.contains("2026"), help)
            XCTAssertTrue(help.contains("GMT"), help)
        }
    }

    func testUnknownElapsedAndCrossYearResetStatesRemainHonest() {
        func window(_ date: Date?) -> UsageWindow {
            UsageWindow(label: "Weekly", usedPercent: 100, windowSeconds: 604_800, resetAt: date)
        }
        XCTAssertEqual(MenuAccountPresentation.resetCaption(for: window(nil), context: context()), "Time unavailable")
        XCTAssertEqual(MenuAccountPresentation.resetCaption(for: window(now.addingTimeInterval(-10)), context: context()), "Updating…")
        XCTAssertEqual(MenuAccountPresentation.resetCaption(for: window(now.addingTimeInterval(-901)), context: context()), "Awaiting update")
        let nextYear = MenuAccountPresentation.resetCaption(for: window(now.addingTimeInterval(90 * 86_400)), context: context())
        XCTAssertTrue(nextYear.contains("2027"), nextYear)
    }

    func testCostNamesApiEquivalentValueAndRejectsUnknownOrInvalidValues() {
        XCTAssertEqual(MenuAccountPresentation.costText(12.34), "~$12.34")
        XCTAssertEqual(MenuAccountPresentation.costText(0), "~$0.00")
        XCTAssertNil(MenuAccountPresentation.costText(nil))
        XCTAssertNil(MenuAccountPresentation.costText(.nan))
        XCTAssertNil(MenuAccountPresentation.costText(.infinity))
        XCTAssertNil(MenuAccountPresentation.costText(-1))
        XCTAssertTrue(row().accessibilitySummary.contains("lifetime observed usage, not a bill"))
    }

    func testStatusAndAccessibilityDescribePauseAndSelectionWithoutSymbols() {
        XCTAssertEqual(row(capped: true).statusLabel, "Usage cap reached")
        XCTAssertTrue(row(capped: true).accessibilitySummary.contains("paused by usage cap"))
        XCTAssertTrue(row().accessibilitySummary.contains("Last routed"))
        XCTAssertTrue(row().accessibilitySummary.contains("74% used"))
        var cooling = row()
        cooling = MenuAccountRow(
            rank: cooling.rank, alias: cooling.alias, isActive: false, isSticky: false,
            isEnabled: true, needsLogin: false, isDraining: true, cooldownUntil: now,
            windows: [], costEstimate: nil
        )
        XCTAssertEqual(cooling.statusLabel, "Cooling down · Usage from others")
        XCTAssertEqual(cooling.statusHelp, "Cooling down · Usage from others")
        XCTAssertFalse(cooling.statusHelp.contains("caps enabled"))
    }

    func testPoolCaptionUsesAvailabilityWhenWeeklyQuotaIsCoolingDown() {
        let ready = Account(alias: "ready", accessToken: "synthetic-fixture")
        let cooling = Account(alias: "weekly-full", accessToken: "synthetic-fixture", disabledUntil: ["Weekly": now.addingTimeInterval(600)])
        let pool = UsageAnalytics.poolSummary(accounts: [ready, cooling], drainingAliases: [], now: now)
        XCTAssertEqual(MenuAccountPresentation.poolCaption(pool), "1/2 accounts available")
    }

    func testNativeMenuActionKeyboardAndAccessibilityPreserveSelectionGuards() throws {
        for (enabled, capped) in [(true, false), (false, false), (true, true)] {
            var selections = 0
            let container = MenuRowContainer(row: row(enabled: enabled, capped: capped), width: 340, isEnabled: enabled,
                onSelect: { selections += 1 }, onDoubleClick: {})
            let allowed = enabled && !capped
            XCTAssertEqual(container.accessibilityPerformPress(), allowed)
            container.selectFromMenu(nil)
            let enter = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ))
            container.keyDown(with: enter)
            XCTAssertEqual(selections, allowed ? 3 : 0)
            XCTAssertEqual(container.accessibilityCustomActions()?.map(\.name) ?? [], enabled ? ["Pin manual override"] : [])
        }
    }

    func testRowsMeasureAtTheirActualWidthForLongLocalizedDates() {
        for locale in ["en_US", "de_DE", "fr_FR", "ar_SA"] {
            var sample = row()
            sample.resetContext = context(locale)
            for width: CGFloat in [280, 340, 360, 400] {
                let container = MenuRowContainer(row: sample, width: width, isEnabled: true, onSelect: {})
                let measured = NSHostingView(rootView: sample.frame(width: width)).fittingSize
                XCTAssertEqual(container.frame.width, width)
                XCTAssertGreaterThan(container.frame.height, 40)
                XCTAssertGreaterThanOrEqual(container.frame.height, ceil(measured.height))
                XCTAssertLessThanOrEqual(container.frame.height, width >= 340 ? 64 : 80)
            }
        }
    }

    /// Opt-in synthetic evidence only; never opens the app or reads live accounts.
    func testRenderSyntheticNativePopupFixturesWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXSWAP_MENU_FIXTURE_DIR"] else {
            throw XCTSkip("Set CODEXSWAP_MENU_FIXTURE_DIR to render synthetic popup evidence")
        }
        _ = NSApplication.shared
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(360)), ("dark", .darkAqua, 360), ("narrow", .aqua, 280)] {
            let surface = FixtureSurface(frame: .zero)
            surface.appearance = NSAppearance(named: appearance)
            surface.wantsLayer = true
            var y: CGFloat = 0
            func add(_ view: NSView, height: CGFloat) {
                view.frame = NSRect(x: 0, y: y, width: width, height: height)
                surface.addSubview(view)
                y += height
            }
            let header = NSHostingView(rootView: MenuSummaryView(title: "● Ready — idle · 42 served", detail: "1/4 accounts available · 1 task running").frame(width: width))
            add(header, height: ceil(header.fittingSize.height))
            for sample in [row(), row(capped: true, rank: 2, alias: "Account with usage cap", isActive: false), MenuAccountRow(
                rank: 3, alias: "Weekly quota exhausted", isActive: false, isSticky: false, isEnabled: true,
                needsLogin: false, isDraining: false, cooldownUntil: now.addingTimeInterval(500_000), windows: [
                    UsageWindow(label: "5h", usedPercent: 30, windowSeconds: 18_000, resetAt: now.addingTimeInterval(7_200)),
                    UsageWindow(label: "Weekly", usedPercent: 100, windowSeconds: 604_800, resetAt: now.addingTimeInterval(500_000))
                ], costEstimate: nil, resetContext: context()
            ), row(rank: 4, alias: "Account needing attention", isActive: false, needsLogin: true)
            ] {
                let container = MenuRowContainer(row: sample, width: width, isEnabled: true, onSelect: {})
                print("Compact fixture row \(sample.rank): \(container.frame.height) points")
                add(container, height: container.frame.height)
            }
            for title in ["Routing & Task Details     ›", "Refresh Usage", "Warm Quota Windows…", "Usage Monitor…", "Diagnostics…", "Task Board…                 ⌘T", "Settings…                      ⌘,", "Quit CodexSwap             ⌘Q"] {
                let label = NSTextField(labelWithString: title)
                label.font = .menuFont(ofSize: 13)
                label.textColor = .labelColor
                let wrapper = NSView()
                label.frame = NSRect(x: 10, y: 2, width: width - 20, height: 20)
                wrapper.addSubview(label)
                add(wrapper, height: 24)
            }
            surface.frame = NSRect(x: 0, y: 0, width: width, height: y + 6)
            let window = NSWindow(contentRect: surface.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = surface
            surface.appearance?.performAsCurrentDrawingAppearance {
                surface.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            surface.layoutSubtreeIfNeeded()
            surface.displayIfNeeded()
            let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("compact-menu-\(name).png"))
            print("Synthetic fixture \(name): \(Int(width))x\(Int(y + 6)) points")
            window.orderOut(nil)
        }
    }
}

private final class FixtureSurface: NSView {
    override var isFlipped: Bool { true }
}
