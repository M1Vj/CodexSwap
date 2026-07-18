import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import SwapKit

final class ProxyShutdownRegressionTests: XCTestCase {
    func testCountingBarrierWaitTimesOutInsteadOfHanging() async {
        let barrier = CountingLifecycleBarrier(target: 1)

        do {
            try await barrier.waitUntilTarget(timeout: .milliseconds(20))
            XCTFail("wait unexpectedly completed")
        } catch is LifecycleBarrierTimeout {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testLifecycleBarrierWaitTimesOutInsteadOfHanging() async {
        let barrier = LifecycleBarrier()

        do {
            try await barrier.waitUntilArrived(timeout: .milliseconds(20))
            XCTFail("wait unexpectedly completed")
        } catch is LifecycleBarrierTimeout {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testConcurrentStartsCoalesceOneBindAndPublishOneServer() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = makeServer(root: root)
        let callers = CountingLifecycleBarrier(target: 2)
        let binds = CountingLifecycleBarrier(target: 1, initiallyBlocked: true)
        await server.setLifecycleTestHooks(
            afterBind: { await binds.arriveAndWaitIfBlocked() },
            stopCommitted: nil,
            startCaller: { await callers.arriveAndWaitIfBlocked() }
        )

        let first = Task { try await server.start() }
        do {
            try await binds.waitUntilTarget()
        } catch {
            await callers.release()
            await binds.release()
            first.cancel()
            _ = try? await first.value
            await server.stop()
            throw error
        }
        let second = Task { try await server.start() }
        do {
            try await callers.waitUntilTarget()
        } catch {
            await callers.release()
            await binds.release()
            first.cancel()
            second.cancel()
            _ = try? await first.value
            _ = try? await second.value
            await server.stop()
            throw error
        }
        await binds.release()

        do {
            try await first.value
            try await second.value
        } catch {
            first.cancel()
            second.cancel()
            _ = try? await first.value
            _ = try? await second.value
            await server.stop()
            throw error
        }
        let bindCount = await binds.count()
        let runningPort = await server.port()
        XCTAssertEqual(bindCount, 1)
        XCTAssertNotNil(runningPort)

        await server.stop()
        let stoppedPort = await server.port()
        XCTAssertNil(stoppedPort)
        let snapshot = await server.shutdownTrackingSnapshot()
        XCTAssertEqual(snapshot, .init(tasks: 0, channels: 0, waiters: 0))
    }

    func testStopCancelsRequestWaitingForUpstreamHeadersAndIsIdempotent() async throws {
        let upstream = HangingHeaderUpstream()
        let upstreamURL = try await upstream.start()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-shutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "shutdown", accountID: "account", accessToken: "token"))

        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        config.apiUpstream = upstreamURL
        let server = ProxyServer(store: store, config: config, settingsProvider: { .default })
        do {
            try await server.start()
        } catch {
            await server.stop()
            await upstream.stop()
            throw error
        }

        let boundPort = await server.port()
        guard let port = boundPort else {
            await server.stop()
            await upstream.stop()
            return XCTFail("proxy did not publish a port")
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"input":"hang"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestTask = Task { try? await URLSession.shared.data(for: request) }

        do {
            try await upstream.waitForRequest()
        } catch {
            requestTask.cancel()
            _ = await requestTask.value
            await server.stop()
            await upstream.stop()
            throw error
        }

        let stopped = expectation(description: "proxy stop completes")
        let stopTask = Task {
            await server.stop()
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 1.0)
        _ = await stopTask.value
        requestTask.cancel()
        _ = await requestTask.value

        let snapshot = await server.shutdownTrackingSnapshot()
        XCTAssertEqual(snapshot.tasks, 0)
        XCTAssertEqual(snapshot.channels, 0)
        XCTAssertEqual(snapshot.waiters, 0)

        await server.stop()
        let secondSnapshot = await server.shutdownTrackingSnapshot()
        XCTAssertEqual(secondSnapshot, snapshot)
        await upstream.stop()
    }

    func testConcurrentStopCallersShareShutdownAndLeaveNoPublishedState() async throws {
        let started = try await makeStartedServer()
        defer { try? FileManager.default.removeItem(at: started.root) }
        let server = started.server

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await server.stop() }
            }
        }

