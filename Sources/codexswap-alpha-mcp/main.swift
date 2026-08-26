import Foundation
import Darwin
import SwapKit

// A process can receive SIGTERM in the small interval between exec(2) and the
// async MCP service reaching its normal signal-source setup. Keep the handler
// intentionally tiny and async-signal-safe; startup consumes this flag before
// switching the dispositions to SIG_IGN for DispatchSourceSignal.
private nonisolated(unsafe) var startupShutdownSignal: sig_atomic_t = 0

@_cdecl("codexswap_alpha_mcp_startup_shutdown_signal")
private func recordStartupShutdownSignal(_ signalNumber: Int32) {
    startupShutdownSignal = 1
}

private func installStartupShutdownSignalHandler() {
    var action = sigaction()
    precondition(
        sigemptyset(&action.sa_mask) == 0,
        "could not initialize startup shutdown signal disposition"
    )
    action.sa_flags = 0
    action.__sigaction_u.__sa_handler = recordStartupShutdownSignal
    precondition(
        sigaction(SIGINT, &action, nil) == 0,
        "could not install startup SIGINT handler"
    )
    precondition(
        sigaction(SIGTERM, &action, nil) == 0,
        "could not install startup SIGTERM handler"
    )
}

private let startupShutdownSignalHandlerInstalled: Void = installStartupShutdownSignalHandler()

private enum AlphaMCPMainError: Error {
    case invalidTask
    case taskTooLarge
}

private func failure(for error: AlphaMCPMainError) -> AlphaDelegationMCPToolResult {
    switch error {
    case .invalidTask:
        return .failure(
            text: "The Alpha delegation task must not be empty.",
            structuredContent: ["code": .string("invalid_task")]
        )
    case .taskTooLarge:
        return .failure(
            text: "The Alpha delegation task is too large.",
            structuredContent: ["code": .string("task_too_large")]
        )
    }
}

private func boundedTask(_ task: String) -> Result<String, AlphaMCPMainError> {
    guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .failure(.invalidTask)
    }
    guard task.utf8.count <= AlphaDelegationMCPServer.maxTaskBytes else {
        return .failure(.taskTooLarge)
    }
    return .success(task)
}

private func structuredResult(
    _ result: AlphaDelegationResult,
    mode: AlphaDelegationMode
) -> AlphaDelegationMCPToolResult {
    var structured: [String: AlphaDelegationMCPJSONValue] = [
        "mode": .string(mode.rawValue),
        "toolNames": .array(result.toolNames.map(AlphaDelegationMCPJSONValue.string)),
        "toolCount": .number(Decimal(result.toolCount)),
        "exitStatus": .number(Decimal(result.exitStatus)),
    ]
    if let sessionID = result.sessionID {
        structured["sessionID"] = .string(sessionID)
    }
    return .success(text: result.text, structuredContent: structured)
}

private enum AlphaMCPInputError: Error, Sendable {
    case descriptorUnavailable
    case readFailed(Int32)
    case overloaded
}

private final class AlphaMCPLineSlots: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore: DispatchSemaphore
    private var cancelled = false

    init(capacity: Int) {
        semaphore = DispatchSemaphore(value: Swift.max(1, capacity))
    }

    func acquire() -> Bool {
        while true {
            lock.lock()
            let shouldStop = cancelled
            lock.unlock()
            if shouldStop { return false }
            if semaphore.wait(timeout: .now() + .milliseconds(25)) == .success {
                return true
            }
        }
    }

    func release() {
        semaphore.signal()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        semaphore.signal()
    }
}

private final class BoundedStdinLines: AsyncSequence, @unchecked Sendable {
    typealias Element = Data
    typealias AsyncIterator = Iterator

    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let slots: AlphaMCPLineSlots
    private let reader: Task<Void, Never>

    init(
        input: FileHandle,
        maximumLineBytes: Int,
        capacity: Int
    ) {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(Swift.max(1, capacity))
        )
        self.stream = stream
        self.continuation = continuation

