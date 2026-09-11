import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DiagnosticComponent: String, Codable, CaseIterable, Sendable {
    case app
    case proxy
    case routing
    case accounts
    case quota
    case warmup
    case tasks
    case alpha
    case settings
    case storage
    case notifications
    case diagnostics
}

public enum DiagnosticOperation: String, Codable, CaseIterable, Sendable {
    case lifecycle
    case request
    case selection
    case authentication
    case importAccounts = "import_accounts"
    case usageFetch = "usage_fetch"
    case reset
    case warmup
    case taskRun = "task_run"
    case taskQueue = "task_queue"
    case configuration
    case persistence
    case notification
    case export
}

public enum DiagnosticOutcome: String, Codable, CaseIterable, Sendable {
    case started
    case succeeded
    case failed
    case cancelled
    case skipped
    case retrying
    case changed
}

public enum DiagnosticCode: String, Codable, CaseIterable, Sendable {
    case none
    case unknown
    case io
    case network
    case timeout
    case unauthorized
    case revoked
    case rateLimited = "rate_limited"
    case invalidInput = "invalid_input"
    case notFound = "not_found"
    case busy
    case unavailable
    case staleSnapshot = "stale_snapshot"

    public static func classify(_ error: Error) -> DiagnosticCode {
        if let error = error as? UsageClient.UsageError {
            switch error {
            case .unauthorized:
                return .unauthorized
            case .http(let status) where status == 401 || status == 403:
                return .unauthorized
            case .http(let status) where status == 429:
                return .rateLimited
            case .http(let status) where (500...599).contains(status):
                return .unavailable
            case .http:
                return .network
            case .malformed:
                return .invalidInput
            }
        }
        if error is CancellationError {
            return .none
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut:
                return .timeout
            case .userAuthenticationRequired:
                return .unauthorized
            case .fileDoesNotExist:
                return .notFound
            default:
                return .network
            }
        }
        if let error = error as? POSIXError {
            switch error.code {
            case .EACCES, .EPERM:
                return .unauthorized
            case .EBUSY:
                return .busy
            case .ETIMEDOUT:
                return .timeout
            case .ENOENT:
                return .notFound
            default:
                return .io
            }
        }
        if let error = error as? CocoaError {
            switch error.code {
            case .fileNoSuchFile:
                return .notFound
            case .fileReadNoPermission, .fileWriteNoPermission:
                return .unauthorized
            default:
                return .io
            }
        }
        return .unknown
    }
}

public enum DiagnosticLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case debug
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

private let diagnosticsProcessSessionID = UUID()
private let diagnosticsMinimumTimestamp = Date(timeIntervalSince1970: -2_208_988_800)
private let diagnosticsMaximumTimestamp = Date(timeIntervalSince1970: 253_402_300_799)