        let port = await server.port()
        XCTAssertNil(port)
        let snapshot = await server.shutdownTrackingSnapshot()
        XCTAssertEqual(snapshot, .init(tasks: 0, channels: 0, waiters: 0))
    }

    func testStartAfterStopThrowsAlreadyStopped() async throws {
        let started = try await makeStartedServer()
        defer { try? FileManager.default.removeItem(at: started.root) }
        let server = started.server
        await server.stop()

        do {
            try await server.start()
            XCTFail("start after stop unexpectedly succeeded")
        } catch ProxyServer.LifecycleError.alreadyStopped {}

        let port = await server.port()
        XCTAssertNil(port)
    }

    func testStartAfterStopCommitsButBeforeServingClearsThrowsAlreadyStopped() async throws {
        let started = try await makeStartedServer()
        defer { try? FileManager.default.removeItem(at: started.root) }
        let server = started.server
        let stopCommitted = LifecycleBarrier()
        await server.setLifecycleTestHooks(
            afterBind: nil,
            stopCommitted: { await stopCommitted.arriveAndWait() }
        )

        let stopTask = Task { await server.stop() }
        do {
            try await stopCommitted.waitUntilArrived()
        } catch {
            await stopCommitted.release()
            stopTask.cancel()
            await stopTask.value
            await server.stop()
            throw error
        }

        do {
            try await server.start()
            XCTFail("start during committed stop unexpectedly succeeded")
        } catch ProxyServer.LifecycleError.alreadyStopped {
        } catch {
            await stopCommitted.release()
            stopTask.cancel()
            await stopTask.value
            await server.stop()
            throw error
        }

        await stopCommitted.release()
        await stopTask.value
    }

    func testStartDuringCommittedStopClosesPostBindChannelAndThrowsAlreadyStopped() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = makeServer(root: root)
        let afterBind = LifecycleBarrier()
        let stopCommitted = LifecycleBarrier()
        await server.setLifecycleTestHooks(
            afterBind: { await afterBind.arriveAndWait() },
            stopCommitted: { await stopCommitted.arriveAndWait() }
        )

        let startTask = Task { () -> Error? in
            do {
                try await server.start()
                return nil
            } catch {
                return error
            }
        }
        do {
            try await afterBind.waitUntilArrived()
        } catch {
            await afterBind.release()
            await stopCommitted.release()
            startTask.cancel()
            _ = await startTask.value
            await server.stop()
            throw error
        }
        let stopTask = Task { await server.stop() }
        do {
            try await stopCommitted.waitUntilArrived()
        } catch {
            await afterBind.release()
            await stopCommitted.release()
            startTask.cancel()
            stopTask.cancel()
            _ = await startTask.value
            await stopTask.value
            await server.stop()
            throw error
        }
        await afterBind.release()

        let startError = await startTask.value
        await stopCommitted.release()
        await stopTask.value
        guard case ProxyServer.LifecycleError.alreadyStopped? = startError else {
            return XCTFail("expected alreadyStopped, got \(String(describing: startError))")
        }
        let port = await server.port()
        XCTAssertNil(port)
        let snapshot = await server.shutdownTrackingSnapshot()
        XCTAssertEqual(snapshot, .init(tasks: 0, channels: 0, waiters: 0))
    }

    func testBindFailureThenRepeatedStopLeavesNoPublishedState() async throws {
        let occupied = HangingHeaderUpstream()
        _ = try await occupied.start()
        let boundPort = await occupied.port()
        guard let occupiedPort = boundPort else {
            await occupied.stop()
            return XCTFail("occupied server did not publish a port")
        }

        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = ProxyServer.Config()
        config.port = occupiedPort
        let server = makeServer(root: root, config: config)

        do {
            try await server.start()
            XCTFail("bind unexpectedly succeeded")
        } catch {}
        await server.stop()
        await server.stop()

        let port = await server.port()
        XCTAssertNil(port)
        let snapshot = await server.shutdownTrackingSnapshot()
        XCTAssertEqual(snapshot, .init(tasks: 0, channels: 0, waiters: 0))
        await occupied.stop()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeServer(root: URL, config: ProxyServer.Config = .init()) -> ProxyServer {
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        return ProxyServer(store: store, config: config, settingsProvider: { .default })
    }

    private func makeStartedServer() async throws -> (root: URL, server: ProxyServer) {
        let root = try makeRoot()
        let server = makeServer(root: root)
        do {
            try await server.start()
            return (root, server)
        } catch {
            await server.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

private struct LifecycleBarrierTimeout: Error {}

private actor CountingLifecycleBarrier {
    private let target: Int
    private var arrivals = 0
    private var blocked: Bool
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(target: Int, initiallyBlocked: Bool = false) {
        self.target = target
        blocked = initiallyBlocked
    }

    func arriveAndWaitIfBlocked() async {
        arrivals += 1
        guard blocked else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilTarget(timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while arrivals < target {
            guard clock.now < deadline else {
                release()
                throw LifecycleBarrierTimeout()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() {
        blocked = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func count() -> Int { arrivals }
}

private actor LifecycleBarrier {
    private var arrived = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arrive() {
        arrived = true
    }

    func arriveAndWait() async {
        arrive()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived(timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !arrived {
            guard clock.now < deadline else {
                release()
                throw LifecycleBarrierTimeout()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor HangingHeaderUpstream {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var servingTask: Task<Void, Never>?
    private var connectionTasks: [Task<Void, Never>] = []
    private var requestSeen = false

    func start() async throws -> URL {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                        wrappingChannelSynchronously: child
                    )
                }
            }
        self.channel = channel.channel
        servingTask = Task { [weak self] in
            guard let self else { return }
            try? await channel.executeThenClose { inbound in
                for try await connection in inbound {
                    let task = Task { [weak self] in
                        guard let self else { return }
                        try? await self.hold(connection)
                    }
                    await self.track(task)
                }
            }
        }
        return URL(string: "http://127.0.0.1:\(channel.channel.localAddress!.port!)")!
    }

    func port() -> Int? { channel?.localAddress?.port }

    func stop() async {
        let serving = servingTask
        serving?.cancel()
        try? await channel?.close()
        _ = await serving?.value
        let connections = connectionTasks
        connections.forEach { $0.cancel() }
        for task in connections { await task.value }
        channel = nil
        servingTask = nil
        connectionTasks.removeAll()
        try? await group.shutdownGracefully()
    }

    func waitForRequest() async throws {
        for _ in 0..<100 {
            if requestSeen { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("upstream did not receive the request")
    }

    private func track(_ task: Task<Void, Never>) {
        connectionTasks.append(task)
    }

    private func hold(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async throws {
        try await connection.executeThenClose { inbound, _ in
            for try await part in inbound {
                if case .end = part {
                    requestSeen = true
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(60))
                    }
                    return
                }
            }
        }
    }
}
