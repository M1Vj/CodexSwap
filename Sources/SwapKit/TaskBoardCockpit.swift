import Foundation

public enum TaskBoardFilter {
    public static func includes(_ task: AutomationTask, query: String, needsAttention: Bool) -> Bool {
        guard task.archivedAt == nil else { return false }
        if needsAttention, ![.failed, .pausedQuota, .retryWaiting].contains(task.phase) {
            return false
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [task.title, task.prompt, task.repoPath].contains {
            $0.localizedCaseInsensitiveContains(needle)
        }
    }
}

public enum TaskDropPlacement: Sendable, Equatable {
    case before
    case after
}

public enum TaskReorder {
    public static func destinationIndex(
        sourceIndex: Int,
        targetIndex: Int,
        placement: TaskDropPlacement,
        itemCount: Int
    ) -> Int {
        guard itemCount > 1 else { return 0 }
        let source = max(0, min(sourceIndex, itemCount - 1))
        let target = max(0, min(targetIndex, itemCount - 1))
        var boundary = target + (placement == .after ? 1 : 0)
        if source < boundary { boundary -= 1 }
        return max(0, min(boundary, itemCount - 1))
    }
}

public enum TaskLaneDropDecision: Sendable, Equatable {
    case move
    case runNow
    case reject(reason: String)
}

public enum TaskLaneDropPolicy {
    public static func decision(for task: AutomationTask, into column: TaskColumn) -> TaskLaneDropDecision {
        if task.column == column { return .move }
        if column == .inProgress { return .runNow }
        if column == .done, task.phase != .completed {
            return .reject(reason: "Only completed tasks can move to Done")
        }
        return .move
    }
}

public enum TaskSchedulingReasonFormatter {
    public static func format(
        aliases: [String],
        accounts: [Account],
        consumeBankedWindow: Bool,
        minHeadroomPercent: Int = 0,
        primaryThresholdPercent: Int = 100,
        secondaryThresholdPercent: Int = 100,
        now: Date
    ) -> String {
        guard !aliases.isEmpty else { return "No accounts configured" }
        let byAlias = Dictionary(uniqueKeysWithValues: accounts.map { ($0.alias, $0) })
        return aliases.map { alias in
            let safeAlias = oneLine(alias)
            guard let account = byAlias[alias] else { return "\(safeAlias): unknown account" }
            if account.needsLogin || account.accessToken.isEmpty { return "\(safeAlias): needs login" }
            if let cooldown = account.cooldownUntil(now: now) {
                return "\(safeAlias): cooldown until \(shortDate(cooldown))"
            }
            if !consumeBankedWindow, !AppEngine.hasStartedWindow(account) {
                return "\(safeAlias): banked window not started"
            }
            if let starved = account.usage.first(where: { 100 - $0.usedPercent < minHeadroomPercent }) {
                return "\(safeAlias): headroom<\(minHeadroomPercent)% (\(starved.label) \(starved.usedPercent)% used)"
            }
            if let over = account.usage.first(where: {
                $0.usedPercent >= ($0.windowSeconds >= 604_800 ? secondaryThresholdPercent : primaryThresholdPercent)
            }) {
                return "\(safeAlias): over threshold (\(over.label) \(over.usedPercent)% used)"
            }
            return "\(safeAlias): eligible"
        }.joined(separator: "; ")
    }

    public static func nextDeadline(
        task: AutomationTask,
        aliases: [String],
        accounts: [Account],
        now: Date
    ) -> Date? {
        if task.phase == .retryWaiting, let retryAt = task.nextRetryAt, retryAt > now {
            return retryAt
        }
        let allowed = Set(aliases)
        return accounts
            .filter { allowed.contains($0.alias) }
            .compactMap { account in
                if let cooldown = account.cooldownUntil(now: now) { return cooldown }
                return account.usage.compactMap(\.resetAt).filter { $0 > now }.min()
            }
            .min()
    }

    private static func oneLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
    }
}

public enum TaskRunOutcomeKind: Sendable, Equatable {
    case running
    case succeeded
    case failed
    case waiting
    case stopped
    case unknown
}

public enum TaskRunIdentityResolver {
    public static func record(id: UUID?, in runs: [TaskRunRecord]) -> TaskRunRecord? {
        guard let id else { return nil }
        return runs.first { $0.id == id }
    }

    public static func selectedRunID(
        current: UUID?,
        previousLatest: UUID?,
        runs: [TaskRunRecord]
    ) -> UUID? {
        guard let latest = runs.last?.id else { return nil }
        guard let current else { return latest }
        guard runs.contains(where: { $0.id == current }) else { return latest }
        return current == previousLatest ? latest : current
    }
}