        let slots = AlphaMCPLineSlots(capacity: capacity)
        self.slots = slots
        let descriptor = Darwin.dup(input.fileDescriptor)
        let reader = Task.detached(priority: .utility) {
            guard descriptor >= 0 else {
                continuation.finish(throwing: AlphaMCPInputError.descriptorUnavailable)
                return
            }
            defer { _ = Darwin.close(descriptor) }

            let flags = fcntl(descriptor, F_GETFL)
            if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0 {
                continuation.finish(throwing: AlphaMCPInputError.readFailed(errno))
                return
            }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

            let oversizedMarker = Data(repeating: 0x78, count: maximumLineBytes + 1)
            var pending = Data()
            var overLimit = false
            var buffer = Data(repeating: 0, count: 16 * 1024)

            func emit(_ line: Data) async -> Bool {
                guard slots.acquire() else { return false }
                let result = continuation.yield(line)
                switch result {
                case .enqueued:
                    return true
                case .dropped:
                    slots.release()
                    continuation.finish(throwing: AlphaMCPInputError.overloaded)
                    return false
                case .terminated:
                    slots.release()
                    return false
                @unknown default:
                    slots.release()
                    continuation.finish(throwing: AlphaMCPInputError.overloaded)
                    return false
                }
            }

            while !Task.isCancelled {
                var descriptorEvents = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN | POLLERR | POLLHUP),
                    revents: 0
                )
                let ready = Darwin.poll(&descriptorEvents, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    continuation.finish(throwing: AlphaMCPInputError.readFailed(errno))
                    return
                }
                if ready == 0 { continue }

                let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return -1 }
                    return Darwin.read(descriptor, baseAddress, bytes.count)
                }
                if count == 0 {
                    if !pending.isEmpty {
                        let line = overLimit || pending.count > maximumLineBytes ? oversizedMarker : pending
                        guard await emit(line) else { return }
                    }
                    continuation.finish()
                    return
                }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    continuation.finish(throwing: AlphaMCPInputError.readFailed(errno))
                    return
                }

                pending.append(buffer.prefix(count))
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    let output = overLimit || line.count > maximumLineBytes ? oversizedMarker : line
                    guard await emit(output) else { return }
                    overLimit = false
                }

                if pending.count > maximumLineBytes {
                    overLimit = true
                    pending.removeAll(keepingCapacity: true)
                } else if overLimit {
                    pending.removeAll(keepingCapacity: true)
                }
            }
            continuation.finish()
        }
        self.reader = reader
        continuation.onTermination = { [reader, slots] (_: AsyncThrowingStream<Data, Error>.Continuation.Termination) in
            slots.cancel()
            reader.cancel()
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(iterator: stream.makeAsyncIterator(), slots: slots)
    }

    func cancel() {
        slots.cancel()
        reader.cancel()
        continuation.finish()
    }

    struct Iterator: AsyncIteratorProtocol {
        private var iterator: AsyncThrowingStream<Data, Error>.Iterator
        private let slots: AlphaMCPLineSlots

        fileprivate init(
            iterator: AsyncThrowingStream<Data, Error>.Iterator,
            slots: AlphaMCPLineSlots
        ) {
            self.iterator = iterator
            self.slots = slots
        }

        mutating func next() async throws -> Data? {
            guard let value = try await iterator.next() else { return nil }
            slots.release()
            return value
        }
    }
}

private final class AlphaMCPShutdownController: @unchecked Sendable {
    private let lock = NSLock()
    private var requestCancellation: (@Sendable () -> Void)?
    private var requested = false
    private var pendingRequest = false

    init() {}

    func bindCancellation(_ requestCancellation: @escaping @Sendable () -> Void) {
        lock.lock()
        precondition(self.requestCancellation == nil, "shutdown cancellation is already bound")
        self.requestCancellation = requestCancellation
        let shouldRequestCancellation = pendingRequest
        pendingRequest = false
        lock.unlock()

        if shouldRequestCancellation {
            requestCancellation()
        }
    }

    func request() {
        lock.lock()
        guard !requested else {
            lock.unlock()
            return
        }
        requested = true
        guard let requestCancellation else {
            pendingRequest = true
            lock.unlock()
            return
        }
        lock.unlock()
        requestCancellation()
    }
}

private func makeShutdownSignal(
    signalNumber: Int32,
    controller: AlphaMCPShutdownController
) -> DispatchSourceSignal {
    let source = DispatchSource.makeSignalSource(
        signal: signalNumber,
        queue: DispatchQueue.global(qos: .utility)
    )
    source.setEventHandler(handler: controller.request)
    source.resume()
    return source
}

private func blockShutdownSignals() -> sigset_t {
    var mask = sigset_t()
    precondition(sigemptyset(&mask) == 0, "could not initialize shutdown signal mask")
    precondition(sigaddset(&mask, SIGINT) == 0, "could not add SIGINT to shutdown signal mask")
    precondition(sigaddset(&mask, SIGTERM) == 0, "could not add SIGTERM to shutdown signal mask")
    precondition(
        pthread_sigmask(SIG_BLOCK, &mask, nil) == 0,
        "could not block shutdown signals during MCP startup"
    )
    return mask
}

