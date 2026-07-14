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
    case queued
    case blocked(reason: String)

    public var feedback: String {
        switch self {
        case .started: "Started"
        case .queued: "Queued"
        case let .blocked(reason): reason
        }
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