public struct TaskRunTimelineRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let runNumber: Int
    public let startedAt: Date
    public let duration: TimeInterval
    public let outcome: String
    public let outcomeKind: TaskRunOutcomeKind
    public let exitCode: Int32?
    public let planDone: Int?
    public let planTotal: Int?
    public let logFileName: String
    public let telemetrySummary: String?
    public let servedAliases: [String]

    public var planSummary: String? {
        guard let planDone, let planTotal else { return nil }
        return "\(planDone)/\(planTotal)"
    }

    public static func rows(for task: AutomationTask, now: Date = Date()) -> [TaskRunTimelineRow] {
        task.runs.enumerated().reversed().map { index, run in
            TaskRunTimelineRow(
                id: run.id,
                runNumber: runNumber(for: run) ?? index + 1,
                startedAt: run.startedAt,
                duration: max(0, (run.finishedAt ?? now).timeIntervalSince(run.startedAt)),
                outcome: run.outcome,
                outcomeKind: outcomeKind(for: run),
                exitCode: run.exitCode,
                planDone: run.planDone,
                planTotal: run.planTotal,
                logFileName: run.logFileName,
                telemetrySummary: TaskRunSummaryExtractor.summary(from: run),
                servedAliases: run.servedAliases
            )
        }
    }

    static func runNumber(for run: TaskRunRecord) -> Int? {
        guard run.logFileName.hasPrefix("run-"), run.logFileName.hasSuffix(".log") else { return nil }
        return Int(run.logFileName.dropFirst(4).dropLast(4))
    }

    private static func outcomeKind(for run: TaskRunRecord) -> TaskRunOutcomeKind {
        if run.finishedAt == nil { return .running }
        let value = run.outcome.lowercased()
        if value == "invalid-complete" || value == "replan" { return .waiting }
        if value.contains("complete") || value.contains("success") { return .succeeded }
        if value.contains("stop") || value.contains("interrupt") { return .stopped }
        if value.contains("quota") || value.contains("retry") || value.contains("continue") { return .waiting }
        if value.contains("fail") || (run.exitCode.map { $0 != 0 } == true) { return .failed }
        return .unknown
    }
}

public enum TaskRunSummaryExtractor {
    public static func summary(from run: TaskRunRecord) -> String? {
        var parts: [String] = []
        if let tokens = tokenLine(for: run) { parts.append(tokens) }
        if let summary = run.summary, !summary.isEmpty { parts.append(summary) }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    public static func tokenLine(for run: TaskRunRecord) -> String? {
        var pieces: [String] = []
        if let input = run.inputTokens { pieces.append("in \(compact(input))") }
        if let cached = run.cachedTokens { pieces.append("cached \(compact(cached))") }
        if let output = run.outputTokens { pieces.append("out \(compact(output))") }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    private static func compact(_ value: Int) -> String {
        value >= 10_000 ? "\(value / 1_000)k" : String(value)
    }
}

public struct TaskPlanChecklist: Sendable, Equatable {
    public let done: [String]
    public let remaining: [String]
    public let handoffExcerpt: String?
    public let progress: PlanProgress?

    public static func scan(_ document: String) -> TaskPlanChecklist {
        var done: [String] = []
        var remaining: [String] = []
        var handoffLines: [String] = []
        var inHandoff = false
        for line in document.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.lowercased() == "## handoff" {
                inHandoff = true
                continue
            }
            if inHandoff, value.hasPrefix("#") {
                inHandoff = false
            } else if inHandoff, !value.isEmpty {
                handoffLines.append(value)
            }
            guard value.count >= 5, value.hasPrefix("- ["), value[value.index(value.startIndex, offsetBy: 4)] == "]" else {
                continue
            }
            let marker = value[value.index(value.startIndex, offsetBy: 3)]
            let text = value.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if marker == "x" || marker == "X" {
                done.append(text)
            } else if marker == " " {
                remaining.append(text)
            }
        }
        let handoff = handoffLines.isEmpty ? nil : String(handoffLines.joined(separator: "\n").prefix(2_000))
        return TaskPlanChecklist(
            done: done,
            remaining: remaining,
            handoffExcerpt: handoff,
            progress: PlanDocParser.parse(document)
        )
    }
}

public enum TaskLogTailReader {
    public static func lines(at url: URL, maxLines: Int = 500) async -> [String] {
        guard maxLines > 0 else { return [] }
        return await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            guard let length = try? handle.seekToEnd() else { return [] }
            let byteCount = min(length, 1_048_576)
            try? handle.seek(toOffset: length - byteCount)
            guard let data = try? handle.read(upToCount: Int(byteCount)) else { return [] }
            var lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if lines.last == "" { lines.removeLast() }
            if byteCount < length, !lines.isEmpty { lines.removeFirst() }
            return Array(lines.suffix(maxLines))
        }.value
    }
}

public enum TaskRunNowResult: Sendable, Equatable {
    case started
    case queued(reason: String)
    case blocked(reason: String)

    public var feedback: String {
        switch self {
        case .started: "Started"
        case let .queued(reason): "Queued — \(reason)"
        case let .blocked(reason): reason
        }
    }
}

public enum TaskBoardCardGroup: String, Sendable {
    case regular
    case attention
}

public enum TaskBoardCardIdentity {
    public static func value(taskID: UUID, group: TaskBoardCardGroup) -> String {
        "\(group.rawValue)-\(taskID.uuidString)"
    }
}

