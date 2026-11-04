import AppKit
import SwiftUI
import SwapKit

/// SwiftUI row rendered inside the status menu for one account.
/// Countdown strings are computed at render time; the menu rebuilds on every open,
/// so per-second ticking is unnecessary (and timers do not fire during menu tracking).
struct MenuAccountRow: View {
    let rank: Int
    let alias: String
    let isActive: Bool
    let isSticky: Bool
    let isEnabled: Bool
    let needsLogin: Bool
    let isDraining: Bool
    let cooldownUntil: Date?
    let windows: [UsageWindow]
    let costEstimate: Double?
    /// Read-only cap metadata. Settings edits remain in the Accounts pane.
    var usageLimitSettings: AccountUsageLimitSettings = .disabled
    var selectionLabel: String = "Selected"
    var resetContext: UsageResetPresentation = .init()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("#\(rank)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(alias)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .help(selectionLabel)
                    }
                    if isSticky {
                        Image(systemName: "pin.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .help("Pinned manual override; double-click to release")
                            .accessibilityLabel("Pinned manual override")
                    }
                    if let statusLabel {
                        Image(systemName: needsLogin ? "exclamationmark.triangle.fill" : isUsageLimitReached || cooldownUntil != nil ? "pause.circle" : isDraining ? "bolt.fill" : "gauge.with.dots.needle.50percent")
                            .font(.system(size: 11))
                            .foregroundStyle(needsLogin ? Color.red : Color.secondary)
                            .help(statusHelp)
                            .accessibilityLabel(statusLabel)
                    }
                    Spacer(minLength: 0)
                    if let costText = MenuAccountPresentation.costText(costEstimate) {
                        Text(costText)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help("Estimated API-equivalent value of lifetime usage observed by CodexSwap; not your subscription bill or an additional charge.")
                    }
                }
                if windows.isEmpty {
                    Text("Quota unavailable · refresh usage")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(windows, id: \.label) { window in
                            MenuUsageWindow(window: window, context: resetContext)
                        }
                    }
                }
            }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    var accessibilitySummary: String {
        var parts = ["Rank \(rank)", alias, isActive ? selectionLabel : "Not selected"]
        if !isEnabled { parts.append("Unavailable") }
        if isSticky { parts.append("sticky until quota error") }
        parts += windows.map { "\($0.label) \($0.usedPercent)% used, \(MenuAccountPresentation.resetHelp(for: $0, context: resetContext))" }
        if usageLimitSettings.enabled {
            parts.append("usage caps \(usageLimitSettings.fiveHourPercent)% 5-hour and \(usageLimitSettings.weeklyPercent)% weekly")
            if isUsageLimitReached {
                parts.append("paused by usage cap")
                parts.append(isSticky ? "sticky manual override" : "single-click disabled; double-click to pin a manual override")
            }
        }
        if needsLogin { parts.append("needs sign-in") }
        if cooldownUntil != nil { parts.append("Cooling down until limit reset") }
        if isDraining { parts.append("draining from other users") }
        if let cost = MenuAccountPresentation.costText(costEstimate) {
            parts.append("Estimated API-equivalent value \(cost), lifetime observed usage, not a bill")
        }
        return parts.joined(separator: ", ")
    }

    var statusLabel: String? {
        var parts: [String] = []
        if needsLogin { parts.append("Sign-in required") }
        if isUsageLimitReached { parts.append("Usage cap reached") }
        else if cooldownUntil != nil && !needsLogin { parts.append("Cooling down") }
        if isDraining { parts.append("Usage from others") }
        if usageLimitSettings.enabled && !isUsageLimitReached {
            parts.append("Caps \(usageLimitSettings.fiveHourPercent)% / \(usageLimitSettings.weeklyPercent)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var statusHelp: String {
        guard usageLimitSettings.enabled else { return statusLabel ?? "" }
        let cap = "5-hour \(usageLimitSettings.fiveHourPercent)% · weekly \(usageLimitSettings.weeklyPercent)%"
        guard isUsageLimitReached else { return "\(statusLabel ?? "") · Usage caps enabled (\(cap))" }
        if isSticky {
            return "Paused by usage cap (\(cap)); double-click to release the manual override"
        }
        return "Paused by usage cap (\(cap)); single-click disabled, double-click to pin a manual override"
    }

    var allowsSingleClickSelection: Bool {
        !isUsageLimitReached
    }

    private var isUsageLimitReached: Bool {
        guard usageLimitSettings.enabled else { return false }
        return AccountUsageLimitWindow.allCases.contains { window in
            guard let reading = AccountUsageLimitPresentation.usageWindow(for: window, in: windows) else { return false }
            return reading.usedPercent >= AccountUsageLimitPresentation.cap(for: window, settings: usageLimitSettings)
        }
    }
}

/// Menu-specific formatting keeps both windows' exact dates visible. Full year and
/// time zone remain available in help and VoiceOver, including elapsed readings.
enum MenuAccountPresentation {
    static func poolCaption(_ summary: UsageAnalytics.PoolSummary) -> String {
        "\(summary.eligibleCount)/\(summary.accountCount) accounts available"
    }

    static func resetCaption(for window: UsageWindow, context: UsageResetPresentation = .init()) -> String {
        guard let date = window.resetAt else { return "Time unavailable" }
        guard date > context.now else {
            return context.now.timeIntervalSince(date) <= 900 ? "Updating…" : "Awaiting update"
        }
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.calendar = context.calendar
        formatter.timeZone = context.timeZone
        let crossYear = context.calendar.component(.year, from: date) != context.calendar.component(.year, from: context.now)
        formatter.setLocalizedDateFormatFromTemplate(crossYear ? "yMMMd" : "MMMd")
        let day = formatter.string(from: date)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "\(day), \(formatter.string(from: date))"
    }

    static func resetHelp(for window: UsageWindow, context: UsageResetPresentation = .init()) -> String {
        guard let date = window.resetAt else { return "Reset time unavailable" }
        var style = Date.FormatStyle(date: .complete, time: .complete)
        style.locale = context.locale
        style.calendar = context.calendar
        style.timeZone = context.timeZone
        return "Reset: \(date.formatted(style))"
    }

    static func costText(_ estimate: Double?) -> String? {
        guard let estimate, estimate.isFinite, estimate >= 0 else { return nil }
        return String(format: "~$%.2f", estimate)
    }
}

private struct MenuUsageWindow: View {
    let window: UsageWindow
    let context: UsageResetPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(UsageAnalytics.healthTier(usedPercent: window.usedPercent).color.opacity(0.28))
                        .frame(width: geometry.size.width * CGFloat(min(100, max(0, window.usedPercent))) / 100)
                    Text("\(window.label) \(window.usedPercent)%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5)
                }
            }
            .frame(height: 16)
            Text(MenuAccountPresentation.resetCaption(for: window, context: context))
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(MenuAccountPresentation.resetHelp(for: window, context: context))
    }
}

