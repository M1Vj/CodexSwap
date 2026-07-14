import Foundation

public struct GitRepositoryState: Sendable, Equatable {
    public let headSHA: String
    public let branch: String
}

public struct GitCommitSummary: Sendable, Equatable, Identifiable {
    public let sha: String
    public let subject: String

    public var id: String { sha }
}

public struct GitChangeSummary: Sendable, Equatable {
    public let commits: [GitCommitSummary]
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int
    public let isTruncated: Bool
}

public enum GitProbe {
    private static let maximumOutputBytes = 65_536

    public static func repositoryState(at repositoryPath: String) async -> GitRepositoryState? {
        async let head = run(at: repositoryPath, arguments: ["rev-parse", "HEAD"])
        async let branch = run(at: repositoryPath, arguments: ["rev-parse", "--abbrev-ref", "HEAD"])
        guard let headValue = await head?.trimmingCharacters(in: .whitespacesAndNewlines),
              let branchValue = await branch?.trimmingCharacters(in: .whitespacesAndNewlines),
              isSHA(headValue), !branchValue.isEmpty else { return nil }
        return GitRepositoryState(headSHA: headValue, branch: branchValue)
    }

    public static func changes(
        at repositoryPath: String,
        baseSHA: String,
        headSHA: String,
        commitLimit: Int = 50
    ) async -> GitChangeSummary? {
        guard isSHA(baseSHA), isSHA(headSHA) else { return nil }
        let limit = max(1, min(commitLimit, 100))
        let range = "\(baseSHA)..\(headSHA)"
        async let log = run(
            at: repositoryPath,
            arguments: ["log", "--oneline", "--max-count=\(limit + 1)", range]
        )
        async let shortstat = run(at: repositoryPath, arguments: ["diff", "--shortstat", range])
        guard let logValue = await log, let statValue = await shortstat else { return nil }
        let lines = logValue.split(separator: "\n").map(String.init)
        let commits = lines.prefix(limit).compactMap(parseCommit)
        let stats = parseShortstat(statValue)
        return GitChangeSummary(
            commits: commits,
            filesChanged: stats.files,
            insertions: stats.insertions,
            deletions: stats.deletions,
            isTruncated: lines.count > limit
        )
    }

    private static func run(at repositoryPath: String, arguments: [String]) async -> String? {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-git-probe-\(UUID().uuidString).out")
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else { return nil }
        guard let output = try? FileHandle(forWritingTo: outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryPath] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { completed in
                continuation.yield(completed.terminationStatus)
                continuation.finish()
            }
        }
        do {
            try process.run()
            var iterator = termination.makeAsyncIterator()
            guard await iterator.next() == 0 else { return nil }
            try output.close()
            let reader = try FileHandle(forReadingFrom: outputURL)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: maximumOutputBytes + 1) ?? Data()
            guard data.count <= maximumOutputBytes else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private static func isSHA(_ value: String) -> Bool {
        (7...64).contains(value.count) && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }

    private static func parseCommit(_ line: String) -> GitCommitSummary? {
        guard let separator = line.firstIndex(of: " ") else { return nil }
        let sha = String(line[..<separator])
        let subject = String(line[line.index(after: separator)...])
        guard isSHA(sha), !subject.isEmpty else { return nil }
        return GitCommitSummary(sha: sha, subject: subject)
    }

    private static func parseShortstat(_ value: String) -> (files: Int, insertions: Int, deletions: Int) {
        (
            captureCount(in: value, pattern: #"(\d+) files? changed"#),
            captureCount(in: value, pattern: #"(\d+) insertions?\(\+\)"#),
            captureCount(in: value, pattern: #"(\d+) deletions?\(-\)"#)
        )
    }

    private static func captureCount(in value: String, pattern: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let range = Range(match.range(at: 1), in: value) else { return 0 }
        return Int(value[range]) ?? 0
    }
}
