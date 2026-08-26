import Foundation
import XCTest
import Darwin
@testable import SwapKit

final class AlphaDelegationMCPProtocolTests: XCTestCase {
    func testInitializeNegotiatesCurrentVersionAndEchoesNumericID() async throws {
        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: "unused")
        }

        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        let object = try responseObject(response)
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual((object["id"] as? NSNumber)?.intValue, 7)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(result["serverInfo"] as? [String: Any])
    }

    func testInitializeUsesSafeCurrentFallbackForUnknownVersion() async throws {
        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: "unused")
        }

        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":"fallback","method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        let object = try responseObject(response)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
    }

    func testInitializeRequiresAProtocolVersionString() async throws {
        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: "unused")
        }

        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":8,"method":"initialize","params":{"capabilities":{},"clientInfo":{}}}"#)
        let object = try responseObject(response)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testInitializedNotificationAndPingUseNotificationAndStringIDSemantics() async throws {
        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: "unused")
        }

        let initialized = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(initialized)

        let ping = await server.handle(line: #"{"jsonrpc":"2.0","id":"p-1","method":"ping"}"#)
        let object = try responseObject(ping)
        XCTAssertEqual(object["id"] as? String, "p-1")
        XCTAssertEqual((object["result"] as? [String: Any])?.isEmpty, true)
    }

    func testToolsListIsDeterministicAndUsesStrictSchemasAndAnnotations() async throws {
        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: "unused")
        }

        let first = try responseObject(await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#))
        let second = try responseObject(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#))
        let firstTools = try XCTUnwrap(first["result"] as? [String: Any])["tools"] as? [[String: Any]]
        let secondTools = try XCTUnwrap(second["result"] as? [String: Any])["tools"] as? [[String: Any]]
        XCTAssertEqual(firstTools?.compactMap { $0["name"] as? String }, [
            "codexswap_alpha_review",
        ])
        XCTAssertEqual(firstTools?.compactMap { $0["name"] as? String }, secondTools?.compactMap { $0["name"] as? String })

        let review = try XCTUnwrap(firstTools?.first { $0["name"] as? String == "codexswap_alpha_review" })
        let reviewSchema = try XCTUnwrap(review["inputSchema"] as? [String: Any])
        XCTAssertEqual(reviewSchema["type"] as? String, "object")
        XCTAssertEqual(reviewSchema["required"] as? [String], ["task"])
        XCTAssertEqual(reviewSchema["additionalProperties"] as? Bool, false)
        let taskSchema = try XCTUnwrap((reviewSchema["properties"] as? [String: Any])?["task"] as? [String: Any])
        XCTAssertEqual(taskSchema["type"] as? String, "string")
        XCTAssertEqual((taskSchema["maxLength"] as? NSNumber)?.intValue, AlphaDelegationMCPServer.maxTaskBytes)
        let description = try XCTUnwrap(review["description"] as? String).lowercased()
        XCTAssertTrue(description.contains("task text over the network"))
        XCTAssertTrue(description.contains("third-party remote alpha provider"))
        XCTAssertTrue(description.contains("returned as untrusted review evidence"))
        XCTAssertTrue(description.contains("character-based"))
        XCTAssertTrue(description.contains("32 kib"))
        XCTAssertTrue(description.contains("utf-8 byte cap"))
        XCTAssertEqual((review["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        XCTAssertEqual((review["annotations"] as? [String: Any])?["destructiveHint"] as? Bool, false)
    }

    func testEditToolIsNotAdvertisedOrDispatchedInReviewOnlyV1() async throws {
        let called = InvocationBox()
        let server = AlphaDelegationMCPServer { _, _ in
            called.record(tool: "unexpected", task: "unexpected")
            return .success(text: "unexpected")
        }

        let listed = try responseObject(await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let names = ((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["codexswap_alpha_review"])

        let editCall = await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"codexswap_alpha_edit","arguments":{"task":"edit"}}}"#)
        let editObject = try responseObject(editCall)
        let error = try XCTUnwrap(editObject["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertNil(called.tool)
    }

    func testToolCallDispatchesTaskAndReturnsTextStructuredContentAndEchoedID() async throws {
        let called = InvocationBox()
        let server = AlphaDelegationMCPServer { tool, task in
            called.record(tool: tool.rawValue, task: task)
            return .success(text: "reviewed", structuredContent: [
                "status": .string("ok"),
                "taskLength": .number(Decimal(task.count)),
            ])
        }

        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"check this"}}}"#)
        let object = try responseObject(response)
        XCTAssertEqual((object["id"] as? NSNumber)?.intValue, 42)
        XCTAssertEqual(called.tool, "codexswap_alpha_review")
        XCTAssertEqual(called.task, "check this")
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["type"] as? String, "text")
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "reviewed")
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["status"] as? String, "ok")
    }

    func testToolCallRejectsTaskOverAdvertisedLimitBeforeHandlerInvocation() async throws {
        let called = InvocationBox()
        let server = AlphaDelegationMCPServer { _, task in
            called.record(tool: "unexpected", task: task)
            return .success(text: "unexpected")
        }

        let task = String(repeating: "x", count: 32 * 1024 + 1)
        let response = await server.handle(line: toolCallLine(id: "too-large", task: task))
        let object = try responseObject(response)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertNil(called.tool)
    }

    func testToolCallAllowsTaskAtAdvertisedLimitAndInvokesHandler() async throws {
        let called = InvocationBox()
        let server = AlphaDelegationMCPServer { tool, task in
            called.record(tool: tool.rawValue, task: task)
            return .success(text: "accepted")
        }

        let task = String(repeating: "x", count: 32 * 1024)
        let response = await server.handle(line: toolCallLine(id: "at-limit", task: task))
        let object = try responseObject(response)
        XCTAssertNil(object["error"])
        XCTAssertEqual(called.tool, "codexswap_alpha_review")
        XCTAssertEqual(called.task?.utf8.count, 32 * 1024)
    }

    func testToolCallAcceptsAtLimitTasksAfterJSONEscapingAndUTF8Decoding() async throws {
        let tasks: [(String, String)] = [
            ("quotes", String(repeating: "\"", count: AlphaDelegationMCPServer.maxTaskBytes)),
            ("backslashes", String(repeating: "\\", count: AlphaDelegationMCPServer.maxTaskBytes)),
            ("controls", String(repeating: "\u{0001}", count: AlphaDelegationMCPServer.maxTaskBytes)),
            ("multibyte", String(repeating: "é", count: AlphaDelegationMCPServer.maxTaskBytes / 2)),
        ]

        for (id, task) in tasks {
            let called = InvocationBox()
            let server = AlphaDelegationMCPServer { tool, receivedTask in
                called.record(tool: tool.rawValue, task: receivedTask)
                return .success(text: "accepted")
            }
            var frame = toolCallLine(id: id, task: task)
            frame.append(0x0A)
            XCTAssertLessThanOrEqual(frame.count, AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes, id)

            let response = await server.handle(line: frame)
            let object = try responseObject(response)
            XCTAssertNil(object["error"], id)
            XCTAssertEqual(called.tool, AlphaDelegationMCPToolName.review.rawValue, id)
            XCTAssertEqual(called.task?.utf8.count, AlphaDelegationMCPServer.maxTaskBytes, id)
        }
    }

    func testToolCallRejectsOneByteOverDecodedUTF8LimitAfterLargeFrameDecoding() async throws {
        let called = InvocationBox()
        let server = AlphaDelegationMCPServer { _, task in
            called.record(tool: "unexpected", task: task)
            return .success(text: "unexpected")
        }
        let task = String(repeating: "\u{0001}", count: AlphaDelegationMCPServer.maxTaskBytes + 1)
        var frame = toolCallLine(id: "one-byte-over", task: task)
        frame.append(0x0A)
        XCTAssertLessThanOrEqual(frame.count, AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes)

        let response = await server.handle(line: frame)
        let object = try responseObject(response)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertNil(called.tool)
    }

    func testServeAcceptsAnAtLimitEscapedTaskThroughJSONLFraming() async throws {
        XCTAssertEqual(AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes, 256 * 1024)
        XCTAssertEqual(AlphaDelegationMCPServer.maxInboundLineBytes, AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes)

        let called = InvocationBox()
        let server = AlphaDelegationMCPServer { tool, task in
            called.record(tool: tool.rawValue, task: task)
            return .success(text: "accepted")
        }
        let writer = CollectingWriter()
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let serveTask = Task {
            try await server.serve(lines: lines, writer: writer)
        }

        var frame = toolCallLine(
            id: "framed-at-limit",
            task: String(repeating: "\u{0001}", count: AlphaDelegationMCPServer.maxTaskBytes)
        )
        frame.append(0x0A)
        XCTAssertLessThanOrEqual(frame.count, AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes)
        continuation.yield(frame)
        await writer.waitForCount(1)
        continuation.finish()
        try await serveTask.value

        XCTAssertEqual(called.tool, AlphaDelegationMCPToolName.review.rawValue)
        XCTAssertEqual(called.task?.utf8.count, AlphaDelegationMCPServer.maxTaskBytes)
        let values = await writer.lines
        let response = try XCTUnwrap(values.first)
        let object = try responseObject(response)
        XCTAssertNil(object["error"])
        XCTAssertEqual((object["result"] as? [String: Any])?["isError"] as? Bool, false)
    }

    func testToolCallRejectsExtraArgumentsWithoutInvokingHandler() async throws {
        let called = InvocationBox()
        let server = AlphaDelegationMCPServer { _, _ in
            called.record(tool: "unexpected", task: "unexpected")
            return .success(text: "unexpected")
        }

        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":"bad-args","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"edit","extra":true}}}"#)
        let object = try responseObject(response)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertNil(called.tool)
    }

    func testToolCallNotificationDoesNotInvokeHandler() async throws {
        let called = InvocationBox()
        let server = AlphaDelegationMCPServer { _, _ in
            called.record(tool: "unexpected", task: "unexpected")
            return .success(text: "unexpected")
        }

        let response = await server.handle(line: #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"edit"}}}"#)
        XCTAssertNil(response)
        XCTAssertNil(called.tool)
    }

    func testServeKeepsPingResponsiveAndCancellationPreventsSuccess() async throws {
        let started = XCTestExpectation(description: "tool handler started")
        let server = AlphaDelegationMCPServer { _, _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(5))
            return .success(text: "should not be returned")
        }
        let writer = CollectingWriter()
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let serveTask = Task {
            try await server.serve(lines: lines, writer: writer)
        }

        continuation.yield(Data(#"{"jsonrpc":"2.0","id":"slow","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"slow"}}}"#.utf8))
        await fulfillment(of: [started], timeout: 1)
        continuation.yield(Data(#"{"jsonrpc":"2.0","id":"ping","method":"ping"}"#.utf8))
        await writer.waitForCount(1)
        let writtenBeforeCancel = await writer.lines
        let first = try XCTUnwrap(writtenBeforeCancel.first)
        let firstObject = try responseObject(first)
        XCTAssertEqual(firstObject["id"] as? String, "ping")

        continuation.yield(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"slow"}}"#.utf8))
        continuation.finish()
        try await serveTask.value

        let values = await writer.lines
        XCTAssertEqual(values.count, 2)
        let cancelled = try XCTUnwrap(values.map { try? responseObject($0) }.compactMap { $0 }.first { ($0["id"] as? String) == "slow" })
        let result = try XCTUnwrap(cancelled["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(((result["structuredContent"] as? [String: Any])?["code"] as? String), "cancelled")
        XCTAssertFalse(String(decoding: values[1], as: UTF8.self).contains("should not be returned"))
    }

    func testServeMalformedToolCallDoesNotLeakItsPreflightReservation() async throws {
        let called = InvocationBox()
        let server = AlphaDelegationMCPServer { _, task in
            called.record(tool: "review", task: task)
            return .success(text: "valid-result")
        }
        let writer = CollectingWriter()
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let serveTask = Task {
            try await server.serve(lines: lines, writer: writer)
        }

        // Missing jsonrpc is malformed, but it still resembles a tools/call
        // during the admission preflight. The following valid call reuses the
        // same ID and must not inherit a stale reservation.
        continuation.yield(Data(#"{"id":"same","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"malformed"}}}"#.utf8))
        continuation.yield(Data(#"{"jsonrpc":"2.0","id":"same","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"valid"}}}"#.utf8))
        continuation.finish()
        try await serveTask.value

        XCTAssertEqual(called.task, "valid")
        let values = await writer.lines
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.contains { (try? responseObject($0)["error"] as? [String: Any]) != nil })
        XCTAssertTrue(values.contains { (try? responseObject($0)["result"] as? [String: Any]) != nil })
    }

    func testServeEOFCancelsActiveHandlerAndWaitsForIt() async throws {
        let probe = CancellationProbe()
        let server = AlphaDelegationMCPServer { _, _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(30))
                return .success(text: "late")
            } catch {
                await probe.markCancelled()
                throw error
            }
        }
        let writer = CollectingWriter()
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let serveTask = Task {
            try await server.serve(lines: lines, writer: writer)
        }

        continuation.yield(Data(#"{"jsonrpc":"2.0","id":"eof","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"eof"}}}"#.utf8))
        await waitUntil { await probe.started }
        continuation.finish()
        try await serveTask.value

        let cancelled = await probe.didCancel()
        XCTAssertTrue(cancelled)
    }

    func testServeParentCancellationCancelsActiveHandler() async throws {
        let probe = CancellationProbe()
        let server = AlphaDelegationMCPServer { _, _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(30))
                return .success(text: "late")
            } catch {
                await probe.markCancelled()
                throw error
            }
        }
        let writer = CollectingWriter()
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let serveTask = Task {
            try await server.serve(lines: lines, writer: writer)
        }

        // The continuation is intentionally left open: serve must react to
        // parent cancellation rather than waiting for input EOF.
        continuation.yield(Data(#"{"jsonrpc":"2.0","id":"parent","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"parent"}}}"#.utf8))
        await waitUntil { await probe.started }
        serveTask.cancel()
        do {
            try await serveTask.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        continuation.finish()
        let cancelled = await probe.didCancel()
        XCTAssertTrue(cancelled)
    }

    func testServeWriterFailureCancelsActiveHandler() async throws {
        let probe = CancellationProbe()
        let server = AlphaDelegationMCPServer { _, _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(30))
                return .success(text: "late")
            } catch {
                await probe.markCancelled()
                throw error
            }
        }
        let writer = FailingWriter()
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let serveTask = Task {
            try await server.serve(lines: lines, writer: writer)
        }

        continuation.yield(Data(#"{"jsonrpc":"2.0","id":"writer","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"writer"}}}"#.utf8))
        await waitUntil { await probe.started }
        continuation.yield(Data(#"{"jsonrpc":"2.0","id":"ping-writer","method":"ping"}"#.utf8))
        continuation.finish()

        do {
            try await serveTask.value
            XCTFail("expected writer failure")
        } catch {
            // expected transport failure
        }
        let cancelled = await probe.didCancel()
        XCTAssertTrue(cancelled)
    }

    func testServeReturnsAfterChildWriterFailureWhileInputRemainsOpen() async throws {
        let completion = CompletionProbe()
        let writer = FailingWriter()
        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: "completed-before-writer-failure")
        }
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let serveTask = Task {
            do {
                try await server.serve(lines: lines, writer: writer)
            } catch {
                // The writer failure is the expected transport result.
            }
            await completion.markCompleted()
        }
        defer {
            continuation.finish()
            serveTask.cancel()
        }

        continuation.yield(Data(#"{"jsonrpc":"2.0","id":"writer-open","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"writer-open"}}}"#.utf8))
        await waitUntil { await writer.didAttempt() }
        await waitUntil { await completion.didComplete() }

        let attempted = await writer.didAttempt()
        let completed = await completion.didComplete()
        XCTAssertTrue(attempted)
        XCTAssertTrue(completed, "serve remained blocked on open input after child writer failure")
        _ = await serveTask.value
    }

    func testConcurrentToolAdmissionIsBoundedToOneActiveCall() async throws {
        let started = XCTestExpectation(description: "first tool handler started")
        let called = InvocationBox()
        let server = AlphaDelegationMCPServer { _, task in
            called.record(tool: "review", task: task)
            started.fulfill()
            try await Task.sleep(for: .seconds(5))
            return .success(text: "should not finish")
        }

        let firstTask = Task {
            await server.handle(line: #"{"jsonrpc":"2.0","id":"one","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"one"}}}"#)
        }
        await fulfillment(of: [started], timeout: 1)
        let second = await server.handle(line: #"{"jsonrpc":"2.0","id":"two","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"two"}}}"#)
        let secondObject = try responseObject(second)
        XCTAssertNil(secondObject["error"])
        let secondResult = try XCTUnwrap(secondObject["result"] as? [String: Any])
        XCTAssertEqual(secondResult["isError"] as? Bool, true)
        XCTAssertEqual((secondResult["structuredContent"] as? [String: Any])?["code"] as? String, "busy")
        XCTAssertEqual(called.task, "one")

        _ = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"one"}}"#)
        _ = await firstTask.value
    }

    func testCancellationOverridesAHandlerThatSwallowsCancellation() async throws {
        let started = XCTestExpectation(description: "tool handler started")
        let server = AlphaDelegationMCPServer { _, _ in
            started.fulfill()
            try? await Task.sleep(for: .milliseconds(100))
            return .success(text: "late-success")
        }
        let call = Task {
            await server.handle(line: #"{"jsonrpc":"2.0","id":"late","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"late"}}}"#)
        }
        await fulfillment(of: [started], timeout: 1)
        _ = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"late"}}"#)
        let optionalOutput = await call.value
        let output = try XCTUnwrap(optionalOutput)
        let response = try responseObject(output)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("late-success"))
    }

    func testToolFailureIsResultErrorAndDoesNotLeakInternalError() async throws {
        let secret = "internal-secret-should-not-escape"
        let server = AlphaDelegationMCPServer { _, _ in
            throw NSError(domain: "private", code: 13, userInfo: [NSLocalizedDescriptionKey: secret])
        }

        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":"failure","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"edit"}}}"#)
        let object = try responseObject(response)
        XCTAssertNil(object["error"])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["type"] as? String, "text")
        let serialized = String(decoding: try XCTUnwrap(response), as: UTF8.self)
        XCTAssertFalse(serialized.contains(secret))
        XCTAssertFalse(serialized.contains("private"))
    }

    func testUnknownMethodReturnsProtocolErrorButUnknownNotificationStaysSilent() async throws {
        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: "unused")
        }

        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"private/unknown"}"#)
        let object = try responseObject(response)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertFalse(String(decoding: try XCTUnwrap(response), as: UTF8.self).contains("private/unknown"))
        let notification = await server.handle(line: #"{"jsonrpc":"2.0","method":"private/unknown"}"#)
        XCTAssertNil(notification)
    }

    func testMalformedAndOversizedLinesReturnBoundedParseErrorsWithoutEchoingInput() async throws {
        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: "unused")
        }

        let malformed = await server.handle(line: #"{"jsonrpc":"2.0","id":"malformed","method":"ping""#)
        let malformedObject = try responseObject(malformed)
        XCTAssertEqual((malformedObject["error"] as? [String: Any])?["code"] as? Int, -32700)
        let malformedData = try XCTUnwrap(malformed)
        XCTAssertFalse(String(decoding: malformedData, as: UTF8.self).contains("malformed"))

        let marker = "oversized-secret-marker"
        let oversizedPrefix = "{\"jsonrpc\":\"2.0\",\"id\":\"\(marker)\",\"method\":\"ping\",\"padding\":\""
        let oversized = Data((oversizedPrefix + String(repeating: "x", count: AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes + 1) + "\"}").utf8)
        let oversizedResponse = await server.handle(line: oversized)
        let oversizedData = try XCTUnwrap(oversizedResponse)
        XCTAssertLessThanOrEqual(oversizedData.count, AlphaDelegationMCPServer.maxOutboundLineBytes)
        XCTAssertFalse(String(decoding: oversizedData, as: UTF8.self).contains(marker))
        XCTAssertEqual((try responseObject(oversizedResponse)["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testOversizedToolResultBecomesBoundedToolFailure() async throws {
        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: String(repeating: "x", count: 100_000))
        }

        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":"large","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"large"}}}"#)
        let output = try XCTUnwrap(response)
        XCTAssertLessThanOrEqual(output.count, AlphaDelegationMCPServer.maxOutboundLineBytes)
        let object = try responseObject(output)
        XCTAssertEqual((object["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual((((object["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["code"] as? String), "result_too_large")
    }

    func testCodecAndServerTrimAFull256KiBFrameWithoutMutatingTheInput() async throws {
        let payload = Data(#"{"ok":true}"#.utf8)
        let leadingCount = (AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes - payload.count) / 2
        let trailingCount = AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes - payload.count - leadingCount
        let frame = Data(repeating: 0x20, count: leadingCount)
            + payload
            + Data(repeating: 0x09, count: trailingCount)

        let directValue = try AlphaDelegationMCPJSONRPCCodec.decode(frame)
        XCTAssertEqual(directValue, .object(["ok": .bool(true)]))

        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: "unused")
        }
        let requestPayload = Data(#"{"jsonrpc":"2.0","id":"trim","method":"ping"}"#.utf8)
        let requestLeadingCount = (AlphaDelegationMCPServer.maxInboundLineBytes - requestPayload.count) / 2
        let requestTrailingCount = AlphaDelegationMCPServer.maxInboundLineBytes - requestPayload.count - requestLeadingCount
        let request = Data(repeating: 0x0D, count: requestLeadingCount)
            + requestPayload
            + Data(repeating: 0x0A, count: requestTrailingCount)
        let responseData = await server.handle(line: request)
        let response = try XCTUnwrap(responseData)
        let object = try responseObject(response)
        XCTAssertEqual(object["id"] as? String, "trim")
        XCTAssertNotNil(object["result"] as? [String: Any])
    }

    func testCodecRejectsAFull256KiBWhitespaceFrameWithoutRepeatedDataRemoval() async throws {
        let whitespaceBytes: [UInt8] = [0x20, 0x09, 0x0A, 0x0D]
        let frame = Data(
            (0..<AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes).map {
                whitespaceBytes[$0 % whitespaceBytes.count]
            }
        )

        XCTAssertEqual(frame.count, AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes)
        XCTAssertThrowsError(try AlphaDelegationMCPJSONRPCCodec.decode(frame)) { error in
            XCTAssertEqual(error as? AlphaDelegationMCPCodecError, .malformed)
        }
        XCTAssertEqual(frame.count, AlphaDelegationMCPJSONRPCCodec.maxInboundFrameBytes)
        XCTAssertTrue(frame.allSatisfy { whitespaceBytes.contains($0) })

        let server = AlphaDelegationMCPServer { _, _ in
            .success(text: "unexpected")
        }
        let whitespaceResponse = await server.handle(line: frame)
        XCTAssertNil(whitespaceResponse)
    }

    func testBuiltAlphaMCPReviewWorksFromBroadLaunchDirectoriesWithAttachmentOnlyFake() async throws {
        let executable = try alphaMCPExecutable()
        let workspace = try temporaryDirectory(named: "alpha-mcp-fake")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fakeOpenCode = workspace.appendingPathComponent("fake-opencode.sh")
        let fakeContents = #"""
        #!/bin/sh
        set -eu
        task_file=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--file" ]; then
            shift
            task_file="$1"
          fi
          shift
        done
        grep -Fx 'CODEXSWAP_ALPHA_MCP_SAFE_SENTINEL' "$task_file" >/dev/null
        printf '%s\n' '{"type":"text","text":"CODEXSWAP_ALPHA_MCP_SAFE_SENTINEL"}'
        """#
        XCTAssertTrue(FileManager.default.createFile(atPath: fakeOpenCode.path, contents: Data(fakeContents.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeOpenCode.path)

        let launchDirectories = [
            URL(fileURLWithPath: "/", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/tmp", isDirectory: true),
        ]
        for launchDirectory in launchDirectories {
            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = launchDirectory
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            var environment = ProcessInfo.processInfo.environment
            environment["CODEXSWAP_OPENCODE_BIN"] = fakeOpenCode.path
            process.environment = environment
            try process.run()

            defer {
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                try? input.fileHandleForWriting.close()
                try? output.fileHandleForReading.close()
                try? error.fileHandleForReading.close()
            }

            let ping = Data(#"{"jsonrpc":"2.0","id":"ready","method":"ping"}"#.utf8) + Data([0x0A])
            try input.fileHandleForWriting.write(contentsOf: ping)
            let readiness = try readLine(from: output.fileHandleForReading, timeout: 2)
            XCTAssertEqual(try responseObject(readiness)["id"] as? String, "ready", launchDirectory.path)

            let review = Data(#"{"jsonrpc":"2.0","id":"review","method":"tools/call","params":{"name":"codexswap_alpha_review","arguments":{"task":"CODEXSWAP_ALPHA_MCP_SAFE_SENTINEL"}}}"#.utf8) + Data([0x0A])
            try input.fileHandleForWriting.write(contentsOf: review)
            let reviewObject = try responseObject(readLine(from: output.fileHandleForReading, timeout: 2))
            let result = try XCTUnwrap(reviewObject["result"] as? [String: Any], launchDirectory.path)
            XCTAssertEqual(result["isError"] as? Bool, false, launchDirectory.path)
            XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "CODEXSWAP_ALPHA_MCP_SAFE_SENTINEL", launchDirectory.path)

            try input.fileHandleForWriting.close()
            let exitDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < exitDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(process.isRunning, "Alpha MCP did not close after stdin EOF from \(launchDirectory.path)")
        }
    }

    func testBuiltAlphaMCPExitsNormallyForImmediatePreReadinessSIGTERMStress() async throws {
        let executable = try alphaMCPExecutable()
        for iteration in 0..<8 {
            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let pid = process.processIdentifier
            XCTAssertGreaterThan(pid, 0, "iteration \(iteration)")
            // The kernel can deliver SIGTERM between exec(2) and the first user
            // instruction, before any executable can install a handler. Wait only
            // until this process publishes a caught/ignored SIGTERM disposition,
            // then signal it without sending an MCP readiness request.
            let dispositionDeadline = Date().addingTimeInterval(2)
            while !processHandlesShutdownSignal(pid), Date() < dispositionDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(processHandlesShutdownSignal(pid), "iteration \(iteration)")
            XCTAssertEqual(kill(pid, SIGTERM), 0, "iteration \(iteration)")

            let exitDeadline = Date().addingTimeInterval(1.5)
            while process.isRunning, Date() < exitDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            if process.isRunning {
                _ = kill(pid, SIGKILL)
                process.waitUntilExit()
                XCTFail("Alpha MCP ignored immediate SIGTERM at iteration \(iteration)")
            }
            XCTAssertEqual(process.terminationReason, .exit, "iteration \(iteration)")
            XCTAssertEqual(kill(pid, 0), -1, "iteration \(iteration)")
            XCTAssertEqual(errno, ESRCH, "iteration \(iteration)")
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
        }
    }

    func testBuiltAlphaMCPExitsPromptlyWhenStdoutPipeIsNotDrained() async throws {
        let executable = try alphaMCPExecutable()

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()

        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? error.fileHandleForReading.close()
        }

        let readinessRequest = Data(#"{"jsonrpc":"2.0","id":"readiness","method":"ping"}"#.utf8) + Data([0x0A])
        try input.fileHandleForWriting.write(contentsOf: readinessRequest)
        let readinessResponse = try readLine(
            from: output.fileHandleForReading,
            timeout: 2
        )
        let readinessObject = try responseObject(readinessResponse)
        XCTAssertEqual(readinessObject["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(readinessObject["id"] as? String, "readiness")
        XCTAssertNotNil(readinessObject["result"] as? [String: Any])

        let inputDescriptor = input.fileHandleForWriting.fileDescriptor
        let currentFlags = fcntl(inputDescriptor, F_GETFL)
        XCTAssertGreaterThanOrEqual(currentFlags, 0)
        XCTAssertEqual(fcntl(inputDescriptor, F_SETFL, currentFlags | O_NONBLOCK), 0)
        XCTAssertEqual(fcntl(inputDescriptor, F_SETNOSIGPIPE, 1), 0)

        let frame = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8) + Data([0x0A])
        let frameCount = frame.count
        let floodBackpressured = DispatchSemaphore(value: 0)
        let floodComplete = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            var sent = 0
            let target = 4 * 1024 * 1024
            frame.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                while sent < target {
                    let result = Darwin.write(
                        inputDescriptor,
                        baseAddress.advanced(by: sent % frameCount),
                        min(frameCount - (sent % frameCount), target - sent)
                    )
                    if result > 0 {
                        sent += result
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        floodBackpressured.signal()
                        usleep(1_000)
                    } else {
                        break
                    }
                }
            }
            floodComplete.signal()
        }

        XCTAssertEqual(
            floodBackpressured.wait(timeout: .now() + 1),
            .success,
            "4 MiB ping flood did not reach input backpressure"
        )
        let terminationStart = Date()
        XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0)

        while process.isRunning, Date().timeIntervalSince(terminationStart) < 1.5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            XCTFail("Alpha MCP child did not exit after SIGTERM")
        }

        XCTAssertEqual(process.terminationReason, .exit, "termination status: \(process.terminationStatus)")
        XCTAssertLessThan(Date().timeIntervalSince(terminationStart), 1.5)
        XCTAssertEqual(kill(process.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)

        try? input.fileHandleForWriting.close()
        XCTAssertEqual(floodComplete.wait(timeout: .now() + 1), .success)
    }

    func testStdioWriterCancellationStopsAFullPipeWrite() async throws {
        let pipe = Pipe()
        let writer = AlphaDelegationMCPStdioWriter(output: pipe.fileHandleForWriting)
        let writeTask = Task { () -> Bool in
            do {
                try await writer.write(Data(repeating: 0x78, count: 4 * 1024 * 1024))
                return false
            } catch {
                return true
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        writeTask.cancel()
        let interrupted = await writeTask.value
        XCTAssertTrue(interrupted)
        await writer.close()
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }

    func testStdioWriterReportsBrokenPipeWithoutRaisingSIGPIPE() async throws {
        let pipe = Pipe()
        let writer = AlphaDelegationMCPStdioWriter(output: pipe.fileHandleForWriting)
        try pipe.fileHandleForReading.close()

        let failed = await Task { () -> Bool in
            do {
                try await writer.write(Data("broken".utf8))
                return false
            } catch {
                return true
            }
        }.value
        XCTAssertTrue(failed)
        await writer.close()
        try? pipe.fileHandleForWriting.close()
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !(await predicate()), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func alphaMCPExecutable() throws -> URL {
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let configuredPath = ProcessInfo.processInfo.environment["CODEXSWAP_ALPHA_MCP_TEST_EXECUTABLE"]
        let executablePath = configuredPath.flatMap { $0.isEmpty ? nil : $0 }
            ?? ".build/debug/codexswap-alpha-mcp"
        let executable = URL(fileURLWithPath: executablePath, relativeTo: currentDirectory)
            .standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(
                domain: "AlphaDelegationMCPProtocolTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Alpha MCP test executable is not executable: \(executable.path)"]
            )
        }
        return executable
    }

    private func processHandlesShutdownSignal(_ pid: Int32) -> Bool {
        var processInfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &processInfo, &size, nil, 0)
        }
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else { return false }
        let mask = UInt32(1) << UInt32(SIGTERM - 1)
        return processInfo.kp_proc.p_sigcatch & mask != 0
            || processInfo.kp_proc.p_sigignore & mask != 0
    }

    private func readLine(from handle: FileHandle, timeout: TimeInterval) throws -> Data {
        let descriptor = handle.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var line = Data()
        var byte: UInt8 = 0

        while line.count <= AlphaDelegationMCPServer.maxOutboundLineBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw NSError(
                    domain: "AlphaDelegationMCPProtocolTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "timed out waiting for Alpha MCP readiness"]
                )
            }

            var events = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLERR | POLLHUP),
                revents: 0
            )
            let timeoutMilliseconds = Int32(
                Swift.max(1, Swift.min(Double(Int32.max), remaining * 1_000))
            )
            let ready = Darwin.poll(&events, 1, timeoutMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw NSError(
                    domain: "AlphaDelegationMCPProtocolTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "poll failed while waiting for Alpha MCP readiness"]
                )
            }
            if ready == 0 { continue }

            let count = withUnsafeMutableBytes(of: &byte) { bytes in
                Darwin.read(descriptor, bytes.baseAddress, 1)
            }
            if count == 1 {
                line.append(byte)
                if byte == 0x0A { return line }
                continue
            }
            if count == 0 {
                throw NSError(
                    domain: "AlphaDelegationMCPProtocolTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Alpha MCP closed stdout before readiness"]
                )
            }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw NSError(
                domain: "AlphaDelegationMCPProtocolTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "read failed while waiting for Alpha MCP readiness"]
            )
        }

        throw NSError(
            domain: "AlphaDelegationMCPProtocolTests",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Alpha MCP readiness response exceeded the output limit"]
        )
    }

    private func responseObject(_ data: Data?) throws -> [String: Any] {
        let value = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: value) as? [String: Any])
    }

    private func toolCallLine(id: String, task: String) -> Data {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": "codexswap_alpha_review",
                "arguments": ["task": task],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
    }
}

private actor CancellationProbe {
    private(set) var started = false
    private(set) var cancelled = false

    func markStarted() {
        started = true
    }

    func markCancelled() {
        cancelled = true
    }

    func didCancel() -> Bool {
        cancelled
    }
}

private actor CompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func didComplete() -> Bool {
        completed
    }
}

private actor FailingWriter: AlphaDelegationMCPWriter {
    enum Failure: Error {
        case closed
    }

    private var attempted = false

    func write(_ data: Data) async throws {
        attempted = true
        throw Failure.closed
    }

    func didAttempt() -> Bool {
        attempted
    }
}

private final class InvocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var tool: String?
    private(set) var task: String?

    func record(tool: String, task: String) {
        lock.lock()
        self.tool = tool
        self.task = task
        lock.unlock()
    }
}

private actor CollectingWriter: AlphaDelegationMCPWriter {
    private(set) var lines: [Data] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func write(_ data: Data) async throws {
        lines.append(data)
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForCount(_ count: Int) async {
        guard lines.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private func temporaryDirectory(named name: String = "alpha-mcp") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return directory
}