struct MenuSummaryView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @MainActor
    func makeMenuView(width: CGFloat) -> NSView {
        let hosting = NSHostingView(rootView: self.frame(width: width))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: ceil(hosting.fittingSize.height))
        return hosting
    }
}

/// Horizontal usage bar with a percent label; fill color follows the health tier.
/// The track flexes to fill the row so wide menus never leave dead space.
struct UsageBar: View {
    let label: String
    let usedPercent: Int
    let tier: HealthTier
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(usedPercent)%")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(tier.color)
                Text(caption ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tier.color)
                        .frame(width: max(2, proxy.size.width * CGFloat(usedPercent) / 100))
                }
            }
            .frame(height: 4)
        }
        .frame(minWidth: 96, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(usedPercent)% used\(caption.map { ", \($0)" } ?? "")")
    }
}

extension HealthTier {
    var color: Color {
        switch self {
        case .healthy: .green
        case .strained: .orange
        case .critical: .red
        }
    }
}

/// AppKit container that hosts a SwiftUI row inside an NSMenuItem and forwards clicks
/// to the menu action (custom views do not activate items by themselves).
@MainActor
final class MenuRowContainer: NSView {
    private var onSelect: (() -> Void)?
    private var onDoubleClick: (() -> Void)?
    private let rowIsEnabled: Bool
    private let rowAllowsSingleClickSelection: Bool
    private var hovering = false {
        didSet { layer?.backgroundColor = hovering && rowIsEnabled ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil }
    }

    init(row: MenuAccountRow, width: CGFloat, isEnabled: Bool, onSelect: @escaping () -> Void, onDoubleClick: (() -> Void)? = nil) {
        self.onSelect = onSelect
        self.onDoubleClick = onDoubleClick
        self.rowIsEnabled = isEnabled
        self.rowAllowsSingleClickSelection = row.allowsSingleClickSelection
        let finalWidth = max(280, min(width, 400))
        // Measure at the actual menu width so wrapped dates never lose their last line.
        let hosting = NSHostingView(rootView: row.frame(width: finalWidth))
        let height = max(36, ceil(hosting.fittingSize.height))
        super.init(frame: NSRect(x: 0, y: 0, width: finalWidth, height: height))
        wantsLayer = true
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.accessibilitySummary)
        setAccessibilityEnabled(isEnabled)
        if isEnabled, onDoubleClick != nil {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(
                    name: row.isSticky ? "Release manual override" : "Pin manual override",
                    target: self,
                    selector: #selector(performPinAction)
                )
            ])
        }
        toolTip = row.accessibilitySummary
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    func setMenuHighlighted(_ highlighted: Bool) { hovering = highlighted }

    @objc func selectFromMenu(_ sender: Any?) {
        _ = accessibilityPerformPress()
    }

    override var acceptsFirstResponder: Bool { rowIsEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard rowIsEnabled, rowAllowsSingleClickSelection else { return false }
        onSelect?()
        return true
    }

    @objc private func performPinAction() -> Bool {
        guard rowIsEnabled, let onDoubleClick else { return false }
        onDoubleClick()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76, 49].contains(event.keyCode) {
            _ = accessibilityPerformPress()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Custom views bypass NSMenuItem's enabled state, so the disabled guard lives here.
    override func mouseDown(with event: NSEvent) {
        guard rowIsEnabled else { return }
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else if rowAllowsSingleClickSelection {
            onSelect?()
        }
    }
}
