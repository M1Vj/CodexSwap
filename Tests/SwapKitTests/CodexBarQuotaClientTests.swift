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
        XCTAssertEqual(snapshot.windows?.map(\.windowSeconds), [1_800, 18_000, 604_800])
        XCTAssertEqual(snapshot.windows?.map(\.label), ["30m", "5h", "Weekly"])
        XCTAssertEqual(snapshot.windows?.map(\.usedPercent), [0, 35, 100])
        XCTAssertEqual(snapshot.windows?[1].resetAt, parsedDate("2026-08-02T00:00:00Z"))
        XCTAssertEqual(snapshot.windows?[2].resetAt, parsedDate("2026-08-09T00:00:00.250Z"))
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