public struct DiagnosticRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let processSessionID: UUID
    public let component: DiagnosticComponent
    public let operation: DiagnosticOperation
    public let outcome: DiagnosticOutcome
    public let level: DiagnosticLevel
    public let code: DiagnosticCode
    public let correlationID: UUID?
    public let status: Int?
    public let durationMilliseconds: Int?
    public let count: Int?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        processSessionID: UUID? = nil,
        component: DiagnosticComponent,
        operation: DiagnosticOperation,
        outcome: DiagnosticOutcome,
        level: DiagnosticLevel = .info,
        code: DiagnosticCode = .none,
        correlationID: UUID? = nil,
        status: Int? = nil,
        durationMilliseconds: Int? = nil,
        count: Int? = nil
    ) {
        self.id = id
        self.timestamp = Self.boundTimestamp(timestamp)
        self.processSessionID = processSessionID ?? diagnosticsProcessSessionID
        self.component = component
        self.operation = operation
        self.outcome = outcome
        self.level = level
        self.code = code
        self.correlationID = correlationID
        self.status = Self.boundStatus(status)
        self.durationMilliseconds = Self.boundDuration(durationMilliseconds)
        self.count = Self.boundCount(count)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case processSessionID
        case component
        case operation
        case outcome
        case level
        case code
        case correlationID
        case status
        case durationMilliseconds
        case count
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(Self.timestampString(timestamp), forKey: .timestamp)
        try container.encode(processSessionID, forKey: .processSessionID)
        try container.encode(component, forKey: .component)
        try container.encode(operation, forKey: .operation)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(level, forKey: .level)
        try container.encode(code, forKey: .code)
        try container.encodeIfPresent(correlationID, forKey: .correlationID)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encodeIfPresent(count, forKey: .count)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try Self.decodeTimestamp(from: container)
        processSessionID = try container.decode(UUID.self, forKey: .processSessionID)
        component = try container.decode(DiagnosticComponent.self, forKey: .component)
        operation = try container.decode(DiagnosticOperation.self, forKey: .operation)
        outcome = try container.decode(DiagnosticOutcome.self, forKey: .outcome)
        level = try container.decode(DiagnosticLevel.self, forKey: .level)
        code = try container.decode(DiagnosticCode.self, forKey: .code)
        correlationID = try container.decodeIfPresent(UUID.self, forKey: .correlationID)
        status = Self.boundStatus(try container.decodeIfPresent(Int.self, forKey: .status))
        durationMilliseconds = Self.boundDuration(try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds))
        count = Self.boundCount(try container.decodeIfPresent(Int.self, forKey: .count))
    }

    private static func decodeTimestamp(from container: KeyedDecodingContainer<CodingKeys>) throws -> Date {
        if let value = try? container.decode(String.self, forKey: .timestamp), let date = date(from: value) {
            guard (diagnosticsMinimumTimestamp...diagnosticsMaximumTimestamp).contains(date) else {
                throw DecodingError.dataCorruptedError(forKey: .timestamp, in: container, debugDescription: "Timestamp outside diagnostic bounds")
            }
            return date
        }
        if let value = try? container.decode(Double.self, forKey: .timestamp), value.isFinite {
            let date = Date(timeIntervalSinceReferenceDate: value)
            guard date.timeIntervalSince1970.isFinite,
                  (diagnosticsMinimumTimestamp...diagnosticsMaximumTimestamp).contains(date) else {
                throw DecodingError.dataCorruptedError(forKey: .timestamp, in: container, debugDescription: "Timestamp outside diagnostic bounds")
            }
            return date
        }
        throw DecodingError.dataCorruptedError(forKey: .timestamp, in: container, debugDescription: "Invalid diagnostic timestamp")
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }

    private static func boundStatus(_ value: Int?) -> Int? {
        guard let value, (100...599).contains(value) else { return nil }
        return value
    }

    private static func boundTimestamp(_ value: Date) -> Date {
        guard value.timeIntervalSince1970.isFinite else { return Date() }
        return min(max(value, diagnosticsMinimumTimestamp), diagnosticsMaximumTimestamp)
    }

    private static func boundDuration(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return min(value, 86_400_000)
    }

    private static func boundCount(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return min(value, 1_000_000)
    }
}

public struct DiagnosticSnapshot: Codable, Equatable, Sendable {
    public let records: [DiagnosticRecord]
    public let writeFailures: Int
    public let droppedRecords: Int
    public let readFailures: Int
    public let retentionBytes: Int
    public let truncated: Bool

    public init(
        records: [DiagnosticRecord],
        writeFailures: Int,
        droppedRecords: Int,
        readFailures: Int,
        retentionBytes: Int,
        truncated: Bool
    ) {
        self.records = records
        self.writeFailures = writeFailures
        self.droppedRecords = droppedRecords
        self.readFailures = readFailures
        self.retentionBytes = retentionBytes
        self.truncated = truncated
    }
}

public final class DiagnosticsLog: @unchecked Sendable {
    public static let shared = DiagnosticsLog()

    private static let maximumSegmentBytes = 2_097_152
    private static let maximumRetainedFiles = 4
    private static let maximumSnapshotRecords = 10_000
    private static let maximumReadBytesPerFile = maximumSegmentBytes
    private static let maximumRecordBytes = 4_096

    private let url: URL
    private let maxBytes: Int
    private let retainedFiles: Int
    private let stateLock = NSLock()
    private var writeFailureCount = 0
    private var droppedRecordCount = 0
    private var readFailureCount = 0

