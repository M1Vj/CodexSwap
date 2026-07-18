import Foundation
import XCTest
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import SwapKit

final class QuotaSafetyRegressionTests: XCTestCase {
    func testClientAlwaysSendsCredentialsOnlyToFixedChatGPTOrigin() async throws {
        let capture = QuotaSafetyRequestCapture()
        let client = QuotaResetClient(dataLoader: { request in
            await capture.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(#"{"available_count":0,"credits":[]}"#.utf8), response)
        })

        _ = try await client.credits(accessToken: "secret", accountID: "account")

        let capturedRequest = await capture.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url, QuotaResetClient.defaultCreditsEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account")
    }

    func testClientRejectsCrossOriginAndDowngradedFinalResponses() async {
        for finalURL in ["https://example.test/credits", "http://chatgpt.com/backend-api/wham/rate-limit-reset-credits"] {
            let client = QuotaResetClient(dataLoader: { request in
                let response = HTTPURLResponse(
                    url: URL(string: finalURL)!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (Data(#"{"available_count":0,"credits":[]}"#.utf8), response)
            })
            do {
                _ = try await client.credits(accessToken: "secret", accountID: "account")
                XCTFail("Expected redirect rejection for \(finalURL)")
            } catch let error as QuotaResetClientError {
                XCTAssertEqual(error, .invalidRequest)
            } catch {
                XCTFail("Unexpected error type: \(type(of: error))")
            }
        }
    }

    func testQuotaResetRedirectPolicyRejectsEveryRedirectBeforeCredentialsCanBeForwarded() throws {
        let delegate = QuotaResetRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: QuotaResetClient.defaultCreditsEndpoint)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        let redirectResponse = try XCTUnwrap(HTTPURLResponse(
            url: QuotaResetClient.defaultCreditsEndpoint,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "/redirected"]
        ))
        let redirectTargets = [
            "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits?redirected=true",
            "https://example.test/credits",
            "http://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
        ]

        for target in redirectTargets {
            let request = URLRequest(url: try XCTUnwrap(URL(string: target)))
            var completionInvocationCount = 0
            var completionRequest: URLRequest?
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: redirectResponse,
                newRequest: request,
                completionHandler: {
                    completionInvocationCount += 1
                    completionRequest = $0
                }
            )
            XCTAssertEqual(completionInvocationCount, 1, "Redirect completion must be invoked exactly once for \(target)")
            XCTAssertNil(completionRequest, "Redirect must be rejected before a credential-bearing follow-up to \(target)")
        }
    }

    func testDefaultClientInvalidatesSessionAndReleasesOwnerWhenClientLeavesScope() {
        let sessionInvalidated = expectation(description: "owned URLSession invalidated")
        let sessionOwnerReleased = expectation(description: "owned URLSession owner released")

        do {
            let client = QuotaResetClient(
                ownedSessionDidBecomeInvalid: { sessionInvalidated.fulfill() },
                ownedSessionOwnerDidDeinit: { sessionOwnerReleased.fulfill() }
            )
            withExtendedLifetime(client) {}
        }

        wait(for: [sessionInvalidated, sessionOwnerReleased], timeout: 1)
    }

    func testMalformedSuccessfulConsumeReconcilesAndRemainsAmbiguousWhenCreditIsAvailable() async throws {
        let fixture = try await makeCoordinator(consumeError: QuotaResetClientError.malformedResponse)
        let result = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        let calls = await fixture.service.calls()
        XCTAssertEqual(result, .ambiguousFailure)
        XCTAssertEqual(calls, ["credits", "consume", "credits"])
    }

    func testServiceUnavailableConsumeReconcilesAndRemainsAmbiguousWhenCreditIsAvailable() async throws {
        let fixture = try await makeCoordinator(consumeError: QuotaResetClientError.httpStatus(503))
        let result = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        let calls = await fixture.service.calls()
        XCTAssertEqual(result, .ambiguousFailure)
        XCTAssertEqual(calls, ["credits", "consume", "credits"])
    }

    func testConclusiveReconciliationNeverResolvesAlternativeForAmbiguousConsumeOutcomes() async throws {
        let errors: [QuotaResetClientError] = [
            .malformedResponse,
            .httpStatus(408),
            .httpStatus(503),
            .transport(.network),
        ]
        for error in errors {
            let events = QuotaSafetyEvents()
            var settings = Settings.default
            settings.interactiveExhaustionPolicy = .resetCurrentFirst
            settings.automaticallyResetExhaustedAccounts = true
            let configuredSettings = settings
            let fixture = try await makeCoordinator(
                consumeError: error,
                postConsumeCreditAvailable: false,
                settings: configuredSettings
            )
            let handler = ExhaustionPolicyHandler(reset: { alias in
                await fixture.coordinator.reset(alias: alias, trigger: .automatic)
            })

            let outcome = await handler.decide(
                settings: configuredSettings,
                mode: .normal,
                currentAlias: "alpha",
                resolveAlternative: {
                    await events.append("unexpected")
                    return Account(alias: "beta", accountID: "beta", accessToken: "token")
                }
            )

            let recordedEvents = await events.values()
            let serviceCalls = await fixture.service.calls()
            XCTAssertEqual(outcome.decision, .retryCurrent, "error: \(error)")
            XCTAssertNil(outcome.alternative)
            XCTAssertEqual(recordedEvents, [], "error: \(error)")
            XCTAssertEqual(serviceCalls, ["credits", "consume", "credits"], "error: \(error)")
        }
    }

    func testResetFirstResolvesAlternativeOnlyAfterResetDecision() async {
        let events = QuotaSafetyEvents()
        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .resetCurrentFirst
        let handler = ExhaustionPolicyHandler(reset: { alias in
            await events.append("reset:\(alias)")
            return .noCredit
        })

        let outcome = await handler.decide(
            settings: settings,
            mode: .normal,
            currentAlias: "alpha",
            resolveAlternative: {
                await events.append("fresh-alternative")
                return Account(alias: "beta", accountID: "beta", accessToken: "token")
            }
        )

        XCTAssertEqual(outcome.decision, .switchTo("beta"))
        XCTAssertEqual(outcome.alternative?.alias, "beta")
        let recordedEvents = await events.values()
        XCTAssertEqual(recordedEvents, ["reset:alpha", "fresh-alternative"])
    }

    func testAmbiguousResetNeverResolvesOrSwitchesAlternative() async {
        let events = QuotaSafetyEvents()
        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .resetCurrentFirst
        let handler = ExhaustionPolicyHandler(reset: { _ in .ambiguousFailure })

        let outcome = await handler.decide(
            settings: settings,
            mode: .normal,
            currentAlias: "alpha",
            resolveAlternative: {
                await events.append("unexpected")
                return Account(alias: "beta", accountID: "beta", accessToken: "token")
            }
        )

        XCTAssertEqual(outcome.decision, .stopAndNotify)
        XCTAssertNil(outcome.alternative)
        let recordedEvents = await events.values()
        XCTAssertEqual(recordedEvents, [])
    }

    func testUsage429ReplayUnauthorizedIsDeliveredWithoutThirdForward() async throws {
        try await assertFinalReplay401(sessionInvalidated: false)
    }

    func testUsage429ReplaySessionInvalidatedIsDeliveredWithoutFailoverOrThirdForward() async throws {
        try await assertFinalReplay401(sessionInvalidated: true)
    }

    func testUsage429ReplayUsageLimitIsDeliveredWithoutAnotherDecisionOrThirdForward() async throws {
        try await assertFinalReplay(
            behavior: .usageLimitAlways(state: "replay"),
            expectedStatusCode: 429
        )
    }

    func testLargeNonUsage429IsForwardedCompletelyWithoutExhaustionDecision() async throws {
        let expectedBody = Data(repeating: 0x78, count: 96 * 1024)
        let upstream = LargeNonUsage429Upstream(body: expectedBody)
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "alpha", accountID: "alpha", accessToken: "token"))
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        let decisions = QuotaSafetyDecisionCount()
        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: { .default },
            automaticQuotaReset: { _ in
                await decisions.record()
                return .noCredit
            }
        )
        try await server.start()
        defer {
            Task {
                await server.stop()
                await upstream.stop()
            }
        }
        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{}"#.utf8)
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (body, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(httpResponse.statusCode, 429)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Length"), String(expectedBody.count))
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "x-large-response-marker"), "preserved")
        XCTAssertEqual(body, expectedBody)
        let decisionCount = await decisions.value()
        let requestCount = await upstream.requestCount()
        XCTAssertEqual(decisionCount, 0)
        XCTAssertEqual(requestCount, 1)
        await server.stop()
        await upstream.stop()
    }

    func testLargeSemantic429StopResponseIsForwardedCompletely() async throws {
        var expectedBody = Data(#"{"error":{"code":"usage_limit_reached"}}"#.utf8)
        expectedBody.append(Data(repeating: 0x20, count: 96 * 1024 - expectedBody.count))
        let upstream = LargeNonUsage429Upstream(body: expectedBody)
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "alpha", accountID: "alpha", accessToken: "token"))
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .stopAndNotify
        let configuredSettings = settings
        let decisions = QuotaSafetyDecisionCount()
        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: { configuredSettings },
            automaticQuotaReset: { _ in
                await decisions.record()
                return .noCredit
            }
        )
        try await server.start()
        defer {
            Task {
                await server.stop()
                await upstream.stop()
            }
        }
        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{}"#.utf8)
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (body, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let decisionCount = await decisions.value()
        let requestCount = await upstream.requestCount()

        XCTAssertEqual(httpResponse.statusCode, 429)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Content-Length"), String(expectedBody.count))
        XCTAssertEqual(body, expectedBody)
        XCTAssertEqual(decisionCount, 0)
        XCTAssertEqual(requestCount, 1)
        await server.stop()
        await upstream.stop()
    }

    private func makeCoordinator(
        consumeError: QuotaResetClientError,
        postConsumeCreditAvailable: Bool = true,
        settings: Settings = .default
    ) async throws -> (
        coordinator: QuotaResetCoordinator,
        service: QuotaSafetyResetService
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "alpha", accountID: "account", accessToken: "token"))
        let service = QuotaSafetyResetService(
            consumeError: consumeError,
            postConsumeCreditAvailable: postConsumeCreditAvailable
        )
        let coordinator = QuotaResetCoordinator(
            accountStore: store,
            settings: { settings },
            resetService: service,
            usageService: QuotaSafetyUsageService(),
            pendingRecordURL: root.appendingPathComponent("private/pending.json")
        )
        return (coordinator, service)
    }

    private func assertFinalReplay401(sessionInvalidated: Bool) async throws {
        try await assertFinalReplay(
            behavior: .usageLimitThenUnauthorized(
                state: "replay",
                sessionInvalidated: sessionInvalidated
            ),
            expectedStatusCode: 401
        )
    }

    private func assertFinalReplay(
        behavior: LocalRoutingUpstream.Behavior,
        expectedStatusCode: Int
    ) async throws {
        let upstream = LocalRoutingUpstream(behavior)
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "alpha", accountID: "alpha", accessToken: "token", refreshToken: "refresh"))
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .resetCurrentFirst
        let configuredSettings = settings
        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: { configuredSettings },
            automaticQuotaReset: { _ in .reset(windowsReset: 1) }
        )
        try await server.start()
        defer {
            Task {
                await server.stop()
                await upstream.stop()
            }
        }
        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{}"#.utf8)
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.data(for: request)
        let statusCode = try XCTUnwrap(response as? HTTPURLResponse).statusCode
        let forwards = await upstream.requestCount()

        XCTAssertEqual(statusCode, expectedStatusCode)
        XCTAssertEqual(forwards, 2)
        await server.stop()
        await upstream.stop()
    }
}