private func ignoreShutdownSignals() {
    var action = sigaction()
    precondition(
        sigemptyset(&action.sa_mask) == 0,
        "could not initialize shutdown signal disposition"
    )
    action.sa_flags = 0
    action.__sigaction_u.__sa_handler = SIG_IGN
    precondition(
        sigaction(SIGINT, &action, nil) == 0,
        "could not ignore SIGINT during MCP startup"
    )
    precondition(
        sigaction(SIGTERM, &action, nil) == 0,
        "could not ignore SIGTERM during MCP startup"
    )
}

private func hasPendingShutdownSignal() -> Bool {
    var pending = sigset_t()
    guard sigpending(&pending) == 0 else { return startupShutdownSignal != 0 }
    return startupShutdownSignal != 0
        || sigismember(&pending, SIGINT) == 1
        || sigismember(&pending, SIGTERM) == 1
}

private func makeMCPWorkingDirectory(fileManager: FileManager = .default) -> URL? {
    let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL
    let directory = temporaryRoot.appendingPathComponent(
        "codexswap-alpha-mcp-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard let attributes = try? fileManager.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              mode & 0o777 == 0o700,
              directory.standardizedFileURL.path
                == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            try? fileManager.removeItem(at: directory)
            return nil
        }
        return directory
    } catch {
        try? fileManager.removeItem(at: directory)
        return nil
    }
}

private func removeMCPWorkingDirectory(
    at directory: URL,
    fileManager: FileManager = .default
) {
    let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL.path
    let standardized = directory.standardizedFileURL
    guard standardized.path.hasPrefix(temporaryRoot + "/"),
          let attributes = try? fileManager.attributesOfItem(atPath: standardized.path),
          attributes[.type] as? FileAttributeType == .typeDirectory,
          standardized.path == standardized.resolvingSymlinksInPath().standardizedFileURL.path else {
        return
    }
    try? fileManager.removeItem(at: standardized)
}

_ = startupShutdownSignalHandlerInstalled
private let shutdownSignalMask = blockShutdownSignals()
private let shutdownRequestedDuringStartup = hasPendingShutdownSignal()
ignoreShutdownSignals()
private let shutdownController = AlphaMCPShutdownController()
let shutdownSignals = [SIGINT, SIGTERM].map {
    makeShutdownSignal(signalNumber: $0, controller: shutdownController)
}

let workingDirectoryCandidate = makeMCPWorkingDirectory()
if workingDirectoryCandidate == nil {
    shutdownSignals.forEach { $0.cancel() }
    var mask = shutdownSignalMask
    _ = pthread_sigmask(SIG_UNBLOCK, &mask, nil)
    FileHandle.standardError.write(Data("Alpha MCP could not create a private working directory.\n".utf8))
    exit(1)
}
let workingDirectory = workingDirectoryCandidate!

let runner = AlphaDelegationRunner()

let server = AlphaDelegationMCPServer { tool, task in
    switch boundedTask(task) {
    case let .failure(error):
        return failure(for: error)
    case let .success(task):
        guard tool == .review else {
            return .failure(
                text: "Only read-only Alpha review is available.",
                structuredContent: ["code": .string("unsupported_mode")]
            )
        }
        let mode = AlphaDelegationMode.review

        do {
            let result = try await runner.run(
                task: task,
                mode: mode,
                workingDirectory: workingDirectory
            )
            return structuredResult(result, mode: mode)
        } catch is CancellationError {
            return .failure(
                text: "The Alpha delegation was cancelled.",
                structuredContent: ["code": .string("cancelled")]
            )
        } catch {
            return .failure(
                text: "The Alpha delegation failed.",
                structuredContent: ["code": .string("delegation_failed")]
            )
        }
    }
}

let standardInput = FileHandle.standardInput
private let stdinLines = BoundedStdinLines(
    input: standardInput,
    maximumLineBytes: AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes,
    capacity: AlphaDelegationMCPServer.maxBufferedInputLines
)
let writer = AlphaDelegationMCPStdioWriter()
let serviceTask = Task {
    try await server.serve(lines: stdinLines, writer: writer)
}
shutdownController.bindCancellation {
    serviceTask.cancel()
    stdinLines.cancel()
}
if shutdownRequestedDuringStartup {
    shutdownController.request()
}
var startupMask = shutdownSignalMask
precondition(
    pthread_sigmask(SIG_UNBLOCK, &startupMask, nil) == 0,
    "could not unblock shutdown signals after MCP startup"
)

var exitCode = 0
do {
    try await serviceTask.value
} catch is CancellationError {
    // Cancellation propagates into an in-flight runner and terminates its child.
} catch {
    FileHandle.standardError.write(Data("Alpha MCP server stopped unexpectedly.\n".utf8))
    exitCode = 1
}

stdinLines.cancel()
await writer.close()
shutdownSignals.forEach { $0.cancel() }
removeMCPWorkingDirectory(at: workingDirectory)
if exitCode != 0 {
    exit(Int32(exitCode))
}
