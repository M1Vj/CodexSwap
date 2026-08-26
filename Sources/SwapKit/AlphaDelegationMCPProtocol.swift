import Foundation
import Darwin

/// The intentionally narrow tool exposed by the local Alpha delegation server.
public enum AlphaDelegationMCPToolName: String, CaseIterable, Codable, Sendable {
    case review = "codexswap_alpha_review"
    // Kept as a source-compatibility marker for callers compiled against the
    // pre-review-only API. It is intentionally not advertised or dispatched.
    case edit = "codexswap_alpha_edit"
}

/// A small, lossless-enough JSON value used by the protocol boundary.
///
/// Numbers are represented as `Decimal` so identifiers and structured results do
/// not need to pass through `Double` before they are written back to JSON.
public enum AlphaDelegationMCPJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([AlphaDelegationMCPJSONValue])
    case object([String: AlphaDelegationMCPJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Decimal.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AlphaDelegationMCPJSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: AlphaDelegationMCPJSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

/// JSON-RPC identifiers. A null identifier is retained for parse/invalid-request
/// responses, while normal notifications simply omit an identifier.
public enum AlphaDelegationMCPJSONRPCID: Codable, Sendable, Equatable {
    case string(String)
    case number(Decimal)
    case null

    public init(string: String) {
        self = .string(string)
    }

    public init(number: Int64) {
        self = .number(Decimal(number))
    }

    public init(number: Double) {
        self = .number(Decimal(number))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Decimal.self) {
            self = .number(number)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be a string, number, or null"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public typealias MCPJSONRPCID = AlphaDelegationMCPJSONRPCID
public typealias MCPJSONValue = AlphaDelegationMCPJSONValue

public enum AlphaDelegationMCPCodecError: Error, Equatable, Sendable {
    case malformed
    case oversized
}

/// Pure newline-delimited JSON codec shared by the dispatcher and a future
/// executable transport.
public enum AlphaDelegationMCPJSONRPCCodec {
    /// A 32 KiB UTF-8 task can expand to six ASCII bytes per source byte when
    /// JSON escapes control characters. This 256 KiB frame bound leaves room
    /// for the JSON-RPC envelope and its trailing newline.
    public static let maxInboundFrameBytes = 256 * 1024

    /// Compatibility name for callers that used the previous line-limit API.
    public static let maxLineBytes = maxInboundFrameBytes

    @inline(__always)
    static func trimJSONWhitespace(_ data: Data) -> Data {
        var start = data.startIndex
        var end = data.endIndex
        while start < end, isJSONWhitespace(data[start]) {
            start += 1
        }
        while end > start, isJSONWhitespace(data[end - 1]) {
            end -= 1
        }
        return Data(data[start..<end])
    }

    @inline(__always)
    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    public static func decode(_ line: Data) throws -> AlphaDelegationMCPJSONValue {
        guard line.count <= maxInboundFrameBytes else { throw AlphaDelegationMCPCodecError.oversized }
        let normalized = trimJSONWhitespace(line)
        guard !normalized.isEmpty,
              let value = try? JSONDecoder().decode(AlphaDelegationMCPJSONValue.self, from: normalized) else {
            throw AlphaDelegationMCPCodecError.malformed
        }
        return value
    }

    public static func encode(_ value: AlphaDelegationMCPJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw AlphaDelegationMCPCodecError.malformed
        }
        data.append(0x0A)
        guard data.count <= maxInboundFrameBytes else { throw AlphaDelegationMCPCodecError.oversized }
        return data
    }
}

/// The result returned by an injected tool handler.
public struct AlphaDelegationMCPToolResult: Codable, Sendable, Equatable {
    public let text: String
    public let structuredContent: [String: AlphaDelegationMCPJSONValue]
    public let isError: Bool

    public init(
        text: String,
        structuredContent: [String: AlphaDelegationMCPJSONValue] = [:],
        isError: Bool = false
    ) {
        self.text = text
        self.structuredContent = structuredContent
        self.isError = isError
    }

    public static func success(
        text: String,
        structuredContent: [String: AlphaDelegationMCPJSONValue] = [:]
    ) -> Self {
        Self(text: text, structuredContent: structuredContent, isError: false)
    }

    public static func failure(
        text: String = "Tool execution failed.",
        structuredContent: [String: AlphaDelegationMCPJSONValue] = [:]
    ) -> Self {
        Self(text: text, structuredContent: structuredContent, isError: true)
    }
}

public typealias AlphaDelegationMCPToolHandler = @Sendable (
    AlphaDelegationMCPToolName,
    String
) async throws -> AlphaDelegationMCPToolResult

/// A serialized output sink. Implementations must write the supplied line as-is;
/// the server already appends the newline required by the stdio transport.
public protocol AlphaDelegationMCPWriter: Sendable {
    func write(_ data: Data) async throws
}

public enum AlphaDelegationMCPStdioWriterError: Error, Equatable, Sendable {
    case descriptorUnavailable
    case closed
    case writeFailed(Int32)
}

/// Serialized stdout writer that keeps pipe writes cancellable.
public actor AlphaDelegationMCPStdioWriter: AlphaDelegationMCPWriter {
    private let output: FileHandle?
    private let descriptor: Int32
    private var closed = false

    public init(output: FileHandle = .standardOutput) {
        let ownedDescriptor = Darwin.dup(output.fileDescriptor)
        var descriptor = Int32(-1)
        var ownedOutput: FileHandle? = nil
        if ownedDescriptor >= 0 {
            let originalFlags = fcntl(ownedDescriptor, F_GETFL)
            let configured = originalFlags >= 0
                && fcntl(ownedDescriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0
                && fcntl(ownedDescriptor, F_SETFD, FD_CLOEXEC) == 0
                && fcntl(ownedDescriptor, F_SETNOSIGPIPE, 1) == 0
            if configured {
                descriptor = ownedDescriptor
                ownedOutput = FileHandle(fileDescriptor: ownedDescriptor, closeOnDealloc: true)
            } else {
                if originalFlags >= 0 {
                    _ = fcntl(ownedDescriptor, F_SETFL, originalFlags)
                }
                _ = Darwin.close(ownedDescriptor)
            }
        }
        self.descriptor = descriptor
        self.output = ownedOutput
    }

    public func write(_ data: Data) async throws {
        guard descriptor >= 0 else {
            throw AlphaDelegationMCPStdioWriterError.descriptorUnavailable
        }
        guard !closed else {
            throw AlphaDelegationMCPStdioWriterError.closed
        }

        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard !closed else {
                throw AlphaDelegationMCPStdioWriterError.closed
            }

            let written = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                try await waitUntilWritable()
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try await waitUntilWritable()
                continue
            }
            throw AlphaDelegationMCPStdioWriterError.writeFailed(errno)
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        try? output?.close()
    }

    private func waitUntilWritable() async throws {
        while true {
            try Task.checkCancellation()
            var descriptorEvents = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT | POLLERR | POLLHUP),
                revents: 0
            )
            let result = Darwin.poll(&descriptorEvents, 1, 50)
            if result > 0 {
                if descriptorEvents.revents & Int16(POLLNVAL) != 0 {
                    throw AlphaDelegationMCPStdioWriterError.closed
                }
                if descriptorEvents.revents & Int16(POLLERR | POLLHUP | POLLOUT) != 0 {
                    return
                }
            } else if result < 0, errno != EINTR {
                throw AlphaDelegationMCPStdioWriterError.writeFailed(errno)
            }
        }
    }
}

/// Synchronous, lock-protected request registry. The stdio reader can continue
/// accepting cancellation and ping messages while a tool task is suspended.
private final class AlphaDelegationMCPRequestRegistry: @unchecked Sendable {
    enum Reservation: Equatable {
        case admitted
        case duplicate
        case busy
    }

    private let lock = NSLock()
    private let maximumActiveTasks: Int
    private var tasks: [String: Task<AlphaDelegationMCPToolResult, Never>] = [:]
    private var cancelled: Set<String> = []
    private var reserved: Set<String> = []

    init(maximumActiveTasks: Int) {
        self.maximumActiveTasks = max(1, maximumActiveTasks)
    }

    func reserve(_ key: String) -> Reservation {
        lock.lock()
        defer { lock.unlock() }
        guard !reserved.contains(key), tasks[key] == nil else { return .duplicate }
        guard reserved.count + tasks.count < maximumActiveTasks else { return .busy }
        reserved.insert(key)
        return .admitted
    }

    func attach(_ key: String, task: Task<AlphaDelegationMCPToolResult, Never>) {
        lock.lock()
        defer { lock.unlock() }
        reserved.remove(key)
        tasks[key] = task
        if cancelled.contains(key) {
            task.cancel()
        }
    }

    func cancel(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard reserved.contains(key) || tasks[key] != nil else { return }
        cancelled.insert(key)
        tasks[key]?.cancel()
    }

    /// Cancels every admitted or pre-reserved request. Reservations remain
    /// visible until their owning handler calls `finish`/`abandon`, preventing
    /// a late attach from racing a new request with the same ID.
    func cancelAll() {
        lock.lock()
        let keys = reserved.union(tasks.keys)
        cancelled.formUnion(keys)
        let activeTasks = tasks.values
        lock.unlock()
        activeTasks.forEach { $0.cancel() }
    }

    /// Releases a reservation on every early-return path. If a task was
    /// attached before its owner was cancelled, cancel it before removing it.
    func abandon(_ key: String) {
        lock.lock()
        reserved.remove(key)
        let task = tasks.removeValue(forKey: key)
        cancelled.remove(key)
        lock.unlock()
        task?.cancel()
    }

    func finish(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        reserved.remove(key)
        tasks.removeValue(forKey: key)
        return cancelled.remove(key) != nil
    }
}

private final class AlphaDelegationMCPAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pending < limit else { return false }
        pending += 1
        return true
    }

    func release() {
        lock.lock()
        pending = max(0, pending - 1)
        lock.unlock()
    }
}

