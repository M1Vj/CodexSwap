import AppKit
import Charts
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

enum UsageMonitorPresentation {
    static let rangeLabels = UsageTelemetryRange.allCases.map(rangeLabel)
    static let sectionTitles = [
        "Capacity", "Efficiency", "Reliability", "Latency", "Trends", "Account mix", "Model mix", "Task Board"
    ]
    static let archivedHistoryLabel = "Include archived usage history"
    static let telemetryDisclosure = "Collects only bounded counts, categories, timestamps, durations, token totals, retry outcomes, and estimated-cost provenance. Prompts, responses, commands, paths, headers, OAuth data, session identifiers, aliases, and raw errors are never stored. Request details stay local for 30 days; daily aggregates stay for 365 days; lifetime totals remain until cleared. Telemetry is never uploaded. Latency combines local and network time, and these metrics do not infer interactive quality or productivity."
    static let telemetryOffMessage = "Metadata telemetry is off. Quota and local usage history remain available; enable collection to see derived usage insights."

    static func rangeLabel(_ range: UsageTelemetryRange) -> String {
        switch range {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .lifetime: "Lifetime"
        }
    }

    static func scopeCaption(includeArchived: Bool) -> String {
        includeArchived ? "Active quota · archived usage is historical" : "Active accounts · current quota"
    }

    static func percentileText(value: Int?, sampleCount: Int, percentile: Double) -> String {
        let threshold = percentile >= 0.95 ? 20 : 3
        guard sampleCount >= threshold else { return "Not enough samples" }
        guard let value else { return "~>10m" }
        if value >= 600_000 { return "~≤10m" }
        return "~\(value) ms"
    }

