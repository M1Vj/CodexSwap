import XCTest
@testable import SwapKit

final class RunTelemetryTests: XCTestCase {
    private static let fixture = """
    OpenAI Codex v0.144.0
    --------
    workdir: /tmp/example
    --------
    {"type":"thread.started","thread_id":"0199aaaa-bbbb-cccc-dddd-eeeeffff0001"}
    {"type":"turn.started"}
    {"type":"item.started","item":{"id":"item_0","item_type":"command_execution","command":"ls"}}
    {"type":"item.completed","item":{"id":"item_0","item_type":"command_execution","command":"ls"}}
    {"type":"item.completed","item":{"id":"item_1","item_type":"agent_message","text":"Interim note."}}
    not json at all
    {"type":"turn.completed","usage":{"input_tokens":24837,"cached_input_tokens":18001,"output_tokens":1542}}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_2","item_type":"agent_message","text":"All done: shipped the fix."}}
    {"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":58}}
    {"type":"unknown.event","payload":{"x":1}}
    tokens used
    38,353
    """

    func testDecoderExtractsSessionTokensAndFinalMessage() {
        let telemetry = CodexEventDecoder.decode(logText: Self.fixture)

        XCTAssertEqual(telemetry.sessionID, "0199aaaa-bbbb-cccc-dddd-eeeeffff0001")
        XCTAssertEqual(telemetry.inputTokens, 25_837)
        XCTAssertEqual(telemetry.cachedTokens, 18_901)
        XCTAssertEqual(telemetry.outputTokens, 1_600)
        XCTAssertEqual(telemetry.finalMessage, "All done: shipped the fix.")
        XCTAssertNil(telemetry.lastError)
    }

    func testDecoderCapturesErrorsAndToleratesAlternateItemShape() {
        let text = """
        {"type":"thread.started","session_id":"alt-session"}
        {"type":"item.completed","item":{"id":"i","type":"agent_message","content":"Alt shape."}}
        {"type":"error","message":"stream disconnected"}
        {"type":"turn.failed","error":{"message":"usage_limit_reached"}}
        """
        let telemetry = CodexEventDecoder.decode(logText: text)

        XCTAssertEqual(telemetry.sessionID, "alt-session")
        XCTAssertEqual(telemetry.finalMessage, "Alt shape.")
        XCTAssertEqual(telemetry.lastError, "usage_limit_reached")
    }

    func testDecoderReturnsEmptyForPlainTextLog() {
        XCTAssertTrue(CodexEventDecoder.decode(logText: "plain output\nno json here").isEmpty)
    }

    func testRunRecordTelemetryFieldsDecodeTolerantlyAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(TaskRunRecord.self, from: Data("{}".utf8))
        XCTAssertNil(legacy.sessionID)
        XCTAssertNil(legacy.inputTokens)
        XCTAssertNil(legacy.summary)

        let record = TaskRunRecord(
            sessionID: "s",
            inputTokens: 10,
            cachedTokens: 5,
            outputTokens: 3,
            summary: "did things"
        )
        let decoded = try JSONDecoder().decode(TaskRunRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
    }