private actor QuotaSafetyRequestCapture {
    private(set) var request: URLRequest?
    func record(_ request: URLRequest) { self.request = request }
    func capturedRequest() -> URLRequest? { request }
}

private actor QuotaSafetyResetService: QuotaResetServing {
    private let consumeError: QuotaResetClientError
    private let postConsumeCreditAvailable: Bool
    private(set) var callKinds: [String] = []

    init(consumeError: QuotaResetClientError, postConsumeCreditAvailable: Bool = true) {
        self.consumeError = consumeError
        self.postConsumeCreditAvailable = postConsumeCreditAvailable
    }

    func calls() -> [String] { callKinds }

    func credits(accessToken: String, accountID: String) async throws -> ResetCreditSnapshot {
        callKinds.append("credits")
        let available = callKinds.filter { $0 == "credits" }.count == 1 || postConsumeCreditAvailable
        return ResetCreditSnapshot(
            availableCount: available ? 1 : 0,
            credits: available ? [ResetCredit(id: "credit", resetType: "weekly", status: "available", grantedAt: Date())] : [],
            fetchedAt: Date()
        )
    }

    func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeResult {
        callKinds.append("consume")
        throw consumeError
    }
}

private struct QuotaSafetyUsageService: UsageFetching {
    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] { [] }
}

