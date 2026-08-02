import Foundation
import XCTest
@testable import SwapKit

final class CodexBarQuotaClientTests: XCTestCase {
    func testFetchUsesFixedExecutableAndExactOneShotArguments() async throws {
        let probe = InvocationProbe()
        let client = CodexBarQuotaClient { executable, arguments, _, _ in
            await probe.record(executable: executable, arguments: arguments)
            return CodexBarCommandResult(stdout: Data("[]".utf8), exitCode: 0)
        }

        _ = try await client.fetch(accounts: [Account(alias: "alpha", accessToken: "local")])

        let recordedInvocation = await probe.invocation()
        let invocation = try XCTUnwrap(recordedInvocation)
        XCTAssertEqual(invocation.executable.path, "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")
        XCTAssertEqual(invocation.arguments, [
            "usage", "--provider", "codex", "--all-accounts",
            "--source", "oauth", "--format", "json", "--json-only",
        ])
    }

    func testFetchParsesSecondaryWindowAndResetCredits() async throws {
        let fixture = """
        [{
          "account": "alpha",
          "usage": {
            "primary": {"resetDescription": "RAW-RESET-DESCRIPTION", "resetsAt": "2026-08-02T00:00:00Z", "usedPercent": 35, "windowMinutes": 300},
            "secondary": {"resetDescription": "weekly", "resetsAt": "2026-08-09T00:00:00.250Z", "usedPercent": 125, "windowMinutes": 10080},
            "tertiary": {"resetDescription": "tertiary", "resetsAt": null, "usedPercent": -5, "windowMinutes": 30},
            "codexResetCredits": {
              "availableCount": 2,
              "credits": [{
                "description": "RAW-CREDIT-DESCRIPTION",
                "expires_at": "2026-08-03T00:00:00.500Z",
                "granted_at": "2026-08-01T00:00:00Z",
                "id": "RAW-CREDIT-ID",
                "reset_type": "manual",
                "status": "available",
                "title": "RAW-CREDIT-TITLE"
              }, {
                "description": "used",
                "expires_at": "2026-08-04T00:00:00Z",
                "granted_at": "2026-08-01T00:00:00Z",
                "id": "used-credit",
                "reset_type": "manual",
                "status": "redeemed",
                "title": "used"
              }]
            }
          }
        }]
        """
        let client = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data(fixture.utf8), exitCode: 0)
        }

        let snapshots = try await client.fetch(accounts: [
            Account(alias: "alpha", email: "alpha@example.test", accountID: "alpha-id")
        ])

        let snapshot = try XCTUnwrap(snapshots["alpha-id"])
        XCTAssertEqual(snapshot.windows?.map(\.windowSeconds), [18_000, 604_800])
        XCTAssertEqual(snapshot.windows?.map(\.label), ["5h", "Weekly"])
        XCTAssertEqual(snapshot.windows?.map(\.usedPercent), [35, 100])
        XCTAssertEqual(snapshot.windows?[0].resetAt, parsedDate("2026-08-02T00:00:00Z"))
        XCTAssertEqual(snapshot.windows?[1].resetAt, parsedDate("2026-08-09T00:00:00.250Z"))
        XCTAssertEqual(snapshot.resetCredits?.availableCount, 2)
        XCTAssertEqual(snapshot.resetCredits?.earliestAvailable?.expiresAt, parsedDate("2026-08-03T00:00:00.500Z"))
    }

    func testFetchMapsUniqueEmailAndLocalPartToSafeSnapshots() async throws {
        let fixture = """
        [
          {"account": "not-the-local-alias", "usage": {"accountEmail": "Alice@other.test", "primary": {"resetsAt": null, "usedPercent": 10, "windowMinutes": 300}}},
          {"account": "beta", "usage": {"identity": {"accountEmail": "beta@example.test"}, "secondary": {"resetsAt": null, "usedPercent": 20, "windowMinutes": 10080}}}
        ]
        """
        let client = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data(fixture.utf8), exitCode: 0)
        }

        let snapshots = try await client.fetch(accounts: [
            Account(alias: "alice", email: "alice@example.test", accountID: "alice-id"),
            Account(alias: "gamma", email: "beta@example.test", accountID: "beta-id"),
        ])

        XCTAssertEqual(snapshots["alice-id"]?.windows?.first?.usedPercent, 10)
        XCTAssertEqual(snapshots["beta-id"]?.windows?.first?.windowSeconds, 604_800)
    }

    func testFetchIgnoresAmbiguousAndUnmatchedItems() async throws {
        let fixture = """
        [
          {"account": "shared", "usage": {"primary": {"resetsAt": null, "usedPercent": 10, "windowMinutes": 300}}},
          {"account": "nobody", "usage": {"primary": {"resetsAt": null, "usedPercent": 20, "windowMinutes": 300}}},
          {"account": "unique", "usage": {"primary": {"resetsAt": null, "usedPercent": 30, "windowMinutes": 300}}}
        ]
        """
        let client = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data(fixture.utf8), exitCode: 0)
        }

        let snapshots = try await client.fetch(accounts: [
            Account(alias: "shared", email: "one@example.test", accountID: "one-id"),
            Account(alias: "other", email: "shared@example.test", accountID: "two-id"),
            Account(alias: "unique", accountID: "three-id"),
        ])

        XCTAssertNil(snapshots["one-id"])
        XCTAssertNil(snapshots["two-id"])
        XCTAssertEqual(snapshots["three-id"]?.windows?.first?.usedPercent, 30)
    }

    func testFetchRejectsMalformedOrOversizedOutputWithSafeError() async throws {
        let malformed = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data("{not-json".utf8), stderr: Data("RAW-ERROR-MARKER".utf8), exitCode: 0)
        }
        do {
            _ = try await malformed.fetch(accounts: [])
            XCTFail("Expected malformed response")
        } catch let error as CodexBarQuotaError {
            XCTAssertEqual(error, .malformedResponse)
            XCTAssertFalse(String(describing: error).contains("RAW-ERROR-MARKER"))
        }

        let oversized = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data(repeating: 0x7B, count: 2_000_000), exitCode: 0)
        }
        do {
            _ = try await oversized.fetch(accounts: [])
            XCTFail("Expected oversized output")
        } catch let error as CodexBarQuotaError {
            XCTAssertEqual(error, .oversizedOutput)
        }
    }

    func testSafeSnapshotAndErrorsDoNotRetainRawPrivateMarkers() async throws {
        let fixture = """
        [{
          "account": "RAW-EMAIL-MARKER@example.test",
          "usage": {
            "accountEmail": "RAW-EMAIL-MARKER@example.test",
            "primary": {"resetsAt": null, "usedPercent": 1, "windowMinutes": 300},
            "codexResetCredits": {"availableCount": 1, "credits": [{"id": "RAW-CREDIT-ID-MARKER", "status": "available", "expires_at": null, "description": "RAW-DESCRIPTION-MARKER", "title": "RAW-TITLE-MARKER"}]}
          },
          "error": "RAW-ERROR-MARKER"
        }]
        """
        let client = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data(fixture.utf8), exitCode: 0)
        }
        let snapshots = try await client.fetch(accounts: [
            Account(alias: "safe", email: "raw-email-marker@example.test", accountID: "safe-id")
        ])
        let rendered = String(describing: snapshots)
        for marker in ["RAW-EMAIL-MARKER", "RAW-CREDIT-ID-MARKER", "RAW-DESCRIPTION-MARKER", "RAW-TITLE-MARKER", "RAW-ERROR-MARKER"] {
            XCTAssertFalse(rendered.contains(marker), "snapshot retained private marker \(marker)")
        }

        let failing = CodexBarQuotaClient { _, _, _, _ in
            struct SyntheticFailure: Error { let marker = "RAW-ERROR-MARKER" }
            throw SyntheticFailure()
        }
        do {
            _ = try await failing.fetch(accounts: [])
            XCTFail("Expected safe command failure")
        } catch {
            XCTAssertFalse(String(describing: error).contains("RAW-ERROR-MARKER"))
            XCTAssertEqual(error as? CodexBarQuotaError, .commandFailed)
        }
    }

    func testProcessRunnerCapturesNormalStdoutAndStderr() async throws {
        let result = try await runSyntheticProcess(
            "printf SYNTHETIC-STDOUT; printf SYNTHETIC-STDERR >&2"
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "SYNTHETIC-STDOUT")
        XCTAssertEqual(String(data: result.stderr, encoding: .utf8), "SYNTHETIC-STDERR")
    }

    func testProcessRunnerNonzeroExitMapsToSafeError() async throws {
        let client = CodexBarQuotaClient(runner: { _, _, _, _ in
            try await CodexBarProcessRunner.run(
                URL(fileURLWithPath: "/bin/sh"),
                ["-c", "printf RAW-NONZERO-MARKER >&2; exit 7"],
                .seconds(2),
                1_048_576
            )
        })

        do {
            _ = try await client.fetch(accounts: [])
            XCTFail("Expected nonzero process failure")
        } catch let error as CodexBarQuotaError {
            XCTAssertEqual(error, .commandFailed)
            XCTAssertFalse(String(describing: error).contains("RAW-NONZERO-MARKER"))
        }
    }

    func testFetchKeepsValidSnapshotsFromNonzeroPartialDocument() async throws {
        let fixture = """
        [
          {"account":"alpha","usage":{"primary":{"resetsAt":null,"usedPercent":25,"windowMinutes":300}}},
          {"account":"beta","error":"RAW-PER-ACCOUNT-ERROR-MARKER"}
        ]
        """
        let client = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data(fixture.utf8), exitCode: 1)
        }

        let snapshots = try await client.fetch(accounts: [
            Account(alias: "alpha", accountID: "alpha-id")
        ])

        XCTAssertEqual(snapshots["alpha-id"]?.windows?.first?.usedPercent, 25)
        XCTAssertFalse(String(describing: snapshots).contains("RAW-PER-ACCOUNT-ERROR-MARKER"))
    }

    func testValidSnapshotSurvivesMalformedUsageFromAnotherMatchedAccount() async throws {
        let fixture = """
        [
          {"account":"alpha","usage":{"primary":{"resetsAt":null,"usedPercent":25,"windowMinutes":300}}},
          {"account":"beta","usage":{"primary":{"resetsAt":"RAW-BAD-BETA-TIMESTAMP","usedPercent":10,"windowMinutes":300}}}
        ]
        """
        let client = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data(fixture.utf8), exitCode: 0)
        }

        let snapshots = try await client.fetch(accounts: [
            Account(alias: "alpha", accountID: "alpha-id"),
            Account(alias: "beta", accountID: "beta-id"),
        ])

        XCTAssertEqual(snapshots["alpha-id"]?.windows?.first?.usedPercent, 25)
        XCTAssertNil(snapshots["beta-id"])
    }

    func testMalformedUsagePreservesValidCreditsForSameMatchedAccount() async throws {
        let fixture = """
        [{
          "account":"alpha",
          "usage":{
            "primary":{"resetsAt":"RAW-BAD-USAGE-TIMESTAMP","usedPercent":10,"windowMinutes":300},
            "codexResetCredits":{"availableCount":2,"credits":[]}
          }
        }]
        """
        let client = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data(fixture.utf8), exitCode: 0)
        }

        let snapshots = try await client.fetch(accounts: [Account(alias: "alpha", accountID: "alpha-id")])

        XCTAssertNil(snapshots["alpha-id"]?.windows)
        XCTAssertEqual(snapshots["alpha-id"]?.resetCredits?.availableCount, 2)
    }

    func testValidUsagePreservesMalformedCreditsForSameMatchedAccount() async throws {
        let fixture = """
        [{
          "account":"alpha",
          "usage":{
            "primary":{"resetsAt":null,"usedPercent":10,"windowMinutes":300},
            "codexResetCredits":"RAW-BAD-CREDITS"
          }
        }]
        """
        let client = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data(fixture.utf8), exitCode: 0)
        }

        let snapshots = try await client.fetch(accounts: [Account(alias: "alpha", accountID: "alpha-id")])

        XCTAssertEqual(snapshots["alpha-id"]?.windows?.first?.usedPercent, 10)
        XCTAssertNil(snapshots["alpha-id"]?.resetCredits)
    }

    func testAllMatchedDataMalformedAtExitZeroRemainsMalformedResponse() async throws {
        let fixture = """
        [{"account":"alpha","usage":{"primary":{"resetsAt":"RAW-BAD-ONLY-TIMESTAMP","usedPercent":10,"windowMinutes":300}}}]
        """
        let client = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(stdout: Data(fixture.utf8), exitCode: 0)
        }

        do {
            _ = try await client.fetch(accounts: [Account(alias: "alpha", accountID: "alpha-id")])
            XCTFail("Expected malformed response")
        } catch let error as CodexBarQuotaError {
            XCTAssertEqual(error, .malformedResponse)
            XCTAssertFalse(String(describing: error).contains("RAW-BAD-ONLY-TIMESTAMP"))
        }
    }

    func testProcessRunnerRejectsStdoutOverflow() async throws {
        do {
            _ = try await runSyntheticProcess(
                "dd if=/dev/zero bs=2048 count=1 2>/dev/null",
                maxOutputBytes: 1_024
            )
            XCTFail("Expected stdout overflow")
        } catch let error as CodexBarQuotaError {
            XCTAssertEqual(error, .oversizedOutput)
        }
    }

    func testProcessRunnerRejectsStderrOverflowWithoutRetainingMarker() async throws {
        let marker = "RAW-STDERR-OVERFLOW-MARKER"
        let command = "printf '\(marker)'; dd if=/dev/zero bs=2048 count=1 1>&2 2>/dev/null"
        do {
            _ = try await runSyntheticProcess(command, maxOutputBytes: 1_024)
            XCTFail("Expected stderr overflow")
        } catch let error as CodexBarQuotaError {
            XCTAssertEqual(error, .oversizedOutput)
            XCTAssertFalse(String(describing: error).contains(marker))
        }
    }

    func testProcessRunnerTimeoutEscalatesAfterIgnoredTermination() async throws {
        let probe = ProcessOutcomeProbe()
        let completed = expectation(description: "timeout runner completes")
        Task {
            do {
                _ = try await runSyntheticProcess(
                    "trap '' TERM; (sleep 0.3; kill -KILL $$) & wait",
                    timeout: .milliseconds(40)
                )
                await probe.record(.success)
            } catch let error as CodexBarQuotaError {
                await probe.record(.failure(error))
            } catch {
                await probe.record(.other)
            }
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 2)
        let outcome = await probe.outcome()
        XCTAssertEqual(outcome, .failure(.timeout))
    }

    func testProcessRunnerCancellationTerminatesAndPropagatesCancellation() async throws {
        let probe = ProcessOutcomeProbe()
        let completed = expectation(description: "cancelled runner completes")
        let task = Task {
            do {
                _ = try await runSyntheticProcess(
                    "trap '' TERM; (sleep 0.3; kill -KILL $$) & wait",
                    timeout: .seconds(5)
                )
                await probe.record(.success)
            } catch is CancellationError {
                await probe.record(.cancelled)
            } catch let error as CodexBarQuotaError {
                await probe.record(.failure(error))
            } catch {
                await probe.record(.other)
            }
            completed.fulfill()
        }

        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        await fulfillment(of: [completed], timeout: 2)
        let outcome = await probe.outcome()
        XCTAssertEqual(outcome, .cancelled)
    }

    func testProcessRunnerMapsUnavailableExecutableToSafeError() async throws {
        do {
            _ = try await CodexBarProcessRunner.run(
                URL(fileURLWithPath: "/definitely/not-a-real-CodexBarCLI"),
                [],
                .seconds(1),
                1_024
            )
            XCTFail("Expected unavailable executable")
        } catch let error as CodexBarQuotaError {
            XCTAssertEqual(error, .unavailable)
            XCTAssertFalse(String(describing: error).contains("not-a-real-CodexBarCLI"))
        }
    }

    func testMalformedTimestampAndFieldTypesProduceSafeError() async throws {
        let malformedFixtures = [
            "[{\"account\":\"alpha\",\"usage\":{\"primary\":{\"resetsAt\":\"RAW-BAD-TIMESTAMP\",\"usedPercent\":10,\"windowMinutes\":300}}}]",
            "[{\"account\":\"alpha\",\"usage\":{\"primary\":{\"resetsAt\":null,\"usedPercent\":\"RAW-BAD-FIELD\",\"windowMinutes\":300}}}]",
        ]
        for fixture in malformedFixtures {
            let client = CodexBarQuotaClient { _, _, _, _ in
                CodexBarCommandResult(stdout: Data(fixture.utf8), exitCode: 0)
            }
            do {
                _ = try await client.fetch(accounts: [Account(alias: "alpha")])
                XCTFail("Expected malformed response")
            } catch let error as CodexBarQuotaError {
                XCTAssertEqual(error, .malformedResponse)
                XCTAssertFalse(String(describing: error).contains("RAW-BAD"))
            }
        }
    }

    func testOversizedStderrMapsToSafeErrorWithoutMarker() async throws {
        let marker = "RAW-OVERSIZED-STDERR-MARKER"
        let client = CodexBarQuotaClient { _, _, _, _ in
            CodexBarCommandResult(
                stdout: Data("[]".utf8),
                stderr: Data(repeating: 0x41, count: 2_000_000) + Data(marker.utf8),
                exitCode: 0
            )
        }
        do {
            _ = try await client.fetch(accounts: [])
            XCTFail("Expected oversized stderr")
        } catch let error as CodexBarQuotaError {
            XCTAssertEqual(error, .oversizedOutput)
            XCTAssertFalse(String(describing: error).contains(marker))
        }
    }

    private func parsedDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private actor InvocationProbe {
    struct Invocation: Sendable {
        let executable: URL
        let arguments: [String]
    }

    private var value: Invocation?

    func record(executable: URL, arguments: [String]) {
        value = Invocation(executable: executable, arguments: arguments)
    }

    func invocation() -> Invocation? { value }
}

private actor ProcessOutcomeProbe {
    enum Outcome: Sendable, Equatable {
        case success
        case failure(CodexBarQuotaError)
        case cancelled
        case other
    }

    private var value: Outcome?

    func record(_ outcome: Outcome) {
        value = outcome
    }

    func outcome() -> Outcome? { value }
}

private func runSyntheticProcess(
    _ command: String,
    timeout: Duration = .seconds(2),
    maxOutputBytes: Int = 1_048_576
) async throws -> CodexBarCommandResult {
    try await CodexBarProcessRunner.run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", command],
        timeout,
        maxOutputBytes
    )
}