/// Records a writer/transport failure raised by a detached tool response so
/// the reader loop can stop admitting work and tear down the registry.
private final class AlphaDelegationMCPServeState: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?

    func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    func storedFailure() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Waits for a transport/child failure without relying on an unstructured
    /// task. Polling is intentionally short and cancellation-aware so an open
    /// stdin sequence cannot keep `serve` alive after a writer failure.
    func waitForFailure() async throws -> Error {
        while !Task.isCancelled {
            if let failure = storedFailure() {
                return failure
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }
}

/// Minimal newline-delimited JSON-RPC 2.0 MCP server for local Alpha delegation.
///
/// The type is intentionally transport-agnostic: a future executable can feed
/// stdin lines into `serve`, while unit tests and other transports can call
/// `handle(line:)` directly.
public struct AlphaDelegationMCPServer: Sendable {
    public static let currentProtocolVersion = "2025-06-18"
    public static let fallbackProtocolVersion = "2024-11-05"
    public static let maxInboundLineBytes = AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes
    public static let maxOutboundLineBytes = 64 * 1024
    public static let maxTaskBytes = 32 * 1024
    public static let maxActiveToolCalls = 1
    public static let maxBufferedInputLines = 64

    private let handler: AlphaDelegationMCPToolHandler
    private let serverName: String
    private let serverVersion: String
    private let registry: AlphaDelegationMCPRequestRegistry

    public init(
        handler: @escaping AlphaDelegationMCPToolHandler,
        serverName: String = "CodexSwap",
        serverVersion: String = "1.0"
    ) {
        self.handler = handler
        self.serverName = Self.safeMetadata(serverName, fallback: "CodexSwap")
        self.serverVersion = Self.safeMetadata(serverVersion, fallback: "1.0")
        self.registry = AlphaDelegationMCPRequestRegistry(maximumActiveTasks: Self.maxActiveToolCalls)
    }

    /// Handles one newline-delimited request. Responses include their trailing
    /// newline, and notifications intentionally return nil.
    public func handle(line: Data) async -> Data? {
        await handle(line: line, preReservedKey: nil)
    }

    private func handle(line: Data, preReservedKey: String?) async -> Data? {
        var ownedReservationKey: String?
        defer {
            if let ownedReservationKey {
                registry.abandon(ownedReservationKey)
            } else if let preReservedKey {
                registry.abandon(preReservedKey)
            }
        }
        guard !line.isEmpty else { return nil }
        guard line.count <= Self.maxInboundLineBytes else {
            return Self.errorResponse(id: nil, code: -32700, message: "Parse error")
        }

        let normalized = AlphaDelegationMCPJSONRPCCodec.trimJSONWhitespace(line)
        guard !normalized.isEmpty else { return nil }

        let value: AlphaDelegationMCPJSONValue
        do {
            value = try JSONDecoder().decode(AlphaDelegationMCPJSONValue.self, from: Data(normalized))
        } catch {
            return Self.errorResponse(id: nil, code: -32700, message: "Parse error")
        }

        guard case let .object(request) = value else {
            return Self.errorResponse(id: nil, code: -32600, message: "Invalid request")
        }

        let id: AlphaDelegationMCPJSONRPCID?
        if let rawID = request["id"] {
            guard let decodedID = Self.rpcID(from: rawID) else {
                return Self.errorResponse(id: nil, code: -32600, message: "Invalid request")
            }
            id = decodedID
        } else {
            id = nil
        }

        guard request["jsonrpc"]?.stringValue == "2.0",
              let method = request["method"]?.stringValue,
              !method.isEmpty else {
            return Self.errorResponse(id: id, code: -32600, message: "Invalid request")
        }

        switch method {
        case "initialize":
            guard let params = Self.object(from: request["params"]) else {
                return id.map {
                    Self.response(id: $0, result: .object([:]), errorCode: -32602, errorMessage: "Invalid method parameters")
                }
            }
            guard let id else { return nil }
            guard let requested = params["protocolVersion"]?.stringValue,
                  !requested.isEmpty else {
                return Self.response(
                    id: id,
                    result: .object([:]),
                    errorCode: -32602,
                    errorMessage: "Invalid method parameters"
                )
            }
            let protocolVersion = Self.negotiate(requested)
            let result: AlphaDelegationMCPJSONValue = .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object([
                    "tools": .object([:]),
                ]),
                "serverInfo": .object([
                    "name": .string(serverName),
                    "version": .string(serverVersion),
                ]),
            ])
            return Self.response(id: id, result: result)

        case "notifications/initialized":
            return nil

        case "notifications/cancelled":
            guard let params = Self.object(from: request["params"]),
                  let rawRequestID = params["requestId"],
                  let requestID = Self.rpcID(from: rawRequestID) else {
                return nil
            }
            registry.cancel(Self.key(for: requestID))
            return nil

        case "ping":
            return id.map { Self.response(id: $0, result: .object([:])) }

        case "tools/list":
            guard request["params"] == nil || Self.object(from: request["params"]) != nil else {
                return id.map {
                    Self.response(id: $0, result: .object([:]), errorCode: -32602, errorMessage: "Invalid method parameters")
                }
            }
            guard let id else { return nil }
            return Self.response(id: id, result: .object(["tools": .array(Self.toolDefinitions)]))

        case "tools/call":
            guard let params = Self.object(from: request["params"]),
                  let rawName = params["name"]?.stringValue,
                  let tool = AlphaDelegationMCPToolName(rawValue: rawName),
                  tool == .review,
                  let arguments = Self.object(from: params["arguments"]),
                  arguments.count == 1,
                  let task = arguments["task"]?.stringValue,
                  task.utf8.count <= Self.maxTaskBytes else {
                return id.map {
                    Self.response(id: $0, result: .object([:]), errorCode: -32602, errorMessage: "Invalid method parameters")
                }
            }

            // MCP notifications are deliberately side-effect free here. A caller
            // must provide an id before a tool handler is allowed to run.
            guard let id else { return nil }

            let requestKey = Self.key(for: id)
            let reservation: AlphaDelegationMCPRequestRegistry.Reservation
            if let preReservedKey {
                guard preReservedKey == requestKey else {
                    return Self.errorResponse(id: id, code: -32600, message: "Invalid request")
                }
                reservation = .admitted
                ownedReservationKey = requestKey
            } else {
                reservation = registry.reserve(requestKey)
                if reservation == .admitted {
                    ownedReservationKey = requestKey
                }
            }
            switch reservation {
            case .duplicate:
                return Self.errorResponse(id: id, code: -32600, message: "Invalid request")
            case .busy:
                return Self.toolResponse(
                    id: id,
                    result: .failure(
                        text: "Another Alpha delegation is already running.",
                        structuredContent: ["code": .string("busy")]
                    )
                )
            case .admitted:
                break
            }

            let work = Task { () -> AlphaDelegationMCPToolResult in
                do {
                    return try await handler(tool, task)
                } catch is CancellationError {
                    return .failure(
                        text: "The Alpha delegation was cancelled.",
                        structuredContent: ["code": .string("cancelled")]
                    )
                } catch {
                    return .failure(
                        text: "Tool execution failed.",
                        structuredContent: ["code": .string("tool_execution_failed")]
                    )
                }
            }
            registry.attach(requestKey, task: work)
            let toolResult = await withTaskCancellationHandler(operation: {
                await work.value
            }, onCancel: {
                registry.cancel(requestKey)
            })
            let wasCancelled = registry.finish(requestKey)
            if wasCancelled {
                return Self.toolResponse(
                    id: id,
                    result: .failure(
                        text: "The Alpha delegation was cancelled.",
                        structuredContent: ["code": .string("cancelled")]
                    )
                )
            }
            return Self.toolResponse(id: id, result: toolResult)

        default:
            return id.map { Self.errorResponse(id: $0, code: -32601, message: "Method not found") }
        }
    }

    public func handle(line: String) async -> Data? {
        await handle(line: Data(line.utf8))
    }

    /// Feeds lines from any async sequence into a serialized writer. The method
    /// never writes logs or anything other than JSON-RPC response lines.
    public func serve<S: AsyncSequence & Sendable>(
        lines: S,
        writer: any AlphaDelegationMCPWriter
    ) async throws where S.Element == Data {
        let admission = AlphaDelegationMCPAdmission(limit: Self.maxActiveToolCalls)
        let state = AlphaDelegationMCPServeState()

        try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.consume(
                        lines: lines,
                        writer: writer,
                        admission: admission,
                        state: state
                    )
                }
                group.addTask {
                    _ = try await state.waitForFailure()
                }

                do {
                    _ = try await group.next()
                    group.cancelAll()
                    registry.cancelAll()
                    _ = try? await group.waitForAll()
                    if let failure = state.storedFailure() {
                        throw failure
                    }
                } catch {
                    registry.cancelAll()
                    group.cancelAll()
                    _ = try? await group.waitForAll()
                    throw error
                }
            }
            try Task.checkCancellation()
        }, onCancel: {
            registry.cancelAll()
            state.fail(CancellationError())
        })
    }

    private func consume<S: AsyncSequence & Sendable>(
        lines: S,
        writer: any AlphaDelegationMCPWriter,
        admission: AlphaDelegationMCPAdmission,
        state: AlphaDelegationMCPServeState
    ) async throws where S.Element == Data {
        try await withThrowingTaskGroup(of: Void.self) { group in
            do {
                for try await line in lines {
                    if let failure = state.storedFailure() {
                        registry.cancelAll()
                        group.cancelAll()
                        throw failure
                    }

                    // Fast requests and notifications stay on the reader task
                    // so a long Alpha call cannot starve ping or cancellation.
                    guard Self.method(in: line) == "tools/call",
                          let key = Self.preflightToolKey(in: line),
                          admission.tryAcquire() else {
                        do {
                            if let response = await self.handle(line: line) {
                                try await writer.write(response)
                            }
                        } catch {
                            state.fail(error)
                            registry.cancelAll()
                            group.cancelAll()
                            throw error
                        }
                        continue
                    }
                    guard registry.reserve(key) == .admitted else {
                        admission.release()
                        do {
                            if let response = await self.handle(line: line) {
                                try await writer.write(response)
                            }
                        } catch {
                            state.fail(error)
                            registry.cancelAll()
                            group.cancelAll()
                            throw error
                        }
                        continue
                    }
                    group.addTask {
                        defer { admission.release() }
                        do {
                            if let response = await self.handle(line: line, preReservedKey: key) {
                                try await writer.write(response)
                            }
                        } catch {
                            state.fail(error)
                            registry.cancelAll()
                            throw error
                        }
                    }
                }

                // EOF is an intentional shutdown boundary: cancel active
                // handlers before waiting for structured response tasks.
                registry.cancelAll()
                group.cancelAll()
                _ = try? await group.waitForAll()
                if let failure = state.storedFailure() {
                    throw failure
                }
            } catch {
                registry.cancelAll()
                group.cancelAll()
                _ = try? await group.waitForAll()
                throw error
            }
        }
    }

    private static func negotiate(_ requested: String?) -> String {
        guard let requested, !requested.isEmpty else { return currentProtocolVersion }
        if requested == currentProtocolVersion || requested == fallbackProtocolVersion {
            return requested
        }
        return currentProtocolVersion
    }

    private static func safeMetadata(_ raw: String, fallback: String) -> String {
        let scalars = raw.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                return true
            default:
                return false
            }
        }
        let value = String(String.UnicodeScalarView(scalars).prefix(64))
        return value.isEmpty ? fallback : value
    }

    private static func method(in line: Data) -> String? {
        guard let value = try? AlphaDelegationMCPJSONRPCCodec.decode(line),
              case let .object(object) = value else { return nil }
        return object["method"]?.stringValue
    }

    private static func preflightToolKey(in line: Data) -> String? {
        guard let value = try? AlphaDelegationMCPJSONRPCCodec.decode(line),
              case let .object(request) = value,
              request["jsonrpc"]?.stringValue == "2.0",
              request["method"]?.stringValue == "tools/call",
              let rawID = request["id"],
              let id = rpcID(from: rawID),
              let params = object(from: request["params"]),
              let rawName = params["name"]?.stringValue,
              AlphaDelegationMCPToolName(rawValue: rawName) == .review,
              let arguments = object(from: params["arguments"]),
              arguments.count == 1,
              arguments["task"]?.stringValue != nil else { return nil }
        return key(for: id)
    }

    private static func rpcID(from value: AlphaDelegationMCPJSONValue) -> AlphaDelegationMCPJSONRPCID? {
        switch value {
        case let .string(value): return .string(value)
        case let .number(value): return .number(value)
        case .null: return .null
        case .bool, .array, .object: return nil
        }
    }

    private static func key(for id: AlphaDelegationMCPJSONRPCID) -> String {
        switch id {
        case let .string(value): return "string:\(value)"
        case let .number(value): return "number:\(value)"
        case .null: return "null"
        }
    }

    private static func object(from value: AlphaDelegationMCPJSONValue?) -> [String: AlphaDelegationMCPJSONValue]? {
        guard case let .object(object) = value else { return nil }
        return object
    }

    private static let toolDefinitions: [AlphaDelegationMCPJSONValue] = [
        toolDefinition(
            name: AlphaDelegationMCPToolName.review.rawValue,
            title: "Review with Alpha",
            description: "Invoking this tool sends task text over the network to a third-party remote Alpha provider. The schema maxLength is character-based; runtime validation enforces a 32 KiB UTF-8 byte cap after decoding. The response is returned as untrusted review evidence.",
            readOnly: true,
            destructive: false
        ),
    ]

    private static func toolDefinition(
        name: String,
        title: String,
        description: String,
        readOnly: Bool,
        destructive: Bool
    ) -> AlphaDelegationMCPJSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "task": .object([
                        "type": .string("string"),
                        "maxLength": .number(Decimal(Self.maxTaskBytes)),
                    ]),
                ]),
                "required": .array([.string("task")]),
                "additionalProperties": .bool(false),
            ]),
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
            ]),
        ])
    }

    private static func response(
        id: AlphaDelegationMCPJSONRPCID?,
        result: AlphaDelegationMCPJSONValue,
        errorCode: Int? = nil,
        errorMessage: String? = nil
    ) -> Data {
        boundedResponse(responseValue(id: id, result: result, errorCode: errorCode, errorMessage: errorMessage))
    }

    private static func responseValue(
        id: AlphaDelegationMCPJSONRPCID?,
        result: AlphaDelegationMCPJSONValue,
        errorCode: Int? = nil,
        errorMessage: String? = nil
    ) -> AlphaDelegationMCPJSONValue {
        var object: [String: AlphaDelegationMCPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id.map(value(from:)) ?? .null,
        ]
        if let errorCode {
            object["error"] = .object([
                "code": .number(Decimal(errorCode)),
                "message": .string(errorMessage ?? "Request failed"),
            ])
        } else {
            object["result"] = result
        }
        return .object(object)
    }

    private static func errorResponse(
        id: AlphaDelegationMCPJSONRPCID?,
        code: Int,
        message: String
    ) -> Data {
        response(id: id, result: .object([:]), errorCode: code, errorMessage: message)
    }

    private static func toolResponse(
        id: AlphaDelegationMCPJSONRPCID?,
        result: AlphaDelegationMCPToolResult
    ) -> Data {
        let value: AlphaDelegationMCPJSONValue = .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(result.text),
                ]),
            ]),
            "structuredContent": .object(result.structuredContent),
            "isError": .bool(result.isError),
        ])
        let candidate = encode(responseValue(id: id, result: value))
        if candidate.count <= maxOutboundLineBytes {
            return candidate
        }
        let bounded: AlphaDelegationMCPJSONValue = .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Tool result exceeded the output limit."),
                ]),
            ]),
            "structuredContent": .object(["code": .string("result_too_large")]),
            "isError": .bool(true),
        ])
        return boundedResponse(responseValue(id: id, result: bounded))
    }

    private static func value(from id: AlphaDelegationMCPJSONRPCID) -> AlphaDelegationMCPJSONValue {
        switch id {
        case let .string(value): return .string(value)
        case let .number(value): return .number(value)
        case .null: return .null
        }
    }

    private static func boundedResponse(_ value: AlphaDelegationMCPJSONValue) -> Data {
        let encoded = encode(value)
        if encoded.count <= maxOutboundLineBytes {
            return encoded
        }

        let fallback: AlphaDelegationMCPJSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .null,
            "error": .object([
                "code": .number(Decimal(-32603)),
                "message": .string("Internal error"),
            ]),
        ])
        return encode(fallback)
    }

    private static func encode(_ value: AlphaDelegationMCPJSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(value)) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
        var line = payload
        line.append(0x0A)
        return line
    }
}

public typealias AlphaDelegationMCPDispatcher = AlphaDelegationMCPServer
public typealias MCPStdioWriter = AlphaDelegationMCPStdioWriter
