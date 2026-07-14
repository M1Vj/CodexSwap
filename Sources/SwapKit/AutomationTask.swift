import Foundation

public enum TaskColumn: String, Codable, Sendable, CaseIterable {
    case todo
    case queued
    case inProgress
    case done
}

public enum TaskPhase: String, Codable, Sendable {
    case idle
    case planning
    case running
    case pausedQuota
    case failed
    case stopped
    case completed
}

public struct TaskRunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var outcome: String
    public var logFileName: String
    public var planDone: Int?
    public var planTotal: Int?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        exitCode: Int32? = nil,
        outcome: String = "",
        logFileName: String = "",
        planDone: Int? = nil,
        planTotal: Int? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.outcome = outcome
        self.logFileName = logFileName
        self.planDone = planDone
        self.planTotal = planTotal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        logFileName = try c.decodeIfPresent(String.self, forKey: .logFileName) ?? ""
        planDone = try c.decodeIfPresent(Int.self, forKey: .planDone)
        planTotal = try c.decodeIfPresent(Int.self, forKey: .planTotal)
    }
}

public struct PlanProgress: Codable, Sendable, Equatable {
    public var done: Int
    public var total: Int
    public var status: String?

    public init(done: Int = 0, total: Int = 0, status: String? = nil) {
        self.done = done
        self.total = total
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }
}

public struct AutomationTask: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var prompt: String
    public var repoPath: String
    public var branch: String
    public var model: String
    public var reasoningEffort: String
    public var allowNetwork: Bool
    /// Evergreen tasks loop forever: a COMPLETE plan re-queues the task for the next quota
    /// window instead of retiring it to Done.
    public var isEvergreen: Bool
    public var accountAliases: [String]
    public var column: TaskColumn
    public var phase: TaskPhase
    public var orderIndex: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var runs: [TaskRunRecord]
    public var lastError: String?
    public var planProgress: PlanProgress?

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        repoPath: String,
        branch: String,
        model: String = "gpt-5.6-sol",
        reasoningEffort: String = "high",
        allowNetwork: Bool = false,
        isEvergreen: Bool = false,
        accountAliases: [String] = [],
        column: TaskColumn = .todo,
        phase: TaskPhase = .idle,
        orderIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        runs: [TaskRunRecord] = [],
        lastError: String? = nil,
        planProgress: PlanProgress? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.repoPath = repoPath
        self.branch = branch
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.allowNetwork = allowNetwork
        self.isEvergreen = isEvergreen
        self.accountAliases = accountAliases
        self.column = column
        self.phase = phase
        self.orderIndex = orderIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.runs = runs
        self.lastError = lastError
        self.planProgress = planProgress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "gpt-5.6-sol"
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? "high"
        allowNetwork = try c.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? false
        isEvergreen = try c.decodeIfPresent(Bool.self, forKey: .isEvergreen) ?? false
        accountAliases = try c.decodeIfPresent([String].self, forKey: .accountAliases) ?? []
        column = try c.decodeIfPresent(TaskColumn.self, forKey: .column) ?? .todo
        phase = try c.decodeIfPresent(TaskPhase.self, forKey: .phase) ?? .idle
        orderIndex = try c.decodeIfPresent(Int.self, forKey: .orderIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        runs = try c.decodeIfPresent([TaskRunRecord].self, forKey: .runs) ?? []
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        planProgress = try c.decodeIfPresent(PlanProgress.self, forKey: .planProgress)
    }

    public var planRelativePath: String {
        ".codexswap/tasks/\(slug)/PLAN.md"
    }

    public func taskDirURL(supportDir: URL) -> URL {
        supportDir
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private var slug: String {
        let mapped = title.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        var base = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        base = String(base.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "task" }
        return "\(base)-\(id.uuidString.lowercased().prefix(8))"
    }
}

public enum PlanDocParser {
    public static func parse(_ text: String) -> PlanProgress? {
        var done = 0
        var total = 0
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            if let marker = capture(in: line, pattern: #"^\s*-\s+\[([ x])\]"#) {
                total += 1
                if marker.caseInsensitiveCompare("x") == .orderedSame { done += 1 }
            }
        }
        let lastLine = lines.last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let status = lastLine
            .flatMap { capture(in: $0, pattern: #"^\s*(?:\*\*)?STATUS:(?:\*\*)?\s*([A-Z]+)"#) }
            .map { $0.uppercased() }

        guard total > 0 || status != nil else { return nil }
        return PlanProgress(done: done, total: total, status: status)
    }

    private static func capture(in line: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[valueRange])
    }
}
