import XCTest
@testable import SwapKit

final class InspectorHardeningTests: XCTestCase {
    func testRunIdentityResolutionSurvivesHistoryEviction() {
        let evictedID = UUID()
        let retainedID = UUID()
        let latestID = UUID()
        let retainedRuns = [
            TaskRunRecord(id: retainedID, logFileName: "run-26.log"),
            TaskRunRecord(id: latestID, logFileName: "run-27.log"),
        ]

        XCTAssertEqual(
            TaskRunIdentityResolver.record(id: retainedID, in: retainedRuns)?.logFileName,
            "run-26.log"
        )
        XCTAssertNil(TaskRunIdentityResolver.record(id: evictedID, in: retainedRuns))
        XCTAssertEqual(
            TaskRunIdentityResolver.selectedRunID(
                current: evictedID,
                previousLatest: retainedID,
                runs: retainedRuns
            ),
            latestID
        )
    }

    func testRunIdentityResolutionFollowsNewLatestRunByID() {
        let olderID = UUID()
        let previousLatestID = UUID()
        let newLatestID = UUID()
        let runs = [
            TaskRunRecord(id: olderID, logFileName: "run-24.log"),
            TaskRunRecord(id: previousLatestID, logFileName: "run-25.log"),
            TaskRunRecord(id: newLatestID, logFileName: "run-26.log"),
        ]

        XCTAssertEqual(
            TaskRunIdentityResolver.selectedRunID(
                current: previousLatestID,
                previousLatest: previousLatestID,
                runs: runs
            ),
            newLatestID
        )
        XCTAssertEqual(
            TaskRunIdentityResolver.selectedRunID(
                current: olderID,
                previousLatest: previousLatestID,
                runs: runs
            ),
            olderID,
            "A deliberate historical selection must not jump to the latest run"
        )
    }

    func testWaitingHeaderUsesMostCommonSchedulingReasonCategory() {
        let quotaOne = UUID()
        let quotaTwo = UUID()
        let proxy = UUID()

        XCTAssertEqual(
            TaskBoardWaitingHeader.text(
                waitingTaskIDs: [quotaOne, quotaTwo, proxy],
                schedulingReasons: [
                    quotaOne.uuidString: "alpha: cooldown until Jul 14 18:00",
                    quotaTwo.uuidString: "beta: over threshold (5h 95% used)",
                    proxy.uuidString: "Proxy is unavailable",
                ]
            ),
            "Waiting for quota — 3 queued"
        )
    }

    func testWaitingHeaderUsesNeutralWordingForMixedReasons() {
        let repository = UUID()
        let account = UUID()

        XCTAssertEqual(
            TaskBoardWaitingHeader.text(
                waitingTaskIDs: [repository, account],
                schedulingReasons: [
                    repository.uuidString: "Repository is busy",
                    account.uuidString: "No accounts configured",
                ]
            ),
            "2 waiting"
        )
    }

    func testWaitingHeaderDistinguishesNonQuotaCategories() {
        let taskID = UUID()
        let cases = [
            ("Automation is disabled", "Automation off — 1 queued"),
            ("Proxy is unavailable", "Waiting for proxy — 1 queued"),
            ("Waiting for an available run slot", "Waiting for a run slot — 1 queued"),
            ("Repository is busy", "Waiting for repository — 1 queued"),
            ("gamma: needs login", "Waiting for an account — 1 queued"),
            ("delta: unknown account", "Waiting for an account — 1 queued"),
            ("epsilon: banked window not started", "Waiting for quota — 1 queued"),
            ("zeta: headroom<5% (Weekly 97% used)", "Waiting for quota — 1 queued"),
            ("Retrying when backoff ends", "Waiting to retry — 1 queued"),
        ]

        for (reason, expected) in cases {
            XCTAssertEqual(
                TaskBoardWaitingHeader.text(
                    waitingTaskIDs: [taskID],
                    schedulingReasons: [taskID.uuidString: reason]
                ),
                expected,
                reason
            )
        }
    }

    func testWaitingHeaderIsNeutralWhenReasonIsMissing() {
        XCTAssertEqual(
            TaskBoardWaitingHeader.text(waitingTaskIDs: [UUID()], schedulingReasons: [:]),
            "1 waiting"
        )
    }

    func testWaitingHeaderIsIdleWithoutWaitingTasks() {
        XCTAssertEqual(
            TaskBoardWaitingHeader.text(waitingTaskIDs: [], schedulingReasons: [:]),
            "Idle"
        )
    }
}