    func testSettingsHeadroomDecodesAndClamps() throws {
        let defaulted = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(defaulted.automationMinHeadroomPercent, 5)

        let out = try JSONDecoder().decode(Settings.self, from: Data(#"{"automationMinHeadroomPercent":99}"#.utf8))
        XCTAssertEqual(out.automationMinHeadroomPercent, 5)

        let valid = try JSONDecoder().decode(Settings.self, from: Data(#"{"automationMinHeadroomPercent":20}"#.utf8))
        XCTAssertEqual(valid.automationMinHeadroomPercent, 20)
    }

    func testAutomationAccountRequiresHeadroomAndNeverFallsBackForStarts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = { (used: Int) in UsageWindow(label: "Weekly", usedPercent: used, windowSeconds: 604_800, resetAt: nil) }
        var settings = Settings.default
        settings.automationMinHeadroomPercent = 10

        let starved = Account(alias: "starved", accessToken: "t", priority: 10, usage: [weekly(93)])
        let roomy = Account(alias: "roomy", accessToken: "t", priority: 5, usage: [weekly(40)])
        XCTAssertEqual(AppEngine.automationAccount(from: [starved, roomy], settings: settings, now: now)?.alias, "roomy")
        XCTAssertNil(AppEngine.automationAccount(from: [starved], settings: settings, now: now), "no over-threshold fallback for run starts")

        XCTAssertTrue(AppEngine.hasHeadroom(Account(alias: "a", accessToken: "t", usage: []), minimumPercent: 10))
    }

    func testNextFallbackModelWalksListAndSkipsCurrentModel() {
        var task = AutomationTask(title: "t", prompt: "p", repoPath: "/tmp", branch: "b", model: "m0")
        task.fallbackModels = ["m0", "m1", "m2"]
        XCTAssertEqual(AppEngine.nextFallback(for: task)?.model, "m1")

        task.model = "m1"
        task.modelFallbacksUsed = 1
        XCTAssertEqual(AppEngine.nextFallback(for: task)?.model, "m2", "already-adopted fallback is skipped")

        task.modelFallbacksUsed = 3
        XCTAssertNil(AppEngine.nextFallback(for: task))
    }

    func testReducerModelFallbackTransitionThenTerminalFailure() {
        let rejectedTail = "The 'made-up' model is not supported when using Codex"
        let withFallback = TaskOutcomeReducer.reduce(TaskExitContext(
            exitCode: 1,
            stderrTail: rejectedTail,
            currentModel: "made-up",
            nextFallbackModel: "gpt-5.6-sol"
        ))
        XCTAssertEqual(withFallback.outcome, "model-fallback")
        XCTAssertEqual(withFallback.phase, .pausedQuota)
        XCTAssertEqual(withFallback.fallbackModel, "gpt-5.6-sol")
        XCTAssertNil(withFallback.terminalEvent)

        let exhausted = TaskOutcomeReducer.reduce(TaskExitContext(
            exitCode: 1,
            stderrTail: rejectedTail,
            currentModel: "made-up",
            nextFallbackModel: nil
        ))
        XCTAssertEqual(exhausted.outcome, "failed")
        XCTAssertEqual(exhausted.phase, .failed)
        XCTAssertNil(exhausted.fallbackModel)
    }

    func testCapRunsKeepsNewestAndReportsEvicted() {
        let runs = (1...30).map { n in
            TaskRunRecord(startedAt: Date(timeIntervalSince1970: Double(n)), outcome: "continue", logFileName: "run-\(n).log")
        }
        let (kept, evicted) = AppEngine.capRuns(runs, limit: 25)

        XCTAssertEqual(kept.count, 25)
        XCTAssertEqual(evicted.count, 5)
        XCTAssertEqual(kept.first?.logFileName, "run-6.log")
        XCTAssertEqual(evicted.last?.logFileName, "run-5.log")

        let untouched = AppEngine.capRuns(runs, limit: 40)
        XCTAssertEqual(untouched.kept.count, 30)
        XCTAssertTrue(untouched.evicted.isEmpty)
    }

    func testTotalRunsDecodingStaysMonotonicWithCappedHistory() throws {
        let json = #"{"title":"t","prompt":"p","repoPath":"/tmp","branch":"b","totalRuns":40,"runs":[{}]}"#
        let task = try JSONDecoder().decode(AutomationTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.totalRuns, 40)

        let legacy = try JSONDecoder().decode(
            AutomationTask.self,
            from: Data(#"{"title":"t","prompt":"p","repoPath":"/tmp","branch":"b","runs":[{},{}]}"#.utf8)
        )
        XCTAssertEqual(legacy.totalRuns, 2, "legacy tasks derive totalRuns from stored runs")
    }

    func testSummaryExtractorComposesTokensAndSummary() {
        let run = TaskRunRecord(inputTokens: 25_837, cachedTokens: 18_901, outputTokens: 1_600, summary: "Shipped.")
        XCTAssertEqual(TaskRunSummaryExtractor.summary(from: run), "in 25k · cached 18k · out 1600 — Shipped.")
        XCTAssertNil(TaskRunSummaryExtractor.summary(from: TaskRunRecord()))
    }

    func testDecoderChunkedFileReadMatchesTextDecode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-chunk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("run-1.log")
        try Self.fixture.data(using: .utf8)!.write(to: url)

        let chunked = CodexEventDecoder.decode(logURL: url, chunkBytes: 8)

        XCTAssertEqual(chunked, CodexEventDecoder.decode(logText: Self.fixture))
    }

    func testTimelineRunNumbersSurviveHistoryEviction() {
        let task = AutomationTask(
            title: "t", prompt: "p", repoPath: "/tmp", branch: "b",
            runs: (6...8).map { n in
                TaskRunRecord(startedAt: Date(timeIntervalSince1970: Double(n)), finishedAt: Date(timeIntervalSince1970: Double(n) + 1), outcome: "continue", logFileName: "run-\(n).log")
            }
        )

        XCTAssertEqual(TaskRunTimelineRow.rows(for: task).map(\.runNumber), [8, 7, 6])
    }

    func testNextFallbackSkipsDuplicatesAndNeverRevisits() {
        var task = AutomationTask(title: "t", prompt: "p", repoPath: "/tmp", branch: "b", model: "m0")
        task.fallbackModels = ["m0", "m0", "m1"]

        let first = AppEngine.nextFallback(for: task)
        XCTAssertEqual(first?.model, "m1")
        XCTAssertEqual(first?.index, 2)

        task.model = "m1"
        task.modelFallbacksUsed = (first?.index ?? 0) + 1
        XCTAssertNil(AppEngine.nextFallback(for: task), "rejected models are never revisited")
    }

    func testPlanParserScopesCheckboxesToChecklistSectionAndSkipsFences() throws {
        let doc = """
        # Task
        ## Handoff
        - [ ] not a real item
        ## Checklist
        - [x] real done
        - [ ] real open
        ## Original prompt
        ```
        - [ ] fenced checkbox from the prompt
        ```
        - [ ] after another heading
        STATUS: CONTINUE
        """
        let progress = try XCTUnwrap(PlanDocParser.parse(doc))

        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.status, "CONTINUE")
    }

    func testPlanParserWithoutChecklistHeadingKeepsLegacyCounting() throws {
        let progress = try XCTUnwrap(PlanDocParser.parse("- [x] a\n- [ ] b\nSTATUS: CONTINUE"))

        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.total, 2)
    }

    func testMalformedNewMetadataDecodesToDefaultsInsteadOfThrowing() throws {
        let record = try JSONDecoder().decode(
            TaskRunRecord.self,
            from: Data(#"{"servedAliases":"oops","inputTokens":"NaN","summary":42}"#.utf8)
        )
        XCTAssertEqual(record.servedAliases, [])
        XCTAssertNil(record.inputTokens)
        XCTAssertNil(record.summary)

        let task = try JSONDecoder().decode(
            AutomationTask.self,
            from: Data(#"{"title":"t","prompt":"p","repoPath":"/tmp","branch":"b","fallbackModels":123,"totalRuns":"x","runs":"bad"}"#.utf8)
        )
        XCTAssertEqual(task.fallbackModels, [])
        XCTAssertEqual(task.totalRuns, 0)
        XCTAssertTrue(task.runs.isEmpty)
    }

    func testTaskStoreQuarantinesCorruptFileInsteadOfClobbering() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tasks.json")
        try Data("not json at all".utf8).write(to: url)

        let store = TaskStore(url: url)
        let loaded = await store.all()

        XCTAssertTrue(loaded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "corrupt file must be moved aside")
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("tasks.json.corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
    }

    func testInteractiveTrafficRefusedOnlyWhenRoutingDisabled() {
        XCTAssertTrue(refusesInteractiveTraffic(mode: .normal, routingEnabled: false))
        XCTAssertFalse(refusesInteractiveTraffic(mode: .normal, routingEnabled: true))
        XCTAssertFalse(refusesInteractiveTraffic(mode: .task(allowed: ["a"]), routingEnabled: false))
        XCTAssertFalse(refusesInteractiveTraffic(mode: .warmup(alias: "a"), routingEnabled: false))
    }

    func testAutoWarmupOnlySpendsOptedInAccounts() {
        var settings = Settings.default
        settings.automationAccounts = ["worker"]
        settings.warmupExcludedAccounts = ["protected"]

        XCTAssertTrue(AppEngine.autoWarmupEligible(Account(alias: "rotator", accessToken: "t", priority: 5), settings: settings))
        XCTAssertTrue(AppEngine.autoWarmupEligible(Account(alias: "worker", accessToken: "t", priority: 0), settings: settings))
        XCTAssertFalse(AppEngine.autoWarmupEligible(Account(alias: "bystander", accessToken: "t", priority: 0), settings: settings), "accounts the user never enabled must not be warmed automatically")
        XCTAssertFalse(AppEngine.autoWarmupEligible(Account(alias: "protected", accessToken: "t", priority: 10), settings: settings))
        XCTAssertFalse(AppEngine.quotaWarmupEligible(Account(alias: "protected", accessToken: "t"), settings: settings), "manual warm-up must also respect durable protection")
        XCTAssertTrue(AppEngine.quotaWarmupEligible(Account(alias: "bystander", accessToken: "t"), settings: settings))
    }

    func testReasonFormatterReportsOverThresholdDistinctFromHeadroom() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = UsageWindow(label: "Weekly", usedPercent: 95, windowSeconds: 18_000, resetAt: nil)
        let account = Account(alias: "edge", accessToken: "t", usage: [weekly])

        let reasons = TaskSchedulingReasonFormatter.format(
            aliases: ["edge"],
            accounts: [account],
            consumeBankedWindow: true,
            minHeadroomPercent: 5,
            primaryThresholdPercent: 95,
            secondaryThresholdPercent: 98,
            now: now
        )

        XCTAssertTrue(reasons.contains("over threshold"), reasons)
    }

    func testReasonFormatterReportsHeadroomStarvation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = UsageWindow(label: "Weekly", usedPercent: 97, windowSeconds: 604_800, resetAt: nil)
        let account = Account(alias: "hot", accessToken: "t", usage: [weekly])

        let reasons = TaskSchedulingReasonFormatter.format(
            aliases: ["hot"],
            accounts: [account],
            consumeBankedWindow: true,
            minHeadroomPercent: 5,
            now: now
        )

        XCTAssertTrue(reasons.contains("headroom<5%"), reasons)
    }
}
