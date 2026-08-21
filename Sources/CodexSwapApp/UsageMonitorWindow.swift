import AppKit
import SwiftUI
import SwapKit

@MainActor
final class UsageMonitorWindowController: NSWindowController {
    private let viewModel: UsageMonitorViewModel

    init(engine: AppEngine) {
        let viewModel = UsageMonitorViewModel(engine: engine)
        self.viewModel = viewModel
        let hostingController = NSHostingController(rootView: UsageMonitorView(model: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "CodexSwap Usage Monitor"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 640))
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await viewModel.refresh() }
    }
}

@MainActor
final class UsageMonitorViewModel: ObservableObject {
    @Published private(set) var overview = PoolUsageOverview(
        generatedAt: Date(),
        accounts: [],
        summary: UsageAnalytics.PoolSummary(),
        smartSwitchEnabled: false
    )
    @Published var sortMode: UsageSortMode = .rank
    @Published var isLoading = false

    private let engine: AppEngine

    init(engine: AppEngine) {
        self.engine = engine
    }

    func refresh() async {
        isLoading = true
        overview = await engine.usageOverview()
        isLoading = false
    }

    var sortedAccounts: [AccountUsageOverview] {
        switch sortMode {
        case .rank: return overview.accounts
        case .headroom:
            return overview.accounts.sorted { a, b in
                primaryUsed(a) > primaryUsed(b)
            }
        case .cost:
            return overview.accounts.sorted { $0.estimatedCost > $1.estimatedCost }
        case .name:
            return overview.accounts.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        }
    }

    private func primaryUsed(_ row: AccountUsageOverview) -> Int {
        (row.windows.first { $0.windowSeconds < 604_800 } ?? row.windows.first)?.usedPercent ?? 0
    }
}

enum UsageSortMode: String, CaseIterable, Identifiable {
    case rank
    case headroom
    case cost
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rank: "Ranking"
        case .headroom: "Most used"
        case .cost: "Est. cost"
        case .name: "Name"
        }
    }
}