public enum TaskAccountLabel {
    public static func compact(_ alias: String, maximumLength: Int = 18) -> String {
        let limit = max(8, maximumLength)
        guard alias.count > limit else { return alias }
        let suffixCount = max(4, limit / 3)
        let prefixCount = limit - suffixCount - 1
        return "\(alias.prefix(prefixCount))…\(alias.suffix(suffixCount))"
    }
}

public enum TaskCardChipLayout {
    public static func rows<Value>(for values: [Value], maximumPerRow: Int = 2) -> [[Value]] {
        let rowSize = max(1, maximumPerRow)
        return stride(from: 0, to: values.count, by: rowSize).map { start in
            Array(values[start..<min(start + rowSize, values.count)])
        }
    }
}

public enum TaskCardPresentation {
    public static func showsWaitingReason(column: TaskColumn, phase: TaskPhase, reason: String?) -> Bool {
        if phase == .pausedQuota || phase == .retryWaiting { return true }
        return column == .queued && phase == .idle && reason?.isEmpty == false
    }
}

public struct TaskBoardWindowSizing: Sendable, Equatable {
    public let initialWidth: Double
    public let initialHeight: Double
    public let minimumWidth: Double
    public let minimumHeight: Double

    public static func resolve(visibleWidth: Double, visibleHeight: Double) -> TaskBoardWindowSizing {
        let availableWidth = max(1, visibleWidth - 40)
        let availableHeight = max(1, visibleHeight - 40)
        return TaskBoardWindowSizing(
            initialWidth: min(1_420, availableWidth),
            initialHeight: min(760, availableHeight),
            minimumWidth: min(840, availableWidth),
            minimumHeight: min(560, availableHeight)
        )
    }
}

public enum TaskBoardMenuStatus {
    public static func nextQuotaReset(
        tasks: [AutomationTask],
        schedulingReasons: [String: String],
        accounts: [Account],
        globalAliases: [String],
        now: Date
    ) -> Date? {
        guard !tasks.contains(where: { $0.phase == .planning || $0.phase == .running }) else { return nil }
        let waiting = tasks.filter {
            ($0.column == .queued && $0.phase == .idle)
                || ($0.column == .inProgress && ($0.phase == .pausedQuota || $0.phase == .retryWaiting))
        }
        guard !waiting.isEmpty else { return nil }
        guard waiting.allSatisfy({ task in
            if task.phase == .retryWaiting { return true }
            guard let reason = schedulingReasons[task.id.uuidString]?.lowercased() else { return false }
            return reason.contains("cooldown") || reason.contains("quota") || reason.contains("banked window")
        }) else { return nil }
        return waiting.compactMap { task in
            TaskSchedulingReasonFormatter.nextDeadline(
                task: task,
                aliases: task.accountAliases.isEmpty ? globalAliases : task.accountAliases,
                accounts: accounts,
                now: now
            )
        }.min()
    }
}

public enum TaskBoardWaitingHeader {
    public static func text(
        waitingTaskIDs: [UUID],
        schedulingReasons: [String: String]
    ) -> String {
        let count = waitingTaskIDs.count
        guard count > 0 else { return "Idle" }
        let categories = waitingTaskIDs.map { taskID in
            category(for: schedulingReasons[taskID.uuidString])
        }
        let counts = categories.reduce(into: [ReasonCategory: Int]()) { result, category in
            result[category, default: 0] += 1
        }
        guard let maximum = counts.values.max() else { return "\(count) waiting" }
        let mostCommon = counts.filter { $0.value == maximum }.map(\.key)
        guard mostCommon.count == 1, let category = mostCommon.first, category != .other else {
            return "\(count) waiting"
        }

        switch category {
        case .automation:
            return "Automation off — \(count) queued"
        case .proxy:
            return "Waiting for proxy — \(count) queued"
        case .concurrency:
            return "Waiting for a run slot — \(count) queued"
        case .repository:
            return "Waiting for repository — \(count) queued"
        case .account:
            return "Waiting for an account — \(count) queued"
        case .quota:
            return "Waiting for quota — \(count) queued"
        case .retry:
            return "Waiting to retry — \(count) queued"
        case .other:
            return "\(count) waiting"
        }
    }

    private enum ReasonCategory: Hashable {
        case automation
        case proxy
        case concurrency
        case repository
        case account
        case quota
        case retry
        case other
    }

    private static func category(for reason: String?) -> ReasonCategory {
        guard let reason else { return .other }
        let value = reason.lowercased()
        if value.contains("automation is disabled") { return .automation }
        if value.contains("proxy is unavailable") { return .proxy }
        if value.contains("available run slot") { return .concurrency }
        if value.contains("repository is busy") { return .repository }
        if value.contains("no accounts") || value.contains("needs login") || value.contains("unknown account") {
            return .account
        }
        if value.contains("retry") || value.contains("backoff") { return .retry }
        if value.contains("cooldown") || value.contains("quota") || value.contains("banked window")
            || value.contains("over threshold") || value.contains("headroom<") {
            return .quota
        }
        return .other
    }
}
