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
    let isEnabled: Bool
    let needsLogin: Bool
    let isDraining: Bool
    let cooldownUntil: Date?
    let windows: [UsageWindow]
    let costEstimate: Double?

    var body: some View {
        HStack(spacing: 10) {
            Text("#\(rank)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 26, alignment: .leading)
                .accessibilityLabel("Rank \(rank)")
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.secondary.opacity(0.6))
                .accessibilityLabel(isActive ? "Active" : "Inactive")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(alias)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                    if isDraining {
                        badge("⚡︎", color: .orange, help: "Quota draining from other users")
                    }
                    if needsLogin {
                        badge("⚠︎", color: .red, help: "Needs sign-in")
                    }
                    if cooldownUntil != nil && !needsLogin {
                        badge("⏸", color: .orange, help: "Cooling down until limit reset")
                    }
                    Spacer(minLength: 0)
                    if let costEstimate, costEstimate > 0 {
                        Text(String(format: "~$%.2f", costEstimate))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(windows, id: \.label) { window in
                        UsageBar(
                            label: window.label,
                            usedPercent: window.usedPercent,
                            tier: UsageAnalytics.healthTier(usedPercent: window.usedPercent),
                            caption: resetCaption(window)
                        )
                    }
                    if windows.isEmpty {
                        Text("no usage data")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = ["Rank \(rank)", alias, isActive ? "active" : "inactive"]
        parts += windows.map { "\($0.label) \($0.usedPercent)% used" }
        if needsLogin { parts.append("needs sign-in") }
        if isDraining { parts.append("draining from other users") }
        return parts.joined(separator: ", ")
    }

    private func resetCaption(_ window: UsageWindow) -> String? {
        guard let resetAt = window.resetAt else { return nil }
        let interval = resetAt.timeIntervalSinceNow
        guard interval > 0 else { return "resetting…" }
        let minutes = Int(interval / 60)
        if minutes >= 60 {
            return "resets in \(minutes / 60)h \(minutes % 60)m"
        }
        return "resets in \(minutes)m"
    }

    private func badge(_ symbol: String, color: Color, help: String) -> some View {
        Text(symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .help(help)
    }
}

/// Horizontal usage bar with a percent label; fill color follows the health tier.
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
            .frame(width: 74, height: 4)
            if let caption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
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
    private let rowIsEnabled: Bool
    private var hovering = false {
        didSet { layer?.backgroundColor = hovering && rowIsEnabled ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil }
    }

    init(row: MenuAccountRow, width: CGFloat, isEnabled: Bool, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        self.rowIsEnabled = isEnabled
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 38))
        wantsLayer = true
        let hosting = NSHostingView(rootView: row)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick)))
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

    /// Custom views bypass NSMenuItem's enabled state, so the disabled guard lives here.
    @objc private func handleClick() {
        guard rowIsEnabled else { return }
        onSelect?()
    }
}