struct UsageMonitorView: View {
    @ObservedObject var model: UsageMonitorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                PoolSummaryCard(summary: model.overview.summary, smartSwitchEnabled: model.overview.smartSwitchEnabled)
                ForEach(model.sortedAccounts) { account in
                    AccountUsageCard(account: account)
                }
                if model.overview.accounts.isEmpty && !model.isLoading {
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "gauge.with.dots.needle.bottom.50percent",
                        description: Text("Add an account to start monitoring usage.")
                    )
                    .frame(maxWidth: .infinity)
                }
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Cheap local snapshot; keeps the dashboard fresh alongside the poller.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage Monitor")
                    .font(.title2.weight(.semibold))
                Text(stalenessText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Sort", selection: $model.sortMode) {
                ForEach(UsageSortMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isLoading)
            .accessibilityLabel("Refresh usage")
        }
    }

    private var stalenessText: String {
        let age = Date().timeIntervalSince(model.overview.generatedAt)
        if age < 10 { return "Updated just now" }
        return "Updated \(Int(age) / 60)m ago · fail-stale: last good readings stay visible"
    }

    private var footer: some View {
        Text("Costs are estimates from published list pricing; Codex subscription traffic has no real invoice. Token totals come from responses routed through the CodexSwap proxy.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

private struct PoolSummaryCard: View {
    let summary: UsageAnalytics.PoolSummary
    let smartSwitchEnabled: Bool

    var body: some View {
        GroupBox {
            HStack(spacing: 24) {
                metric("\(summary.accountCount)", label: "accounts")
                metric("\(summary.eligibleCount)", label: "eligible", color: summary.eligibleCount == 0 ? .red : .primary)
                metric("\(summary.healthyCount)", label: "healthy", color: .green)
                if smartSwitchEnabled {
                    metric("\(summary.drainingCount)", label: "draining by others", color: .orange)
                }
                Divider()
                metric(tokensLabel(summary.totalInputTokens + summary.totalOutputTokens), label: "tokens total")
                metric(String(format: "~$%.2f", summary.estimatedCostTotal), label: "est. cost")
                metric("\(Int(summary.avgPrimaryUsedPercent.rounded()))%", label: "avg used")
            }
            .frame(maxWidth: .infinity)
        } label: {
            Text("Pool Overview").font(.headline)
        }
    }

    private func metric(_ value: String, label: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func tokensLabel(_ tokens: Int) -> String {
        tokens >= 1_000_000
            ? String(format: "%.1fM", Double(tokens) / 1_000_000)
            : String(format: "%.0fK", Double(tokens) / 1_000)
    }
}

private struct AccountUsageCard: View {
    let account: AccountUsageOverview

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("#\(account.rank)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(account.alias)
                        .font(.headline)
                    if account.isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    if account.isDraining {
                        Label("Draining from other users", systemImage: "bolt.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    if account.needsLogin {
                        Label("Needs sign-in", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                    if !account.routingEnabled {
                        Text("Routing off")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if account.stats?.totalRequests ?? 0 > 0 {
                        Text(String(format: "~$%.2f est.", account.estimatedCost))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let plan = account.planType, !plan.isEmpty {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(alignment: .top, spacing: 20) {
                    ForEach(account.windows, id: \.label) { window in
                        WindowMeter(
                            window: window,
                            burnPerHour: burnFor(window),
                            hoursLeft: hoursLeftFor(window),
                            pace: paceFor(window)
                        )
                    }
                    if account.windows.isEmpty {
                        Text("No usage data — waiting for the next poll.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let stats = account.stats, stats.totalRequests > 0 {
                    ModelBreakdownTable(models: stats.models)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
    }

    private func index(of window: UsageWindow) -> Int? {
        account.windows.firstIndex { $0.label == window.label }
    }

    private func burnFor(_ window: UsageWindow) -> Double? {
        index(of: window).flatMap { account.burnPerHourByWindow[$0] }
    }

    private func hoursLeftFor(_ window: UsageWindow) -> Double? {
        index(of: window).flatMap { account.hoursLeftByWindow[$0] }
    }

    private func paceFor(_ window: UsageWindow) -> PaceStatus {
        index(of: window).flatMap { account.paceByWindow[$0] } ?? .unknown
    }
}

private struct WindowMeter: View {
    let window: UsageWindow
    let burnPerHour: Double?
    let hoursLeft: Double?
    let pace: PaceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(paceText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(paceColor)
                    .help("Consumption vs an even spread across the window")
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tier.color.opacity(0.85))
                        .frame(width: max(3, proxy.size.width * CGFloat(window.usedPercent) / 100))
                }
            }
            .frame(height: 8)
            HStack {
                Text("\(window.usedPercent)% used")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tier.color)
                Spacer()
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(analyticsLine)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 180)
    }

    private var tier: HealthTier { UsageAnalytics.healthTier(usedPercent: window.usedPercent) }

    private var paceText: String {
        switch pace {
        case .ahead: "ahead of pace ✓"
        case .even: "even pace"
        case .behind: "burning fast ⚠︎"
        case .unknown: ""
        }
    }

    private var paceColor: Color {
        switch pace {
        case .ahead: .green
        case .even: .secondary
        case .behind: .orange
        case .unknown: .clear
        }
    }

    private var resetText: String {
        guard let resetAt = window.resetAt else { return "" }
        let remaining = resetAt.timeIntervalSinceNow
        guard remaining > 0 else { return "resetting…" }
        let minutes = Int(remaining / 60)
        if minutes >= 1440 { return "resets in \(minutes / 1440)d \(minutes % 1440 / 60)h" }
        if minutes >= 60 { return "resets in \(minutes / 60)h \(minutes % 60)m" }
        return "resets in \(minutes)m"
    }

    /// Burn rate and time-to-exhaustion are suppressed until ≥3% is consumed so early-window
    /// extrapolations never render as fake precision.
    private var analyticsLine: String {
        var parts: [String] = []
        if let burnPerHour, UsageAnalytics.isMeaningfulUsage(usedPercent: window.usedPercent) {
            parts.append(String(format: "burn %.1f%%/h", max(0, burnPerHour)))
        }
        if let hoursLeft {
            parts.append(hoursLeft < 1 ? "runs out <1h" : String(format: "runs out in %.1fh", hoursLeft))
        }
        return parts.joined(separator: " · ")
    }
}

private struct ModelBreakdownTable: View {
    let models: [ModelUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models (lifetime through proxy)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("Model").font(.caption2).foregroundStyle(.tertiary)
                    Text("Requests").font(.caption2).foregroundStyle(.tertiary)
                    Text("In").font(.caption2).foregroundStyle(.tertiary)
                    Text("Cached").font(.caption2).foregroundStyle(.tertiary)
                    Text("Out").font(.caption2).foregroundStyle(.tertiary)
                    Text("Est. cost").font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(models, id: \.model) { row in
                    GridRow {
                        Text(row.model).font(.caption.monospacedDigit())
                        Text("\(row.requests)").font(.caption.monospacedDigit())
                        Text(tokens(row.inputTokens)).font(.caption.monospacedDigit())
                        Text(tokens(row.cachedInputTokens)).font(.caption.monospacedDigit())
                        Text(tokens(row.outputTokens)).font(.caption.monospacedDigit())
                        Text(String(format: "$%.4f", UsageAnalytics.estimatedCost(
                            inputTokens: row.inputTokens,
                            cachedInputTokens: row.cachedInputTokens,
                            outputTokens: row.outputTokens,
                            model: row.model
                        ))).font(.caption.monospacedDigit())
                    }
                }
            }
        }
    }

    private func tokens(_ value: Int) -> String {
        value >= 1_000_000
            ? String(format: "%.2fM", Double(value) / 1_000_000)
            : value >= 1_000
                ? String(format: "%.1fK", Double(value) / 1_000)
                : "\(value)"
    }
}