    public init(
        url: URL = AppPaths.supportDir().appendingPathComponent("diagnostics-v1.jsonl"),
        maxBytes: Int = 2_097_152,
        retainedFiles: Int = 4
    ) {
        self.url = url
        self.maxBytes = min(max(maxBytes, 1), Self.maximumSegmentBytes)
        self.retainedFiles = min(max(retainedFiles, 1), Self.maximumRetainedFiles)
    }

    public func record(
        component: DiagnosticComponent,
        operation: DiagnosticOperation,
        outcome: DiagnosticOutcome,
        level: DiagnosticLevel = .info,
        code: DiagnosticCode = .none,
        correlationID: UUID? = nil,
        status: Int? = nil,
        durationMilliseconds: Int? = nil,
        count: Int? = nil
    ) {
        let record = DiagnosticRecord(
            component: component,
            operation: operation,
            outcome: outcome,
            level: level,
            code: code,
            correlationID: correlationID,
            status: status,
            durationMilliseconds: durationMilliseconds,
            count: count
        )
        guard let data = try? Self.makeEncoder().encode(record) else {
            withStateLock { writeFailureCount += 1 }
            return
        }
        var line = data
        line.append(0x0A)
        guard line.count <= maxBytes else {
            withStateLock { droppedRecordCount += 1 }
            return
        }

        withStateLock {
            guard let directoryDescriptor = try? openDirectoryDescriptor(url.deletingLastPathComponent()) else {
                writeFailureCount += 1
                return
            }
            defer { close(directoryDescriptor) }
            switch acquireLock(directoryDescriptor: directoryDescriptor, nonBlocking: true) {
            case .acquired(let descriptor):
                defer {
                    _ = flock(descriptor, LOCK_UN)
                    close(descriptor)
                }
                do {
                    try ensureOwnedPaths(directoryDescriptor: directoryDescriptor)
                    try rotateIfNeeded(incomingBytes: line.count, directoryDescriptor: directoryDescriptor)
                    let fileDescriptor = try openActiveFile(directoryDescriptor: directoryDescriptor)
                    defer { close(fileDescriptor) }
                    try write(fileDescriptor: fileDescriptor, data: line)
                } catch {
                    writeFailureCount += 1
                }
            case .busy:
                droppedRecordCount += 1
            case .failed:
                writeFailureCount += 1
            }
        }
    }

