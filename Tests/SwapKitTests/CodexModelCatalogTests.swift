import Foundation
import XCTest
@testable import SwapKit

final class CodexModelCatalogTests: XCTestCase {
    private final class CompletionProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var completions = 0

        func recordCompletion() {
            lock.lock()
            completions += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return completions
        }
    }

    private struct StubRunner: CodexCommandRunning {
        let result: Result<CodexCommandResult, CodexCommandError>

        func run(
            arguments: [String],
            timeout: Duration,
            maxOutputBytes: Int
        ) async throws -> CodexCommandResult {
            try result.get()
        }
    }

    private actor RecordingRunner: CodexCommandRunning {
        let output: Data
        private(set) var arguments: [String]?
        private(set) var timeout: Duration?
        private(set) var maxOutputBytes: Int?

        init(output: Data) {
            self.output = output
        }

        func run(
            arguments: [String],
            timeout: Duration,
            maxOutputBytes: Int
        ) async throws -> CodexCommandResult {
            self.arguments = arguments
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            return CodexCommandResult(stdout: output, exitCode: 0)
        }
    }

    private actor SuspendingRunner: CodexCommandRunning {
        private var started = false
        private var startedWaiter: CheckedContinuation<Void, Never>?

        func run(
            arguments: [String],
            timeout: Duration,
            maxOutputBytes: Int
        ) async throws -> CodexCommandResult {
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
            try await Task.sleep(for: .seconds(30))
            return CodexCommandResult(stdout: Data(), exitCode: 0)
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { continuation in
                startedWaiter = continuation
            }
        }
    }

    func testParsesCurrentDebugModelsShapeAndClassifiesProviders() async throws {
        let runner = StubRunner(result: .success(.init(stdout: Data(currentShape.utf8), exitCode: 0)))
        let service = CodexModelCatalogService(runner: runner)

        let models = try await service.load()

        XCTAssertEqual(models.map(\.modelID), ["gpt-5.6-luna", "gpt-5.6-sol", "x-preview-f-free"])
        XCTAssertEqual(models[0].displayName, "GPT-5.6 Luna")
        XCTAssertEqual(models[0].providerFamily, .openAI)
        XCTAssertEqual(models[1].providerFamily, .openAI)
        XCTAssertEqual(models[2].providerFamily, .unknown)
        XCTAssertEqual(models[0].supportedReasoningEfforts.map(\.rawValue), ["low", "high", "max"])
    }

    func testUnknownKeysAndCatalogReorderingDoNotChangeDeterministicOrderAndUnknownEffortSurvives() async throws {
        let first = #"{"models":[{"slug":"future-z","display_name":"Z","supported_reasoning_levels":[{"effort":"future-v9"}],"unknown":{"large":true}},{"slug":"gpt-5.6-luna","display_name":"Luna","supported_reasoning_levels":[{"effort":"max"}]}],"unknown_root":[1,2,3]}"#
        let second = #"{"models":[{"slug":"gpt-5.6-luna","display_name":"Luna","supported_reasoning_levels":[{"effort":"max"}]},{"slug":"future-z","display_name":"Z","supported_reasoning_levels":[{"effort":"future-v9"}]}]}"#

        let firstModels = try await CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(first.utf8), exitCode: 0)))
        ).load()
        let secondModels = try await CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(second.utf8), exitCode: 0)))
        ).load()

        XCTAssertEqual(firstModels, secondModels)
        XCTAssertEqual(firstModels.map(\.modelID), ["future-z", "gpt-5.6-luna"])
        XCTAssertEqual(firstModels[0].supportedReasoningEfforts.map(\.rawValue), ["future-v9"])
    }

    func testMergesOnlyEnabledUniqueBridgedModelsAndUsesConservativeEffortForUnknownBridge() async throws {
        let raw = #"{"models":[{"slug":"gpt-5.6-luna","display_name":"Luna","supported_reasoning_levels":[{"effort":"max"}]}]}"#
        let bridged = [
            BridgedModel(modelID: "x-preview-f-free", displayName: "Alpha", baseURL: "https://alpha.example/v1"),
            BridgedModel(modelID: "x-preview-f-free", displayName: "Duplicate", baseURL: "https://alpha.example/v1", enabled: false),
            BridgedModel(modelID: "disabled-model", baseURL: "https://disabled.example/v1", enabled: false),
            BridgedModel(modelID: "future-bridge", baseURL: "https://bridge.example/v1"),
        ]

        let models = try await CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(raw.utf8), exitCode: 0))),
            bridgedModels: bridged
        ).load()

        XCTAssertEqual(models.map(\.modelID), ["future-bridge", "gpt-5.6-luna", "x-preview-f-free"])
        XCTAssertEqual(models.first(where: { $0.modelID == "future-bridge" })?.supportedReasoningEfforts.map(\.rawValue), ["high"])
        XCTAssertEqual(models.filter { $0.modelID == "x-preview-f-free" }.count, 1)
        XCTAssertEqual(models.first(where: { $0.modelID == "x-preview-f-free" })?.displayName, "Alpha")
    }

    func testDisabledConfiguredBridgeIsOmittedEvenWhenRawCatalogContainsIt() async throws {
        let raw = #"{"models":[{"slug":"gpt-5.6-luna","display_name":"Luna","supported_reasoning_levels":[{"effort":"max"}]},{"slug":"x-preview-f-free","display_name":"Raw Alpha","supported_reasoning_levels":[{"effort":"max"}]}]}"#
        let service = CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(raw.utf8), exitCode: 0))),
            bridgedModels: [BridgedModel(
                modelID: "x-preview-f-free",
                displayName: "Configured Alpha",
                baseURL: "https://alpha.example/v1",
                enabled: false
            )]
        )

        let models = try await service.load()

        XCTAssertEqual(models.map(\.modelID), ["gpt-5.6-luna"])
        XCTAssertNil(models.first(where: { $0.modelID == "x-preview-f-free" }))
    }

    func testDisabledOnlyConfiguredBridgeProducesAnEmptyCatalog() {
        let raw = #"{"models":[{"slug":"x-preview-f-free","display_name":"Raw Alpha","supported_reasoning_levels":[{"effort":"max"}]}]}"#
        let disabled = [BridgedModel(
            modelID: "x-preview-f-free",
            displayName: "Configured Alpha",
            baseURL: "https://alpha.example/v1",
            enabled: false
        )]

        XCTAssertThrowsError(try CodexModelCatalogService.parse(Data(raw.utf8), bridgedModels: disabled)) { error in
            XCTAssertEqual(error as? CodexModelCatalogError, .emptyCatalog)
        }
    }

    func testUnconfiguredReservedBridgeLookingModelsRemainUnknown() async throws {
        let raw = #"{"models":[{"slug":"x-preview-f-free","display_name":"Raw Alpha","supported_reasoning_levels":[{"effort":"max"}]},{"slug":"bridged","display_name":"Reserved Bridge","supported_reasoning_levels":[{"effort":"high"}]},{"slug":"x-future","display_name":"Future Bridge","supported_reasoning_levels":[{"effort":"high"}]}]}"#
        let models = try await CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(raw.utf8), exitCode: 0)))
        ).load()

        XCTAssertEqual(models.first(where: { $0.modelID == "x-preview-f-free" })?.providerFamily, .unknown)
        XCTAssertEqual(models.first(where: { $0.modelID == "bridged" })?.providerFamily, .unknown)
        XCTAssertEqual(models.first(where: { $0.modelID == "x-future" })?.providerFamily, .unknown)
    }

    func testEnabledBridgedIdentitiesOverrideNativePrefixWhenRawCatalogCollides() async throws {
        for modelID in ["gpt-future", "codex-future"] {
            let raw = "{\"models\":[{\"slug\":\"\(modelID)\",\"display_name\":\"Native \(modelID)\",\"supported_reasoning_levels\":[{\"effort\":\"high\"}]},{\"slug\":\"gpt-5.6-luna\",\"display_name\":\"Luna\",\"supported_reasoning_levels\":[{\"effort\":\"max\"}]}]}"
            let models = try await CodexModelCatalogService(
                runner: StubRunner(result: .success(.init(stdout: Data(raw.utf8), exitCode: 0))),
                bridgedModels: [BridgedModel(
                    modelID: modelID,
                    displayName: "Configured bridge",
                    baseURL: "https://bridge.example/v1"
                )]
            ).load()

            XCTAssertEqual(
                models.first(where: { $0.modelID == modelID })?.providerFamily,
                .bridged,
                "configured bridge provenance must override the native prefix heuristic for " + modelID
            )
            XCTAssertEqual(models.first(where: { $0.modelID == "gpt-5.6-luna" })?.providerFamily, .openAI)
        }
    }

    func testDuplicateEnabledBridgedIdentitiesFailClosedRegardlessOfOrder() {
        let firstOrder = [
            BridgedModel(modelID: "gpt-future", displayName: "Bridge A", baseURL: "https://a.example/v1", apiKey: "a"),
            BridgedModel(modelID: "gpt-future", displayName: "Bridge B", baseURL: "https://b.example/v1", apiKey: "b")
        ]
        let secondOrder = Array(firstOrder.reversed())

        for bridgedModels in [firstOrder, secondOrder] {
            XCTAssertThrowsError(
                try CodexModelCatalogService.parse(
                    Data(#"{"models":[]}"#.utf8),
                    bridgedModels: bridgedModels
                )
            ) { error in
                XCTAssertEqual(error as? CodexModelCatalogError, .duplicateBridgedModelID("gpt-future"))
            }
        }
    }

    func testRawUnknownModelsRemainUnknownProvider() async throws {
        let raw = #"{"models":[{"slug":"vendor-model","display_name":"Vendor","supported_reasoning_levels":[{"effort":"medium"}]},{"slug":"bridged","display_name":"Bridge","supported_reasoning_levels":[{"effort":"high"}]},{"slug":"codex-auto-review","display_name":"Codex Auto Review","supported_reasoning_levels":[{"effort":"high"}]}]}"#
        let models = try await CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(raw.utf8), exitCode: 0)))
        ).load()

        XCTAssertEqual(models.first(where: { $0.modelID == "vendor-model" })?.providerFamily, .unknown)
        XCTAssertEqual(models.first(where: { $0.modelID == "bridged" })?.providerFamily, .unknown)
        XCTAssertEqual(models.first(where: { $0.modelID == "codex-auto-review" })?.providerFamily, .openAI)
    }

    func testRejectsEmptyAndMalformedCatalogs() async throws {
        let empty = CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(#"{"models":[]}"#.utf8), exitCode: 0)))
        )
        await assertCatalogError(.emptyCatalog, from: empty)

        let malformed = CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data("not-json".utf8), exitCode: 0)))
        )
        await assertCatalogError(.malformedJSON, from: malformed)
    }

    func testCatalogMapsRunnerFailuresToTypedErrors() async throws {
        for failure in [
            CodexCommandError.nonZeroExit(status: 7),
            CodexCommandError.timeout,
            CodexCommandError.outputLimitExceeded,
            CodexCommandError.launchFailed,
        ] {
            let service = CodexModelCatalogService(
                runner: StubRunner(result: .failure(failure))
            )

            do {
                _ = try await service.load()
                XCTFail("Expected (failure)")
            } catch let error as CodexModelCatalogError {
                guard case .execution(let underlying) = error else {
                    return XCTFail("Unexpected catalog error: \(error)")
                }
                XCTAssertEqual(underlying, failure)
            }
        }
    }

    func testMissingBinaryIsASeparateCatalogError() async throws {
        let service = CodexModelCatalogService(
            runner: StubRunner(result: .failure(.binaryMissing))
        )

        await assertCatalogError(.binaryMissing, from: service)
    }

    func testServiceUsesDebugModelsArgumentsAndSafeBounds() async throws {
        let runner = RecordingRunner(output: Data(currentShape.utf8))
        let service = CodexModelCatalogService(runner: runner)
        _ = try await service.load()

        let arguments = await runner.arguments
        let timeout = await runner.timeout
        let maxOutputBytes = await runner.maxOutputBytes
        XCTAssertEqual(arguments, ["debug", "models"])
        XCTAssertLessThanOrEqual(timeout ?? .zero, .seconds(15))
        XCTAssertEqual(maxOutputBytes, 8 * 1024 * 1024)
    }

    func testServiceRethrowsCancellationWithoutWrappingIt() async throws {
        let runner = SuspendingRunner()
        let service = CodexModelCatalogService(runner: runner)
        let task = Task { try await service.load() }
        await runner.waitUntilStarted()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must remain distinguishable from command failure.
        }
    }

    func testCombinedOutputBoundaryIsAcceptedBeforeJSONValidation() async throws {
        let half = CodexModelCatalogService.maximumOutputBytes / 2
        let runner = StubRunner(result: .success(.init(
            stdout: Data(repeating: 0x20, count: half),
            stderr: Data(repeating: 0x20, count: half),
            exitCode: 0
        )))
        let service = CodexModelCatalogService(runner: runner)

        await assertCatalogError(.malformedJSON, from: service)
    }

    func testAlphaUltraIsSyntheticAndMapsToProviderMax() async throws {
        let raw = #"{"models":[{"slug":"x-preview-f-free","display_name":"Alpha","supported_reasoning_levels":[{"effort":"high"}]}]}"#
        let service = CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(raw.utf8), exitCode: 0))),
            bridgedModels: [BridgedModel(
                modelID: "x-preview-f-free",
                displayName: "Alpha",
                baseURL: "https://alpha.example/v1"
            )],
            alphaUltraEnabled: true
        )

        let models = try await service.load()
        let alpha = try XCTUnwrap(models.first)

        XCTAssertEqual(alpha.supportedReasoningEfforts.map(\.rawValue), ["low", "high", "max", "ultra"])
        XCTAssertTrue(alpha.syntheticUltra)
        XCTAssertEqual(alpha.providerEffort(for: .ultra), .max)
        XCTAssertEqual(alpha.providerEffort(for: .high), .high)
    }

    func testAlphaProviderEffortsStayCanonicalWhileUnknownFutureEffortsSurvive() async throws {
        let raw = #"{"models":[{"slug":"x-preview-f-free","display_name":"Alpha","supported_reasoning_levels":[{"effort":"medium"},{"effort":"xhigh"},{"effort":"future-v9"},{"effort":"ultra"}]}]}"#
        let service = CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(raw.utf8), exitCode: 0))),
            bridgedModels: [BridgedModel(
                modelID: "x-preview-f-free",
                displayName: "Alpha",
                baseURL: "https://alpha.example/v1"
            )],
            alphaUltraEnabled: true
        )

        let models = try await service.load()
        let alpha = try XCTUnwrap(models.first)

        XCTAssertEqual(alpha.supportedReasoningEfforts.map(\.rawValue), ["low", "high", "max", "future-v9", "ultra"])
    }

    func testProviderUltraAlwaysMapsToMaxForGPTAndLeavesOtherEffortsUnchanged() {
        let gpt = CodexModelDescriptor(
            modelID: "gpt-future",
            displayName: "GPT Future",
            supportedReasoningEfforts: [.low, .ultra],
            providerFamily: .openAI
        )

        XCTAssertEqual(gpt.providerEffort(for: .ultra), .max)
        XCTAssertEqual(gpt.providerEffort(for: .low), .low)
        XCTAssertEqual(gpt.providerEffort(for: CodexReasoningEffort(rawValue: "future-v9")), CodexReasoningEffort(rawValue: "future-v9"))
    }

    func testSkipsNullAndScalarModelsAndKeepsValidMixedReasoningEntries() async throws {
        let raw = #"{"models":[null,17,{"slug":"valid-model","display_name":"Valid","supported_reasoning_levels":[null,17,{"effort":null},{"effort":7},{"effort":"future-v9"}]},{"slug":"gpt-5.6-luna","display_name":"Luna","supported_reasoning_levels":[null,"scalar",{"effort":"max"}]}]}"#
        let service = CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(raw.utf8), exitCode: 0)))
        )

        let models = try await service.load()

        XCTAssertEqual(models.map(\.modelID), ["gpt-5.6-luna", "valid-model"])
        XCTAssertEqual(models.first(where: { $0.modelID == "valid-model" })?.supportedReasoningEfforts.map(\.rawValue), ["future-v9"])
        XCTAssertEqual(models.first(where: { $0.modelID == "gpt-5.6-luna" })?.supportedReasoningEfforts.map(\.rawValue), ["max"])
    }

    func testFoundationRunnerReportsNonzeroExitWithoutLeakingOutput() async throws {
        let runner = FoundationCodexCommandRunner(binary: "/bin/sh")

        do {
            _ = try await runner.run(arguments: ["-c", "printf secret; exit 7"], timeout: .seconds(2), maxOutputBytes: 1_024)
            XCTFail("Expected nonzero exit")
        } catch let error as CodexCommandError {
            XCTAssertEqual(error, .nonZeroExit(status: 7))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testFoundationRunnerReportsLaunchFailureForInvalidExecutable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-catalog-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an executable format".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let runner = FoundationCodexCommandRunner(binary: url.path)

        do {
            _ = try await runner.run(arguments: [], timeout: .seconds(2), maxOutputBytes: 1_024)
            XCTFail("Expected launch failure")
        } catch let error as CodexCommandError {
            XCTAssertEqual(error, .launchFailed)
        }
    }

    func testFoundationRunnerTimesOutAndReturnsPromptly() async throws {
        let runner = FoundationCodexCommandRunner(binary: "/bin/sleep")
        let started = Date()

        do {
            _ = try await runner.run(arguments: ["30"], timeout: .milliseconds(50), maxOutputBytes: 1_024)
            XCTFail("Expected timeout")
        } catch let error as CodexCommandError {
            XCTAssertEqual(error, .timeout)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        }
    }

    func testFoundationRunnerCapsCombinedStdoutAndStderrAndSeparatesStreams() async throws {
        let runner = FoundationCodexCommandRunner(binary: "/bin/sh")

        do {
            _ = try await runner.run(
                arguments: ["-c", "printf 12345; printf 67890 >&2"],
                timeout: .seconds(2),
                maxOutputBytes: 8
            )
            XCTFail("Expected combined output limit")
        } catch let error as CodexCommandError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }

        let result = try await runner.run(
            arguments: ["-c", "printf json; printf warning >&2"],
            timeout: .seconds(2),
            maxOutputBytes: 1_024
        )
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "json")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "warning")
    }

    func testFoundationRunnerJoinsReadersWhenOwnedCommandClosesPipes() async throws {
        let completionProbe = CompletionProbe()
        let runner = FoundationCodexCommandRunner(
            binary: "/bin/sh",
            readerCompletionObserver: { completionProbe.recordCompletion() }
        )
        let started = Date()

        // Foundation Process does not expose a portable, mechanically-owned
        // process-group API here. Keep this lifecycle fixture descendant-free:
        // the exact command closes both owned pipes and exits cooperatively.
        let result = try await runner.run(
            arguments: ["-c", "exec 1>&- 2>&-; exit 0"],
            timeout: .seconds(3),
            maxOutputBytes: 1_024
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(completionProbe.count, 2, "Both detached readers must complete before return")
    }

    func testDuplicateRawModelsFailClosedInsteadOfMergingCapabilities() throws {
        let malformed = #"{"slug":"gpt-5.6-luna","display_name":7,"supported_reasoning_levels":[null,7]}"#
        let first = #"{"models":[{"slug":"gpt-5.6-luna","display_name":"Zulu","supported_reasoning_levels":[{"effort":"max"},{"effort":"low"}]},"# + malformed + #",{"slug":"gpt-5.6-luna","display_name":"Luna","supported_reasoning_levels":[{"effort":"high"}]}]}"#
        let second = #"{"models":[{"slug":"gpt-5.6-luna","display_name":"Luna","supported_reasoning_levels":[{"effort":"high"}]},"# + malformed + #",{"slug":"gpt-5.6-luna","display_name":"Zulu","supported_reasoning_levels":[{"effort":"low"},{"effort":"max"}]}]}"#

        for raw in [first, second] {
            XCTAssertThrowsError(try CodexModelCatalogService.parse(Data(raw.utf8))) { error in
                XCTAssertEqual(error as? CodexModelCatalogError, .duplicateCatalogModelID("gpt-5.6-luna"))
            }
        }
    }

    func testDescriptorIsImmutableCodableSendableValue() throws {
        let descriptor = CodexModelDescriptor(
            modelID: "future-model",
            displayName: "Future",
            supportedReasoningEfforts: [.low, CodexReasoningEffort(rawValue: "future-v9")],
            providerFamily: .unknown,
            syntheticUltra: false
        )

        let decoded = try JSONDecoder().decode(
            CodexModelDescriptor.self,
            from: JSONEncoder().encode(descriptor)
        )

        XCTAssertEqual(decoded, descriptor)
    }

    func testMalformedModelEntriesDoNotMakeAUsableCatalogEmpty() async throws {
        let raw = #"{"models":[{"slug":"","display_name":"No ID","supported_reasoning_levels":[{"effort":"max"}]},{"slug":"gpt-5.6-luna","display_name":"Luna","supported_reasoning_levels":[{"effort":"max"}]}]}"#
        let models = try await CodexModelCatalogService(
            runner: StubRunner(result: .success(.init(stdout: Data(raw.utf8), exitCode: 0)))
        ).load()

        XCTAssertEqual(models.map(\.modelID), ["gpt-5.6-luna"])
    }

    private func assertCatalogError(
        _ expected: CodexModelCatalogError,
        from service: CodexModelCatalogService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.load()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as CodexModelCatalogError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private var currentShape: String {
        #"""
        {
          "models": [
            {
              "slug": "gpt-5.6-luna",
              "display_name": "GPT-5.6 Luna",
              "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}, {"effort": "max"}],
              "context_window": 256000,
              "future_metadata": {"large": [1, 2, 3]}
            },
            {
              "slug": "gpt-5.6-sol",
              "display_name": "GPT-5.6 Sol",
              "supported_reasoning_levels": [{"effort": "high"}, {"effort": "max"}]
            },
            {
              "slug": "x-preview-f-free",
              "display_name": "Ox Alpha Free",
              "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}, {"effort": "max"}]
            }
          ]
        }
        """#
    }
}
