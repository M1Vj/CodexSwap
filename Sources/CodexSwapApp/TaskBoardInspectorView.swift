import AppKit
import SwiftUI
import SwapKit

struct TaskBoardInspectorView: View {
    let task: AutomationTask
    let runLogURL: (UUID, Int) async -> URL?
    let planDocument: (UUID) async -> String?

    @State private var tab: InspectorTab = .log
    @State private var selectedRunNumber: Int?
    @State private var runURLs: [Int: URL] = [:]
    @State private var expiredRuns: Set<Int> = []
    @State private var logLines: [String] = []
    @State private var planText: String?
    @State private var followsLog = true
    @State private var loadedTaskID: UUID?
    @State private var loadedRunCount = 0
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
        .task(id: InspectorLoadKey(taskID: task.id, runIDs: task.runs.map(\.id), updatedAt: task.updatedAt)) {
            await loadTask()
        }
        .task(id: selectedLogURL) { await pollSelectedLog() }
        .task(id: changesLoadKey) { await loadSelectedChanges() }
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
                            selectRun(row.runNumber)
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
                                    if expiredRuns.contains(row.runNumber) {
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
                        .background(selectedRunNumber == row.runNumber ? Color.accentColor.opacity(0.12) : .clear)
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
        timelineRows.first { $0.runNumber == selectedRunNumber }
    }

    private var selectedLogURL: URL? {
        selectedRunNumber.flatMap { runURLs[$0] }
    }

    private var selectedRunRecord: TaskRunRecord? {
        guard let selectedRunNumber, task.runs.indices.contains(selectedRunNumber - 1) else { return nil }
        return task.runs[selectedRunNumber - 1]
    }

    private var changesLoadKey: ChangesLoadKey {
        ChangesLoadKey(tab: tab, runID: selectedRunRecord?.id, updatedAt: task.updatedAt)
    }

    private func loadTask() async {
        let taskChanged = loadedTaskID != task.id
        let rows = timelineRows
        var urls: [Int: URL] = [:]
        var expired: Set<Int> = []
        for row in rows {
            if let url = await runLogURL(task.id, row.runNumber) {
                urls[row.runNumber] = url
            } else {
                expired.insert(row.runNumber)
            }
        }
        runURLs = urls
        expiredRuns = expired
        if taskChanged || task.runs.count > loadedRunCount {
            selectedRunNumber = rows.first?.runNumber
        } else if !rows.contains(where: { $0.runNumber == selectedRunNumber }) {
            selectedRunNumber = rows.first?.runNumber
        }
        loadedTaskID = task.id
        loadedRunCount = task.runs.count
        planText = await planDocument(task.id)
        logLines = []
        followsLog = true
        if taskChanged {
            tab = selectedLogURL == nil ? .runs : .log
        } else if tab == .log, selectedLogURL == nil {
            tab = .runs
        }
    }

    private func pollSelectedLog() async {
        guard let url = selectedLogURL else {
            logLines = []
            return
        }
        while !Task.isCancelled {
            let next = await TaskLogTailReader.lines(at: url, maxLines: 500)
            if next != logLines { logLines = next }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func selectRun(_ runNumber: Int) {
        selectedRunNumber = runNumber
        logLines = []
        followsLog = true
        if runURLs[runNumber] != nil { tab = .log }
    }

    private func loadSelectedChanges() async {
        guard tab == .changes,
              let run = selectedRunRecord,
              changeSummaries[run.id] == nil,
              !failedChangeRunIDs.contains(run.id),
              let baseSHA = run.baseSHA,
              let headSHA = run.headSHA else { return }
        loadingChangeRunIDs.insert(run.id)
        defer { loadingChangeRunIDs.remove(run.id) }
        if let summary = await GitProbe.changes(
            at: task.repoPath,
            baseSHA: baseSHA,
            headSHA: headSHA,
            commitLimit: 50
        ) {
            changeSummaries[run.id] = summary
        } else {
            failedChangeRunIDs.insert(run.id)
        }
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
    let tab: InspectorTab
    let runID: UUID?
    let updatedAt: Date
}

private struct InspectorLoadKey: Hashable {
    let taskID: UUID
    let runIDs: [UUID]
    let updatedAt: Date
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
