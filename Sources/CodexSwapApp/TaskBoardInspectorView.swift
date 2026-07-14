import AppKit
import SwiftUI
import SwapKit

struct TaskBoardInspectorView: View {
    let task: AutomationTask
    let runLogURL: (UUID, Int) async -> URL?
    let planDocument: (UUID) async -> String?

    @State private var tab: InspectorTab = .log
    @State private var selectedRunID: UUID?
    @State private var runURLs: [UUID: URL] = [:]
    @State private var expiredRuns: Set<UUID> = []
    @State private var logLines: [String] = []
    @State private var planText: String?
    @State private var followsLog = true
    @State private var loadedTaskID: UUID?
    @State private var latestRunID: UUID?
    @State private var activeLoadKey: InspectorLoadKey?
    @State private var activeLogLoadKey: SelectedLogLoadKey?
    @State private var activeChangesLoadKey: ChangesLoadKey?
    @State private var changeSummaries: [UUID: GitChangeSummary] = [:]
    @State private var loadingChangeRunIDs: Set<UUID> = []
    @State private var failedChangeRunIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorHeader
                .padding(16)
            Divider()
            tabPicker
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            tabContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: inspectorLoadKey) {
            await loadTask(expected: inspectorLoadKey)
        }
        .task(id: selectedLogLoadKey) { await pollSelectedLog(expected: selectedLogLoadKey) }
        .task(id: changesLoadKey) { await loadSelectedChanges(expected: changesLoadKey) }
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(task.title)
                .font(.headline)
                .lineLimit(2)
            Text(URL(fileURLWithPath: task.repoPath).lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let progress = task.planProgress {
                ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))) {
                    Text("Plan \(progress.done)/\(progress.total)")
                        .font(.caption)
                }
            }
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 6) {
            inspectorTabButton(.log, title: "Log", symbol: "doc.text")
                .disabled(selectedLogURL == nil)
            inspectorTabButton(.runs, title: "Runs", symbol: "clock.arrow.circlepath")
            inspectorTabButton(.plan, title: "Plan", symbol: "checklist")
            inspectorTabButton(.changes, title: "Changes", symbol: "arrow.triangle.branch")
        }
        .controlSize(.small)
    }

    private func inspectorTabButton(_ value: InspectorTab, title: String, symbol: String) -> some View {
        Button {
            tab = value
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tab == value ? .accentColor : nil)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .log:
            logTab
        case .runs:
            runsTab
        case .plan:
            planTab
        case .changes:
            changesTab
        }
    }

    private var logTab: some View {
        VStack(spacing: 0) {
            if let row = selectedTimelineRow {
                runSummary(row)
                    .padding(12)
                Divider()
            }
            HStack {
                Button("Copy", systemImage: "doc.on.doc", action: copyLog)
                    .disabled(logLines.isEmpty)
                Button("Open Externally", systemImage: "arrow.up.forward.app", action: openLogExternally)
                    .disabled(selectedLogURL == nil)
                Spacer()
                if !followsLog {
                    Button("Resume", systemImage: "arrow.down.to.line") { followsLog = true }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            LogTailView(lines: logLines, followsLog: $followsLog)
        }
    }

    private func runSummary(_ row: TaskRunTimelineRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                outcomeIcon(row.outcomeKind)
                Text("Run \(row.runNumber)")
                    .fontWeight(.semibold)
                Text(row.outcome.isEmpty ? "Running" : row.outcome.capitalized)
                Text(Self.duration(row.duration))
                if let exitCode = row.exitCode { Text("exit \(exitCode)") }
                if let plan = row.planSummary { Text("· \(plan)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let summary = row.telemetrySummary {
                Text(summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(5)
            }
            aliasChips(row.servedAliases)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var runsTab: some View {
        if timelineRows.isEmpty {
            ContentUnavailableView("No Runs Yet", systemImage: "clock.arrow.circlepath")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(timelineRows) { row in
                        Button {
                            selectRun(row.id)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                outcomeIcon(row.outcomeKind)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Run \(row.runNumber)")
                                            .fontWeight(.semibold)
                                        Text(row.startedAt, style: .time)
                                        Spacer()
                                        Text(Self.duration(row.duration))
                                    }
                                    Text(runDetail(row))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    aliasChips(row.servedAliases)
                                    if expiredRuns.contains(row.id) {
                                        Label("Log expired", systemImage: "doc.badge.clock")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(selectedRunID == row.id ? Color.accentColor.opacity(0.12) : .clear)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var planTab: some View {
        if let planText {
            let checklist = TaskPlanChecklist.scan(planText)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let handoff = checklist.handoffExcerpt {
                        planSection("Handoff", symbol: "arrowshape.turn.up.right") {
                            Text(handoff)
                                .textSelection(.enabled)
                        }
                    }
                    planItems("Done", symbol: "checkmark.circle.fill", items: checklist.done, color: .green)
                    planItems("Remaining", symbol: "circle", items: checklist.remaining, color: .secondary)
                    if checklist.done.isEmpty, checklist.remaining.isEmpty {
                        Text("No checklist items found.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView("No Plan Yet", systemImage: "checklist")
        }
    }

    private func planItems(_ title: String, symbol: String, items: [String], color: Color) -> some View {
        planSection(title, symbol: symbol) {
            if items.isEmpty {
                Text("None")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: symbol)
                        .foregroundStyle(color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func planSection<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var changesTab: some View {
        if let run = selectedRunRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let actualBranch = run.actualBranch,
                       !actualBranch.isEmpty,
                       actualBranch != task.branch {
                        Label(
                            "Run exited on \(actualBranch), expected \(task.branch)",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                    }

                    if run.baseSHA == nil || run.headSHA == nil {
                        ContentUnavailableView(
                            "No Captured Changes",
                            systemImage: "arrow.triangle.branch",
                            description: Text("This run predates Git capture or the repository was unavailable.")
                        )
                    } else if loadingChangeRunIDs.contains(run.id) {
                        HStack {
                            ProgressView()
                            Text("Loading commits and diff summary…")
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else if let summary = changeSummaries[run.id] {
                        changesSummary(summary, run: run)
                    } else if failedChangeRunIDs.contains(run.id) {
                        ContentUnavailableView(
                            "Changes Unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text("The captured revisions could not be read from this repository.")
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No Run Selected", systemImage: "arrow.triangle.branch")
        }
    }

    private func changesSummary(_ summary: GitChangeSummary, run: TaskRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("\(summary.filesChanged) file\(summary.filesChanged == 1 ? "" : "s")")
                Text("+\(summary.insertions)")
                    .foregroundStyle(.green)
                Text("−\(summary.deletions)")
                    .foregroundStyle(.red)
            }
            .font(.callout.weight(.semibold))

            if let baseSHA = run.baseSHA, let headSHA = run.headSHA {
                Text("\(String(baseSHA.prefix(8))) → \(String(headSHA.prefix(8)))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            if summary.commits.isEmpty {
                Text("No commits were created during this run.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.commits) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(commit.sha.prefix(8)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(commit.subject)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .textSelection(.enabled)
                }
                if summary.isTruncated {
                    Label("Commit list capped at 50", systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func aliasChips(_ aliases: [String]) -> some View {
        if !aliases.isEmpty {
            HStack(spacing: 5) {
                ForEach(aliases, id: \.self) { alias in
                    Text(alias)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("Served by \(alias)")
                }
            }
        }
    }

    private var timelineRows: [TaskRunTimelineRow] {
        TaskRunTimelineRow.rows(for: task)
    }

    private var selectedTimelineRow: TaskRunTimelineRow? {
        timelineRows.first { $0.id == selectedRunID }
    }

    private var selectedLogURL: URL? {
        selectedRunID.flatMap { runURLs[$0] }
    }

    private var selectedRunRecord: TaskRunRecord? {
        TaskRunIdentityResolver.record(id: selectedRunID, in: task.runs)
    }

    private var inspectorLoadKey: InspectorLoadKey {
        InspectorLoadKey(taskID: task.id, runIDs: task.runs.map(\.id), updatedAt: task.updatedAt)
    }

    private var selectedLogLoadKey: SelectedLogLoadKey {
        SelectedLogLoadKey(taskID: task.id, runID: selectedRunID, url: selectedLogURL)
    }

    private var changesLoadKey: ChangesLoadKey {
        ChangesLoadKey(taskID: task.id, tab: tab, runID: selectedRunID, updatedAt: task.updatedAt)
    }

    private func loadTask(expected: InspectorLoadKey) async {
        guard !Task.isCancelled else { return }
        activeLoadKey = expected
        let taskChanged = loadedTaskID != expected.taskID
        if taskChanged {
            guard isActiveLoad(expected) else { return }
            loadedTaskID = expected.taskID
            guard isCurrentLoad(expected) else { return }
            selectedRunID = nil
            guard isCurrentLoad(expected) else { return }
            latestRunID = nil
            guard isCurrentLoad(expected) else { return }
            runURLs = [:]
            guard isCurrentLoad(expected) else { return }
            expiredRuns = []
            guard isCurrentLoad(expected) else { return }
            logLines = []
            guard isCurrentLoad(expected) else { return }
            planText = nil
            guard isCurrentLoad(expected) else { return }
            followsLog = true
            guard isCurrentLoad(expected) else { return }
            tab = .runs
            guard isCurrentLoad(expected) else { return }
            changeSummaries = [:]
            guard isCurrentLoad(expected) else { return }
            loadingChangeRunIDs = []
            guard isCurrentLoad(expected) else { return }
            failedChangeRunIDs = []
            guard isCurrentLoad(expected) else { return }
            activeLogLoadKey = nil
            guard isCurrentLoad(expected) else { return }
            activeChangesLoadKey = nil
        }

        let selectionAtStart = selectedRunID
        let previousLatest = latestRunID
        let rows = timelineRows
        var urls: [UUID: URL] = [:]
        var expired: Set<UUID> = []
        for row in rows {
            if let url = await runLogURL(expected.taskID, row.runNumber) {
                guard isCurrentLoad(expected) else { return }
                urls[row.id] = url
            } else {
                guard isCurrentLoad(expected) else { return }
                expired.insert(row.id)
            }
        }
        let plan = await planDocument(expected.taskID)
        guard isCurrentLoad(expected) else { return }
        let resolvedRunID = TaskRunIdentityResolver.selectedRunID(
            current: selectionAtStart,
            previousLatest: previousLatest,
            runs: task.runs
        )

        guard isCurrentLoad(expected) else { return }
        runURLs = urls
        guard isCurrentLoad(expected) else { return }
        expiredRuns = expired
        guard isCurrentLoad(expected) else { return }
        let shouldUpdateSelection = selectedRunID == selectionAtStart
        if shouldUpdateSelection {
            selectedRunID = resolvedRunID
        }
        guard isCurrentLoad(expected) else { return }
        latestRunID = task.runs.last?.id
        guard isCurrentLoad(expected) else { return }
        planText = plan
        if shouldUpdateSelection {
            guard isCurrentLoad(expected), selectedRunID == resolvedRunID else { return }
            logLines = []
            guard isCurrentLoad(expected), selectedRunID == resolvedRunID else { return }
            followsLog = true
            if taskChanged {
                guard isCurrentLoad(expected), selectedRunID == resolvedRunID else { return }
                tab = resolvedRunID.flatMap { urls[$0] } == nil ? .runs : .log
            } else if tab == .log, selectedLogURL == nil {
                guard isCurrentLoad(expected), selectedRunID == resolvedRunID else { return }
                tab = .runs
            }
        }
    }

    private func pollSelectedLog(expected: SelectedLogLoadKey) async {
        guard !Task.isCancelled else { return }
        activeLogLoadKey = expected
        guard isCurrentLogLoad(expected) else { return }
        guard let url = expected.url else {
            guard isCurrentLogLoad(expected) else { return }
            logLines = []
            return
        }
        while !Task.isCancelled {
            let next = await TaskLogTailReader.lines(at: url, maxLines: 500)
            guard isCurrentLogLoad(expected) else { return }
            if next != logLines {
                guard isCurrentLogLoad(expected) else { return }
                logLines = next
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func selectRun(_ runID: UUID) {
        selectedRunID = runID
        logLines = []
        followsLog = true
        if runURLs[runID] != nil { tab = .log }
    }

    private func loadSelectedChanges(expected: ChangesLoadKey) async {
        guard !Task.isCancelled else { return }
        activeChangesLoadKey = expected
        guard isCurrentChangesLoad(expected),
              expected.tab == .changes,
              let run = selectedRunRecord,
              run.id == expected.runID,
              changeSummaries[run.id] == nil,
              !failedChangeRunIDs.contains(run.id),
              let baseSHA = run.baseSHA,
              let headSHA = run.headSHA else { return }
        guard isCurrentChangesLoad(expected) else { return }
        loadingChangeRunIDs.insert(run.id)
        let summary = await GitProbe.changes(
            at: task.repoPath,
            baseSHA: baseSHA,
            headSHA: headSHA,
            commitLimit: 50
        )
        guard isCurrentChangesLoad(expected) else { return }
        loadingChangeRunIDs.remove(run.id)
        guard isCurrentChangesLoad(expected) else { return }
        if let summary {
            changeSummaries[run.id] = summary
        } else {
            guard isCurrentChangesLoad(expected) else { return }
            failedChangeRunIDs.insert(run.id)
        }
    }

    private func isCurrentLoad(_ expected: InspectorLoadKey) -> Bool {
        isActiveLoad(expected) && loadedTaskID == expected.taskID
    }

    private func isActiveLoad(_ expected: InspectorLoadKey) -> Bool {
        !Task.isCancelled && activeLoadKey == expected
    }

    private func isCurrentLogLoad(_ expected: SelectedLogLoadKey) -> Bool {
        !Task.isCancelled
            && activeLogLoadKey == expected
            && loadedTaskID == expected.taskID
            && selectedRunID == expected.runID
    }

    private func isCurrentChangesLoad(_ expected: ChangesLoadKey) -> Bool {
        !Task.isCancelled
            && activeChangesLoadKey == expected
            && loadedTaskID == expected.taskID
            && tab == expected.tab
            && selectedRunID == expected.runID
    }

    private func runDetail(_ row: TaskRunTimelineRow) -> String {
        var parts = [row.outcome.isEmpty ? "running" : row.outcome]
        if let exitCode = row.exitCode { parts.append("exit \(exitCode)") }
        if let plan = row.planSummary { parts.append("\(plan) plan") }
        return parts.joined(separator: " · ")
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logLines.joined(separator: "\n"), forType: .string)
    }

    private func openLogExternally() {
        guard let selectedLogURL else { return }
        NSWorkspace.shared.open(selectedLogURL)
    }

    @ViewBuilder
    private func outcomeIcon(_ kind: TaskRunOutcomeKind) -> some View {
        switch kind {
        case .running:
            Image(systemName: "play.circle.fill").foregroundStyle(.green)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .waiting:
            Image(systemName: "clock.fill").foregroundStyle(.orange)
        case .stopped:
            Image(systemName: "stop.circle.fill").foregroundStyle(.gray)
        case .unknown:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
        }
    }

    private static func duration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}

private enum InspectorTab: String {
    case log
    case runs
    case plan
    case changes
}

private struct ChangesLoadKey: Hashable {
    let taskID: UUID
    let tab: InspectorTab
    let runID: UUID?
    let updatedAt: Date
}

private struct InspectorLoadKey: Hashable {
    let taskID: UUID
    let runIDs: [UUID]
    let updatedAt: Date
}

private struct SelectedLogLoadKey: Hashable {
    let taskID: UUID
    let runID: UUID?
    let url: URL?
}

private struct LogTailView: View {
    let lines: [String]
    @Binding var followsLog: Bool
    @State private var previousTopY: CGFloat?

    private let bottomID = "log-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: LogTopPreferenceKey.self,
                            value: geometry.frame(in: .named("log-scroll")).minY
                        )
                    }
                    .frame(height: 0)

                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .onAppear { followsLog = true }
                }
                .padding(10)
            }
            .coordinateSpace(name: "log-scroll")
            .onPreferenceChange(LogTopPreferenceKey.self) { topY in
                if let previousTopY, topY > previousTopY + 3 { followsLog = false }
                previousTopY = topY
            }
            .onChange(of: lines.count) { _, _ in
                if followsLog { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: followsLog) { _, follows in
                if follows { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
        .overlay {
            if lines.isEmpty {
                ContentUnavailableView("No Log Output", systemImage: "doc.text")
            }
        }
    }
}

private struct LogTopPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