    static func percentageText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unknown" }
        return String(format: "%.1f%%", value * 100)
    }

    static func completenessCaption(_ value: UsageMetricCompleteness) -> String {
        switch value {
        case .complete: "Complete"
        case .partial: "Partial coverage"
        case .unknown: "Unknown"
        }
    }

    static func trendAccessibilityValue(_ metrics: [UsageDailyMetric]) -> String {
        guard !metrics.isEmpty else { return "No daily trend data" }
        let attempts = saturatingSum(metrics.map(\.attempts))
        let tokens = saturatingSum(metrics.map(\.tokens))
        let errors = saturatingSum(metrics.map(\.errors))
        return "\(metrics.count) \(metrics.count == 1 ? "day" : "days"), \(attempts) \(attempts == 1 ? "attempt" : "attempts"), \(tokens) tokens, \(errors) \(errors == 1 ? "error" : "errors")"
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int.max : sum
        }
    }
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
    @Published private(set) var analytics: UsageAnalyticsDerivedSnapshot?
    @Published private(set) var telemetryEnabled = false
    @Published var sortMode: UsageSortMode = .rank
    @Published var selectedRange: UsageTelemetryRange = .sevenDays
    @Published var includeArchivedHistory = false
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
        telemetryEnabled = await engine.metadataTelemetryEnabled()
        analytics = await engine.usageAnalytics(
            range: selectedRange,
            includeArchivedHistory: includeArchivedHistory
        )
        isLoading = false
    }

    func setTelemetryEnabled(_ enabled: Bool) async {
        await engine.setMetadataTelemetryEnabled(enabled)
        await refresh()
    }

    func clearTelemetry() async {
        await engine.clearMetadataTelemetry()
        await refresh()
    }

    func totals(for alias: String) -> LocalUsageTotals? {
        localUsage.attributed[alias]
    }

    var unattributedTotals: LocalUsageTotals? { localUsage.unattributed }

    var hasAnalyticsData: Bool {
        guard let analytics else { return false }
        return analytics.reliability.attemptCount > 0
            || !analytics.daily.isEmpty
            || analytics.taskBoard.terminalRunCount > 0
    }

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
    @State private var telemetryOptInConfirmationPresented = false
    @State private var clearTelemetryConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                historyControls
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
                if let analytics = model.analytics, model.telemetryEnabled || model.hasAnalyticsData {
                    AnalyticsDashboard(
                        metrics: analytics,
                        includeArchivedHistory: model.includeArchivedHistory
                    )
                } else if !model.telemetryEnabled {
                    Text(UsageMonitorPresentation.telemetryOffMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
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
        .confirmationDialog(
            "Enable local metadata telemetry?",
            isPresented: $telemetryOptInConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Enable Collection") {
                Task { await model.setTelemetryEnabled(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(UsageMonitorPresentation.telemetryDisclosure)
        }
        .confirmationDialog(
            "Clear telemetry history?",
            isPresented: $clearTelemetryConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear Telemetry History", role: .destructive) {
                Task { await model.clearTelemetry() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes request details, daily aggregates, anonymous root totals, and lifetime telemetry from this Mac. It does not change quota windows, account credentials, CodexBar, or OAuth state.")
        }
        .onChange(of: model.selectedRange) { _, _ in
            Task { await model.refresh() }
        }
        .onChange(of: model.includeArchivedHistory) { _, _ in
            Task { await model.refresh() }
        }
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

    private var historyControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Picker("History range", selection: $model.selectedRange) {
                        ForEach(UsageTelemetryRange.allCases, id: \.self) { range in
                            Text(UsageMonitorPresentation.rangeLabel(range)).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Usage history range")
                    Toggle(UsageMonitorPresentation.archivedHistoryLabel, isOn: $model.includeArchivedHistory)
                        .disabled(!model.telemetryEnabled && !model.hasAnalyticsData)
                        .help("Archived account usage is historical and never contributes to current routing capacity.")
                    Spacer()
                }
                Text(UsageMonitorPresentation.scopeCaption(includeArchived: model.includeArchivedHistory))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.telemetryEnabled ? "checkmark.shield" : "lock.shield")
                        .foregroundStyle(model.telemetryEnabled ? .green : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.telemetryEnabled ? "Local metadata telemetry is on" : "Local metadata telemetry is off")
                            .font(.callout.weight(.medium))
                        Text(model.telemetryEnabled ? "\(UsageMonitorPresentation.completenessCaption(model.analytics?.completeness ?? .unknown)) coverage · data stays on this Mac." : UsageMonitorPresentation.telemetryOffMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.telemetryEnabled {
                        Button("Clear Telemetry History…", role: .destructive) {
                            clearTelemetryConfirmationPresented = true
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Clear local telemetry history")
                    } else {
                        Button("Enable Collection…") {
                            telemetryOptInConfirmationPresented = true
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Review and enable local metadata telemetry")
                    }
                }
                Text(UsageMonitorPresentation.telemetryDisclosure)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("History & Privacy").font(.headline)
        }
    }

    private var stalenessText: String {
        let age = Date().timeIntervalSince(model.overview.generatedAt)
        if age < 10 { return "Updated just now" }
        return "Updated \(Int(age) / 60)m ago · fail-stale: last good readings stay visible"
    }

    private var footer: some View {
        Text("Telemetry is opt-in, metadata-only, local to this Mac, and never uploaded. Costs are estimates from versioned published list pricing, not invoices. Latency includes local and network time. Token volume, speed, and cost do not measure interactive quality or productivity.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

private struct AnalyticsDashboard: View {
    let metrics: UsageAnalyticsDerivedSnapshot
    let includeArchivedHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Derived usage insights · \(UsageMonitorPresentation.rangeLabel(metrics.range))")
                .font(.title3.weight(.semibold))
            Text(UsageMonitorPresentation.scopeCaption(includeArchived: includeArchivedHistory))
                .font(.caption)
                .foregroundStyle(.secondary)
            CapacityAnalyticsCard(metrics: metrics.capacity)
            HStack(alignment: .top, spacing: 12) {
                EfficiencyAnalyticsCard(metrics: metrics.efficiency)
                ReliabilityAnalyticsCard(metrics: metrics.reliability)
            }
            HStack(alignment: .top, spacing: 12) {
                LatencyAnalyticsCard(metrics: metrics.latency)
                TaskBoardAnalyticsCard(metrics: metrics.taskBoard)
            }
            TrendsAnalyticsCard(range: metrics.range, metrics: metrics.daily, coverageStart: metrics.detailCoverageStart, truncated: metrics.detailTruncated)
            HStack(alignment: .top, spacing: 12) {
                ShareAnalyticsCard(title: "Account mix", rows: metrics.accountShares)
                ShareAnalyticsCard(title: "Model mix", rows: metrics.modelShares)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct AnalyticsMetricRow: View {
    let label: String
    let value: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .font(.callout.monospacedDigit().weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CapacityAnalyticsCard: View {
    let metrics: UsageCapacityMetrics

    var body: some View {
        GroupBox {
            if metrics.windows.isEmpty {
                Text("No fresh active-account quota samples yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let best = bestAvailable {
                        Text("Best available now: \(best.alias ?? "Account") · \(best.label) has \(best.headroomPercent)% headroom.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(metrics.windows) { window in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(window.alias ?? "Account")
                                    .font(.callout.weight(.medium))
                                Text(window.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(window.headroomPercent)% headroom")
                                    .font(.caption.monospacedDigit())
                            }
                            HStack(spacing: 14) {
                                Text("\(window.usedPercent)% used")
                                Text(resetText(window))
                                Text(burnText(window.burnPercentPerHour))
                                Text(forecastText(window.projectedUsageAtResetPercent))
                                Text(exhaustionText(window.hoursUntilExhausted))
                                Text(confidenceText(window.forecastConfidence))
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } label: {
            Text("Capacity").font(.headline)
        }
    }

    private var bestAvailable: UsageCapacityWindowMetric? {
        metrics.windows.min {
            if $0.usedPercent != $1.usedPercent { return $0.usedPercent < $1.usedPercent }
            return ($0.alias ?? "") < ($1.alias ?? "")
        }
    }

    private func resetText(_ metric: UsageCapacityWindowMetric) -> String {
        let seconds = metric.label.lowercased() == "5h" ? UsageResetPresentation.fiveHourWindowSeconds : nil
        return UsageResetPresentation().appCaption(windowSeconds: seconds, resetAt: metric.resetAt) ?? "reset unknown"
    }

    private func burnText(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "burn unknown" }
        return String(format: "burn %.1f%%/h", value)
    }

    private func forecastText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "forecast unknown" }
        return String(format: "at reset %.0f%%", value)
    }

    private func exhaustionText(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "exhaustion unknown" }
        return value >= 24 ? String(format: "exhaustion %.1fd", value / 24) : String(format: "exhaustion %.1fh", value)
    }

    private func confidenceText(_ value: UsageForecastConfidence) -> String {
        "confidence \(value.rawValue)"
    }
}

private struct EfficiencyAnalyticsCard: View {
    let metrics: UsageEfficiencyMetrics

    var body: some View {
        GroupBox {
            VStack(spacing: 6) {
                AnalyticsMetricRow(label: "Attempts", value: "\(metrics.attemptCount)", detail: UsageMonitorPresentation.completenessCaption(metrics.completeness))
                AnalyticsMetricRow(label: "Input", value: compactTokens(metrics.inputTokens), detail: nil)
                AnalyticsMetricRow(label: "Fresh input", value: metrics.freshInputTokens.map(compactTokens) ?? "Unknown", detail: UsageMonitorPresentation.completenessCaption(metrics.freshInputCompleteness))
                AnalyticsMetricRow(label: "Cached input", value: metrics.cacheCompleteness == .unknown ? "Unknown" : compactTokens(metrics.cachedInputTokens), detail: UsageMonitorPresentation.completenessCaption(metrics.cacheCompleteness))
                AnalyticsMetricRow(label: "Cache-write input", value: metrics.cacheCompleteness == .unknown ? "Unknown" : compactTokens(metrics.cacheWriteInputTokens), detail: UsageMonitorPresentation.completenessCaption(metrics.cacheCompleteness))
                AnalyticsMetricRow(label: "Cache hit", value: UsageMonitorPresentation.percentageText(metrics.cacheHitRate), detail: UsageMonitorPresentation.completenessCaption(metrics.cacheCompleteness))
                AnalyticsMetricRow(label: "Cache write", value: UsageMonitorPresentation.percentageText(metrics.cacheWriteRate), detail: nil)
                AnalyticsMetricRow(label: "Output", value: compactTokens(metrics.outputTokens), detail: nil)
                AnalyticsMetricRow(label: "Reasoning", value: metrics.reasoningCompleteness == .unknown ? "Unknown" : compactTokens(metrics.reasoningTokens), detail: UsageMonitorPresentation.completenessCaption(metrics.reasoningCompleteness))
                AnalyticsMetricRow(label: "Reasoning share", value: UsageMonitorPresentation.percentageText(metrics.reasoningShare), detail: UsageMonitorPresentation.completenessCaption(metrics.reasoningCompleteness))
                AnalyticsMetricRow(label: "Tokens / root", value: metrics.tokensPerRootRequest.map { String(format: "%.0f", $0) } ?? "Unknown", detail: nil)
                AnalyticsMetricRow(label: "Estimated cost", value: costText(metrics.estimatedCostUSD, availability: metrics.costAvailability), detail: metrics.pricingRevision.map { "pricing \($0)" })
                AnalyticsMetricRow(label: "Estimated cache savings", value: costText(metrics.estimatedCacheSavingsUSD, availability: metrics.costAvailability), detail: metrics.pricingSource)
            }
        } label: {
            Text("Efficiency").font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func costText(_ value: Double?, availability: CostAvailability) -> String {
        guard availability == .complete, let value else {
            switch availability {
            case .unknown: return "Unknown"
            case .unavailable: return "Unpriced"
            case .partial: return "Partial · withheld"
            case .complete: return "Unknown"
            }
        }
        return String(format: "~$%.4f", value)
    }
}

private struct ReliabilityAnalyticsCard: View {
    let metrics: UsageReliabilityMetrics

    var body: some View {
        GroupBox {
            VStack(spacing: 6) {
                AnalyticsMetricRow(label: "Attempts", value: "\(metrics.attemptCount)", detail: UsageMonitorPresentation.completenessCaption(metrics.completeness))
                AnalyticsMetricRow(label: "Attempt errors", value: UsageMonitorPresentation.percentageText(metrics.attemptErrorRate), detail: "\(metrics.failedAttemptCount) failed")
                AnalyticsMetricRow(label: "429 rate", value: UsageMonitorPresentation.percentageText(metrics.rateLimitedRate), detail: "\(metrics.rateLimitedCount) rate-limited")
                AnalyticsMetricRow(label: "Root success", value: UsageMonitorPresentation.percentageText(metrics.rootSuccessRate), detail: "\(metrics.rootRequestCount) roots")
                AnalyticsMetricRow(label: "Retry amplification", value: metrics.retryAmplification.map { String(format: "%.2fx", $0) } ?? "Unknown", detail: "\(metrics.retryCount) retries")
                AnalyticsMetricRow(label: "Fallback frequency", value: UsageMonitorPresentation.percentageText(metrics.fallbackFrequency), detail: "account/model changes")
                AnalyticsMetricRow(label: "Failed-attempt tokens", value: metrics.failedAttemptTokenCompleteness == .unknown ? "Unknown" : compactTokens(metrics.failedAttemptTokens), detail: "\(metrics.failedAttemptTimeMilliseconds) ms failed time")
            }
        } label: {
            Text("Reliability").font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct LatencyAnalyticsCard: View {
    let metrics: UsageLatencyMetrics

    var body: some View {
        GroupBox {
            VStack(spacing: 6) {
                AnalyticsMetricRow(label: "Total latency ~p50", value: UsageMonitorPresentation.percentileText(value: metrics.p50Milliseconds, sampleCount: metrics.sampleCount, percentile: 0.5), detail: "\(metrics.sampleCount) successful samples")
                AnalyticsMetricRow(label: "Total latency ~p95", value: UsageMonitorPresentation.percentileText(value: metrics.p95Milliseconds, sampleCount: metrics.sampleCount, percentile: 0.95), detail: nil)
                AnalyticsMetricRow(label: "First chunk ~p50", value: UsageMonitorPresentation.percentileText(value: metrics.p50TimeToFirstChunkMilliseconds, sampleCount: metrics.timeToFirstChunkSampleCount, percentile: 0.5), detail: "\(metrics.timeToFirstChunkSampleCount) streamed samples")
                AnalyticsMetricRow(label: "First chunk ~p95", value: UsageMonitorPresentation.percentileText(value: metrics.p95TimeToFirstChunkMilliseconds, sampleCount: metrics.timeToFirstChunkSampleCount, percentile: 0.95), detail: nil)
                Text("Includes local and network time; percentile values use fixed latency buckets.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Text("Latency").font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

enum UsageTrendMetric: String, CaseIterable, Identifiable {
    case attempts
    case tokens
    case estimatedCost
    case errors
    case latency

    var id: Self { self }

    var label: String {
        switch self {
        case .attempts: "Attempts"
        case .tokens: "Tokens"
        case .estimatedCost: "Estimated cost"
        case .errors: "Errors"
        case .latency: "Latency p50"
        }
    }

    func value(_ day: UsageDailyMetric) -> Double? {
        switch self {
        case .attempts: Double(day.attempts)
        case .tokens: Double(day.tokens)
        case .estimatedCost: day.estimatedCostUSD
        case .errors: Double(day.errors)
        case .latency: day.p50Milliseconds.map(Double.init)
        }
    }
}

private struct TrendsAnalyticsCard: View {
    let range: UsageTelemetryRange
    let metrics: [UsageDailyMetric]
    let coverageStart: Date?
    let truncated: Bool
    @State private var selectedMetric: UsageTrendMetric = .attempts

    var body: some View {
        GroupBox {
            if metrics.isEmpty {
                Text(range == .lifetime
                    ? "Lifetime keeps compact totals. Choose 7 or 30 days for daily charts."
                    : "Daily trend buckets are available after telemetry records an attempt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Daily chart")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Picker("Trend metric", selection: $selectedMetric) {
                            ForEach(UsageTrendMetric.allCases) { metric in
                                Text(metric.label).tag(metric)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 155)
                    }
                    Chart(metrics) { day in
                        if let value = selectedMetric.value(day) {
                            LineMark(
                                x: .value("Day", day.dayKey),
                                y: .value(selectedMetric.label, value)
                            )
                            .interpolationMethod(.monotone)
                            PointMark(
                                x: .value("Day", day.dayKey),
                                y: .value(selectedMetric.label, value)
                            )
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: true))
                    .frame(height: 120)
                    .accessibilityLabel("Daily \(selectedMetric.label) trend")
                    .accessibilityValue(UsageMonitorPresentation.trendAccessibilityValue(metrics))
                    Divider()
                    HStack {
                        Text("Day").frame(width: 90, alignment: .leading)
                        Text("Attempts").frame(width: 70, alignment: .trailing)
                        Text("Tokens").frame(width: 75, alignment: .trailing)
                        Text("~Cost").frame(width: 70, alignment: .trailing)
                        Text("Errors").frame(width: 60, alignment: .trailing)
                        Text("429s").frame(width: 45, alignment: .trailing)
                        Text("~p50").frame(width: 65, alignment: .trailing)
                        Text("~p95").frame(width: 65, alignment: .trailing)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    ForEach(metrics) { day in
                        HStack {
                            Text(day.dayKey).frame(width: 90, alignment: .leading)
                            Text("\(day.attempts)").frame(width: 70, alignment: .trailing)
                            Text(compactTokens(day.tokens)).frame(width: 75, alignment: .trailing)
                            Text(day.estimatedCostUSD.map { String(format: "$%.3f", $0) } ?? "Unknown").frame(width: 70, alignment: .trailing)
                            Text("\(day.errors)").frame(width: 60, alignment: .trailing)
                            Text("\(day.rateLimited)").frame(width: 45, alignment: .trailing)
                            Text(UsageMonitorPresentation.percentileText(value: day.p50Milliseconds, sampleCount: day.p50Milliseconds == nil ? 0 : 3, percentile: 0.5)).frame(width: 65, alignment: .trailing)
                            Text(UsageMonitorPresentation.percentileText(value: day.p95Milliseconds, sampleCount: day.p95Milliseconds == nil ? 0 : 20, percentile: 0.95)).frame(width: 65, alignment: .trailing)
                        }
                        .font(.caption.monospacedDigit())
                    }
                    if truncated {
                        Text("Detailed request coverage starts \(coverageStartText); the 50,000-event cap truncated the nominal 30-day detail range. Aggregates remain available.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Daily usage trends table")
            }
        } label: {
            Text("Trends").font(.headline)
        }
    }

    private var coverageStartText: String {
        coverageStart?.formatted(date: .abbreviated, time: .omitted) ?? "later"
    }
}

private enum UsageShareSort: String, CaseIterable, Identifiable {
    case tokens
    case requests
    case estimatedCost
    case name

    var id: Self { self }
    var label: String {
        switch self {
        case .tokens: "Token share"
        case .requests: "Request share"
        case .estimatedCost: "Estimated cost"
        case .name: "Name"
        }
    }
}

private struct ShareAnalyticsCard: View {
    let title: String
    let rows: [UsageShareMetric]
    @State private var sort: UsageShareSort = .tokens

    var body: some View {
        GroupBox {
            if rows.isEmpty {
                Text("No measured share yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    HStack {
                        Text("Top \(min(rows.count, 12)) of \(rows.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Picker("Sort \(title)", selection: $sort) {
                            ForEach(UsageShareSort.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 135)
                    }
                    ForEach(Array(sortedRows.prefix(12))) { row in
                        AnalyticsMetricRow(
                            label: row.key,
                            value: shareText(row),
                            detail: shareDetail(row)
                        )
                    }
                    Text("Share is by observed attempts in the selected range.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            Text(title).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var sortedRows: [UsageShareMetric] {
        rows.sorted { lhs, rhs in
            switch sort {
            case .tokens:
                if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            case .requests:
                if lhs.requests != rhs.requests { return lhs.requests > rhs.requests }
            case .estimatedCost:
                if (lhs.estimatedCostUSD ?? -1) != (rhs.estimatedCostUSD ?? -1) {
                    return (lhs.estimatedCostUSD ?? -1) > (rhs.estimatedCostUSD ?? -1)
                }
            case .name:
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }
    }

    private func shareText(_ row: UsageShareMetric) -> String {
        switch sort {
        case .requests: UsageMonitorPresentation.percentageText(row.requestShare)
        case .estimatedCost: UsageMonitorPresentation.percentageText(row.costShare)
        case .tokens, .name: UsageMonitorPresentation.percentageText(row.tokenShare)
        }
    }

    private func shareDetail(_ row: UsageShareMetric) -> String {
        let cost = row.estimatedCostUSD.map { String(format: " · ~$%.4f", $0) } ?? ""
        return "\(row.requests) requests · \(compactTokens(row.tokens)) tokens\(cost)"
    }
}

private struct TaskBoardAnalyticsCard: View {
    let metrics: UsageTaskBoardMetrics

    var body: some View {
        GroupBox {
            VStack(spacing: 6) {
                AnalyticsMetricRow(label: "Completion", value: UsageMonitorPresentation.percentageText(metrics.completionRate), detail: "\(metrics.completedCount) complete · \(metrics.failedCount) failed")
                AnalyticsMetricRow(label: "Stopped / cancelled", value: "\(metrics.cancelledCount)", detail: "excluded from completion denominator")
                AnalyticsMetricRow(label: "Average duration", value: metrics.runDurationMilliseconds.map(formatDuration) ?? "Unknown", detail: UsageMonitorPresentation.completenessCaption(metrics.completeness))
                AnalyticsMetricRow(label: "Tokens / completed run", value: metrics.tokensPerCompletedRun.map { String(format: "%.0f", $0) } ?? "Unknown", detail: UsageMonitorPresentation.completenessCaption(metrics.tokenCompleteness))
                AnalyticsMetricRow(label: "Estimated cost / completed run", value: metrics.estimatedCostPerCompletedRun.map { String(format: "~$%.4f", $0) } ?? "Unknown", detail: metrics.costAvailability.rawValue.capitalized)
                AnalyticsMetricRow(label: "Retries", value: "\(metrics.retryCount)", detail: "model fallbacks \(metrics.modelFallbackCount)")
                Text("Task Board outcomes are operational run results, not interactive quality or productivity scores.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Text("Task Board").font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func formatDuration(_ value: Double) -> String {
        if value >= 60_000 { return String(format: "%.1f min", value / 60_000) }
        return String(format: "%.0f ms", value)
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
        UsageResetPresentation().appCaption(for: window) ?? ""
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
