import AppKit
import SwiftUI
import SwapKit

/// Compact token formatter shared by the monitor's sections.
fileprivate func compactTokens(_ value: Int) -> String {
    value >= 1_000_000
        ? String(format: "%.2fM", Double(value) / 1_000_000)
        : value >= 1_000
            ? String(format: "%.1fK", Double(value) / 1_000)
            : "\(value)"
}

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
    @Published private(set) var localUsage = LocalUsageAttribution.empty
    @Published var sortMode: UsageSortMode = .rank
    @Published var isLoading = false

    private let engine: AppEngine

    init(engine: AppEngine) {
        self.engine = engine
    }

    func refresh(forceLocalScan: Bool = false) async {
        isLoading = true
        overview = await engine.usageOverview()
        // Engine-side TTL cache keeps the 5s tick cheap; the button forces a rescan.
        localUsage = await engine.localUsageAttribution(forceRefresh: forceLocalScan)
        isLoading = false
    }

    func totals(for alias: String) -> LocalUsageTotals? {
        localUsage.attributed[alias]
    }

    var unattributedTotals: LocalUsageTotals? { localUsage.unattributed }

    var pooledLocalTotals: LocalUsageTotals {
        var combined = LocalUsageTotals()
        for totals in localUsage.attributed.values { combined += totals }
        if let unattributed = localUsage.unattributed { combined += unattributed }
        return combined
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
                PoolSummaryCard(
                    summary: model.overview.summary,
                    smartSwitchEnabled: model.overview.smartSwitchEnabled,
                    localTotals: model.pooledLocalTotals
                )
                ForEach(model.sortedAccounts) { account in
                    AccountUsageCard(account: account, localTotals: model.totals(for: account.alias))
                }
                if let unattributed = model.unattributedTotals {
                    Label(
                        "Shared CODEX_HOME history (last 7d): \(unattributed.sessionCount) sessions · \(compactTokens(unattributed.totalTokens)) — cannot be split across standalone accounts.",
                        systemImage: "questionmark.folder"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Task { await model.refresh(forceLocalScan: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isLoading)
            .help("Refresh usage and rescan local session logs")
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
    let localTotals: LocalUsageTotals

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
                metric(compactTokens(summary.totalProxyTokens), label: "proxy tokens")
                metric(TokenMetricPresentation.text(
                    value: summary.totalCachedInputTokens,
                    completeness: summary.totalCachedInputCompleteness
                ), label: "cached reads")
                metric(TokenMetricPresentation.text(
                    value: summary.totalCacheWriteInputTokens,
                    completeness: summary.totalCacheWriteInputCompleteness
                ), label: "cache writes")
                metric(compactTokens(localTotals.totalTokens), label: "local tokens · 7d")
                metric("\(localTotals.sessionCount)", label: "local sessions · 7d")
                Divider()
                metric(CostMetricPresentation.text(
                    cost: summary.estimatedCostTotal,
                    availability: summary.costAvailability,
                    prefix: "~$",
                    decimals: 2
                ), label: "est. proxy cost")
                metric(CostMetricPresentation.text(
                    cost: localEstimatedCost,
                    availability: UsageAnalytics.costAvailability(localTotals),
                    prefix: "~$",
                    decimals: 2
                ), label: "est. local cost · 7d")
                metric("\(Int(summary.avgPrimaryUsedPercent.rounded()))%", label: "avg used")
            }
            .frame(maxWidth: .infinity)
        } label: {
            Text("Pool Overview").font(.headline)
        }
    }

    private var localEstimatedCost: Double {
        UsageAnalytics.estimatedCost(
            inputTokens: localTotals.inputTokens,
            cachedInputTokens: localTotals.cachedInputCompleteness == .unknown ? nil : localTotals.cachedInputTokens,
            cacheWriteInputTokens: localTotals.cacheWriteInputCompleteness == .unknown ? nil : localTotals.cacheWriteInputTokens,
            outputTokens: localTotals.outputTokens,
            model: localTotals.models.first ?? "unknown"
        )
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

}

private struct AccountUsageCard: View {
    let account: AccountUsageOverview
    let localTotals: LocalUsageTotals?

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
                        Text(CostMetricPresentation.text(
                            cost: account.estimatedCost,
                            availability: account.costAvailability,
                            prefix: "~$",
                            decimals: 2
                        ) + " est.")
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

                if let stats = account.stats,
                   stats.totalRequests > 0,
                   stats.models.contains(where: { $0.requests > 0 }) {
                    ModelBreakdownTable(models: stats.models.filter { $0.requests > 0 })
                        .accessibilityLabel("Proxy-attributed per-model usage")
                }
                if let local = localTotals, local.sessionCount > 0 {
                    LocalUsageSection(totals: local)
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
        if resetAt <= Date() { return "resetting…" }
        return "Resets " + resetAt.formatted(date: .abbreviated, time: .shortened)
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

enum LocalUsageCostProjection {
    static func estimatedCost(for totals: LocalUsageTotals) -> Double {
        UsageAnalytics.estimatedCost(
            inputTokens: totals.inputTokens,
            cachedInputTokens: totals.cachedInputCompleteness == .unknown ? nil : totals.cachedInputTokens,
            cacheWriteInputTokens: totals.cacheWriteInputCompleteness == .unknown ? nil : totals.cacheWriteInputTokens,
            outputTokens: totals.outputTokens,
            model: totals.models.first ?? "unknown"
        )
    }

    static func availability(for totals: LocalUsageTotals) -> CostAvailability {
        UsageAnalytics.costAvailability(totals)
    }

    static func text(
        for totals: LocalUsageTotals,
        prefix: String = "~$",
        decimals: Int = 4
    ) -> String {
        CostMetricPresentation.text(
            cost: estimatedCost(for: totals),
            availability: availability(for: totals),
            prefix: prefix,
            decimals: decimals
        )
    }
}

enum CostMetricPresentation {
    static func text(
        cost: Double,
        availability: CostAvailability,
        prefix: String = "$",
        decimals: Int = 2
    ) -> String {
        switch availability {
        case .unknown:
            return "?"
        case .unavailable, .partial:
            return "unpriced"
        case .complete:
            let format = decimals == 4 ? "%@%.4f" : "%@%.2f"
            return String(format: format, prefix, cost)
        }
    }
}

enum TokenMetricPresentation {
    static func text(value: Int, completeness: TokenFieldCompleteness) -> String {
        switch completeness {
        case .unknown:
            return "?"
        case .partial:
            return "partial \(compactTokens(value))"
        case .complete:
            return compactTokens(value)
        }
    }
}

private struct LocalUsageSection: View {
    let totals: LocalUsageTotals

    var body: some View {
        HStack(spacing: 14) {
            Label("Local sessions · 7d", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            stat("in", tokens(totals.inputTokens))
            stat("cached", TokenMetricPresentation.text(
                value: totals.cachedInputTokens,
                completeness: totals.cachedInputCompleteness
            ))
            stat("write", TokenMetricPresentation.text(
                value: totals.cacheWriteInputTokens,
                completeness: totals.cacheWriteInputCompleteness
            ))
            stat("out", tokens(totals.outputTokens))
            stat("sessions", "\(totals.sessionCount)")
            stat("est.", LocalUsageCostProjection.text(for: totals))
            if let model = totals.models.first {
                Text("via \(model)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.caption.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func tokens(_ value: Int) -> String {
        compactTokens(value)
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
                    Text("Write").font(.caption2).foregroundStyle(.tertiary)
                    Text("Out").font(.caption2).foregroundStyle(.tertiary)
                    Text("Est. cost").font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(models, id: \.model) { row in
                    GridRow {
                        Text(row.model).font(.caption.monospacedDigit())
                        Text("\(row.requests)").font(.caption.monospacedDigit())
                        Text(tokens(row.inputTokens)).font(.caption.monospacedDigit())
                        Text(TokenMetricPresentation.text(
                            value: row.cachedInputTokens,
                            completeness: row.cachedInputCompleteness
                        )).font(.caption.monospacedDigit())
                        Text(TokenMetricPresentation.text(
                            value: row.cacheWriteInputTokens,
                            completeness: row.cacheWriteInputCompleteness
                        )).font(.caption.monospacedDigit())
                        Text(tokens(row.outputTokens)).font(.caption.monospacedDigit())
                        Text(CostMetricPresentation.text(
                            cost: UsageAnalytics.estimatedCost(
                            inputTokens: row.inputTokens,
                            cachedInputTokens: row.cachedInputCompleteness == .unknown ? nil : row.cachedInputTokens,
                            cacheWriteInputTokens: row.cacheWriteInputCompleteness == .unknown ? nil : row.cacheWriteInputTokens,
                            outputTokens: row.outputTokens,
                            model: row.model
                            ),
                            availability: UsageAnalytics.costAvailability(row),
                            prefix: "$",
                            decimals: 4
                        )).font(.caption.monospacedDigit())
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