private actor QuotaSafetyEvents {
    private var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func values() -> [String] { events }
}

private actor QuotaSafetyDecisionCount {
    private var count = 0
    func record() { count += 1 }
    func value() -> Int { count }
}

private actor LargeNonUsage429Upstream {
    private let body: Data
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var servingTask: Task<Void, Never>?
    private var requests = 0

    init(body: Data) { self.body = body }

    func start() async throws -> URL {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: child)
                }
            }
        self.channel = channel.channel
        servingTask = Task { [weak self] in
            guard let self else { return }
            try? await channel.executeThenClose { inbound in
                for try await connection in inbound {
                    try await self.respond(to: connection)
                }
            }
        }
        return URL(string: "http://127.0.0.1:\(channel.channel.localAddress!.port!)")!
    }

    func stop() async {
        try? await channel?.close()
        _ = await servingTask?.value
        channel = nil
        servingTask = nil
        try? await group.shutdownGracefully()
    }

    func requestCount() -> Int { requests }

    private func respond(to connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async throws {
        try await connection.executeThenClose { inbound, outbound in
            for try await part in inbound {
                guard case .end = part else { continue }
                self.requests += 1
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "application/octet-stream")
                headers.add(name: "Content-Length", value: String(self.body.count))
                headers.add(name: "x-large-response-marker", value: "preserved")
                try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .tooManyRequests, headers: headers)))
                for offset in stride(from: 0, to: self.body.count, by: 32 * 1024) {
                    let end = min(offset + 32 * 1024, self.body.count)
                    try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: self.body[offset..<end]))))
                    try await Task.sleep(for: .milliseconds(10))
                }
                try await outbound.write(.end(nil))
                return
            }
        }
    }
}