    public func snapshot(
        limit: Int = 500,
        component: DiagnosticComponent? = nil,
        minimumLevel: DiagnosticLevel = .debug
    ) -> DiagnosticSnapshot {
        let boundedLimit = min(max(limit, 0), Self.maximumSnapshotRecords)
        var payloads: [Data] = []
        var truncated = false
        var localReadFailures = 0
        withStateLock {
            guard let directoryDescriptor = try? openDirectoryDescriptor(url.deletingLastPathComponent()) else {
                localReadFailures += 1
                truncated = true
                return
            }
            defer { close(directoryDescriptor) }
            switch acquireLock(directoryDescriptor: directoryDescriptor, nonBlocking: true) {
            case .acquired(let descriptor):
                defer {
                    _ = flock(descriptor, LOCK_UN)
                    close(descriptor)
                }
                do {
                    try ensureOwnedPaths(directoryDescriptor: directoryDescriptor)
                    for fileURL in readableURLs() where entryExists(fileURL.lastPathComponent, directoryDescriptor: directoryDescriptor) {
                        do {
                            let result = try readData(from: fileURL, directoryDescriptor: directoryDescriptor)
                            payloads.append(result.data)
                            truncated = truncated || result.truncated
                        } catch {
                            localReadFailures += 1
                        }
                    }
                } catch {
                    localReadFailures += 1
                    truncated = true
                }
            case .busy, .failed:
                localReadFailures += 1
                truncated = true
            }
        }

        var records: [DiagnosticRecord] = []
        let decoder = Self.makeDecoder()
        for data in payloads {
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.utf8.count <= Self.maximumRecordBytes,
                      let record = try? decoder.decode(DiagnosticRecord.self, from: Data(line.utf8)) else {
                    localReadFailures += 1
                    continue
                }
                records.append(record)
            }
        }
        records = records.filter { record in
            (component == nil || record.component == component) && record.level >= minimumLevel
        }
        records.sort { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.timestamp < rhs.timestamp
        }
        if records.count > boundedLimit {
            records = Array(records.suffix(boundedLimit))
            truncated = true
        }
        return withStateLock {
            readFailureCount += localReadFailures
            return makeSnapshot(records: records, truncated: truncated)
        }
    }

    public func exportData(limit: Int = 2_000) throws -> Data {
        let snapshot = snapshot(limit: limit)
        let envelope = DiagnosticExportEnvelope(
            schemaVersion: 1,
            currentTime: Self.timestampString(Date()),
            records: snapshot.records,
            writeFailures: snapshot.writeFailures,
            droppedRecords: snapshot.droppedRecords,
            readFailures: snapshot.readFailures,
            retentionBytes: snapshot.retentionBytes,
            truncated: snapshot.truncated
        )
        return try Self.makeEncoder().encode(envelope)
    }

    private func makeSnapshot(records: [DiagnosticRecord], truncated: Bool) -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            records: records,
            writeFailures: writeFailureCount,
            droppedRecords: droppedRecordCount,
            readFailures: readFailureCount,
            retentionBytes: maxBytes * retainedFiles,
            truncated: truncated
        )
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private enum LockAcquisition {
        case acquired(Int32)
        case busy
        case failed
    }

    private func acquireLock(directoryDescriptor: Int32, nonBlocking: Bool) -> LockAcquisition {
        let descriptor = openat(directoryDescriptor, lockFileName, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return .failed }
        guard fstatRegular(descriptor) else {
            close(descriptor)
            return .failed
        }
        _ = fchmod(descriptor, mode_t(0o600))
        let flags = nonBlocking ? LOCK_EX | LOCK_NB : LOCK_EX
        guard flock(descriptor, flags) == 0 else {
            let errorCode = errno
            close(descriptor)
            if nonBlocking && (errorCode == EWOULDBLOCK || errorCode == EAGAIN) {
                return .busy
            }
            return .failed
        }
        return .acquired(descriptor)
    }

    private func ensureOwnedPaths(directoryDescriptor: Int32) throws {
        for name in [fileName, lockFileName] + rotationNames {
            try ensureOwnedEntry(name, directoryDescriptor: directoryDescriptor)
        }
    }

    private func openDirectoryDescriptor(_ directory: URL) throws -> Int32 {
        var normalizedDirectory = directory.standardizedFileURL
        for name in ["var", "tmp", "etc"] {
            let prefix = "/" + name
            guard normalizedDirectory.path.hasPrefix(prefix + "/") else { continue }
            var info = stat()
            if lstat(prefix, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK, info.st_uid == 0,
               let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix),
               destination == "private/" + name || destination == "/private/" + name {
                normalizedDirectory = URL(fileURLWithPath: "/private" + normalizedDirectory.path, isDirectory: true)
            }
        }
        let components = normalizedDirectory.pathComponents.drop { $0 == "/" }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DiagnosticsLogError.io }
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next >= 0 {
                close(descriptor)
                descriptor = next
                continue
            }
            guard errno == ENOENT else {
                close(descriptor)
                throw DiagnosticsLogError.io
            }
            guard mkdirat(descriptor, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                close(descriptor)
                throw DiagnosticsLogError.io
            }
            let created = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard created >= 0 else {
                close(descriptor)
                throw DiagnosticsLogError.unsafePath
            }
            close(descriptor)
            descriptor = created
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              fchmod(descriptor, mode_t(0o700)) == 0 else {
            close(descriptor)
            throw DiagnosticsLogError.unsafePath
        }
        return descriptor
    }

    private func ensureOwnedEntry(_ name: String, directoryDescriptor: Int32) throws {
        var info = stat()
        guard fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw DiagnosticsLogError.io
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == geteuid() else {
            throw DiagnosticsLogError.unsafePath
        }
    }

    private func rotateIfNeeded(incomingBytes: Int, directoryDescriptor: Int32) throws {
        let activeDescriptor = openat(directoryDescriptor, fileName, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard activeDescriptor >= 0 else {
            if errno == ENOENT { return }
            throw DiagnosticsLogError.io
        }
        defer { close(activeDescriptor) }
        guard fstatRegular(activeDescriptor) else { throw DiagnosticsLogError.unsafePath }
        let size = try fileSize(activeDescriptor)
        guard size <= maxBytes else { throw DiagnosticsLogError.oversizedFile }
        guard size > 0, size + incomingBytes > maxBytes else { return }
        if retainedFiles == 1 {
            guard ftruncate(activeDescriptor, 0) == 0 else { throw DiagnosticsLogError.io }
            return
        }

        for name in rotationNames.reversed() {
            try ensureOwnedEntry(name, directoryDescriptor: directoryDescriptor)
        }
        if retainedFiles > 1 {
            if retainedFiles > 2 {
                for index in stride(from: retainedFiles - 1, through: 2, by: -1) {
                    let source = rotationName(index: index - 1)
                    let destination = rotationName(index: index)
                    if entryExists(destination, directoryDescriptor: directoryDescriptor) {
                        guard unlinkat(directoryDescriptor, destination, 0) == 0 else { throw DiagnosticsLogError.io }
                    }
                    if entryExists(source, directoryDescriptor: directoryDescriptor) {
                        guard renameat(directoryDescriptor, source, directoryDescriptor, destination) == 0 else {
                            throw DiagnosticsLogError.io
                        }
                    }
                }
            }
            let first = rotationName(index: 1)
            if entryExists(first, directoryDescriptor: directoryDescriptor) {
                guard unlinkat(directoryDescriptor, first, 0) == 0 else { throw DiagnosticsLogError.io }
            }
            guard renameat(directoryDescriptor, fileName, directoryDescriptor, first) == 0 else {
                throw DiagnosticsLogError.io
            }
        }
    }

    private func openActiveFile(directoryDescriptor: Int32) throws -> Int32 {
        let descriptor = openat(directoryDescriptor, fileName, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw DiagnosticsLogError.io }
        guard fstatRegular(descriptor) else {
            close(descriptor)
            throw DiagnosticsLogError.unsafePath
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            throw DiagnosticsLogError.io
        }
        let size = try fileSize(descriptor)
        guard size <= maxBytes else {
            close(descriptor)
            throw DiagnosticsLogError.oversizedFile
        }
        return descriptor
    }

    private func write(fileDescriptor: Int32, data: Data) throws {
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func readData(from fileURL: URL, directoryDescriptor: Int32) throws -> (data: Data, truncated: Bool) {
        let descriptor = openat(directoryDescriptor, fileURL.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DiagnosticsLogError.io }
        defer { close(descriptor) }
        guard fstatRegular(descriptor) else { throw DiagnosticsLogError.unsafePath }
        let fileSize = try fileSize(descriptor)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let readBytes = min(fileSize, Self.maximumReadBytesPerFile)
        let data = try handle.read(upToCount: readBytes) ?? Data()
        return (data, fileSize > readBytes)
    }

    private var fileName: String { url.lastPathComponent }

    private var lockFileName: String { "." + fileName + ".lock" }

    private var rotationNames: [String] {
        (1..<retainedFiles).map { rotationName(index: $0) }
    }

    private var rotationURLs: [URL] {
        (1..<retainedFiles).map { rotationURL(index: $0) }
    }

    private func rotationURL(index: Int) -> URL {
        url.appendingPathExtension(String(index))
    }

    private func rotationName(index: Int) -> String {
        fileName + "." + String(index)
    }

    private func readableURLs() -> [URL] {
        rotationURLs.reversed() + [url]
    }

    private func fileSize(_ descriptor: Int32) throws -> Int {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw DiagnosticsLogError.io }
        let value = Int(info.st_size)
        guard value >= 0 else { throw DiagnosticsLogError.io }
        return value
    }

    private func entryExists(_ name: String, directoryDescriptor: Int32) -> Bool {
        var info = stat()
        return fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    private func fstatRegular(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_nlink == 1
            && info.st_uid == geteuid()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private struct DiagnosticExportEnvelope: Codable {
    let schemaVersion: Int
    let currentTime: String
    let records: [DiagnosticRecord]
    let writeFailures: Int
    let droppedRecords: Int
    let readFailures: Int
    let retentionBytes: Int
    let truncated: Bool
}

private enum DiagnosticsLogError: Error {
    case io
    case unsafePath
    case oversizedFile
}
