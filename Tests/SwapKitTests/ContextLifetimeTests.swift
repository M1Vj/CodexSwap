import XCTest
@testable import SwapKit

final class ContextLifetimeTests: XCTestCase {
    private func makeTask(isEvergreen: Bool = false) -> AutomationTask {
        AutomationTask(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            title: "Context lifetime",
            prompt: "Keep the task moving.",
            repoPath: "/tmp/repository",
            branch: "feat/context-lifetime",
            isEvergreen: isEvergreen
        )
    }

    private func prompts(for task: AutomationTask) -> [String] {
        [
            TaskPrompt.firstRun(task: task),
            TaskPrompt.continuation(task: task),
            TaskPrompt.replan(task: task),
            TaskPrompt.export(task: task, planDoc: nil),
        ]
    }

    func testAllPromptBuildersRequireBoundedRewrittenHandoff() {
        for prompt in prompts(for: makeTask()) {
            XCTAssertTrue(prompt.contains("## Handoff"))
            XCTAssertTrue(prompt.contains("directly under the title"))
            XCTAssertTrue(prompt.contains("current branch HEAD short SHA"))
            XCTAssertTrue(prompt.contains("up to 5 bullet decisions"))
            XCTAssertTrue(prompt.contains("failed approaches to avoid"))
            XCTAssertTrue(prompt.contains("exact next action"))
            XCTAssertTrue(prompt.contains("about 30 lines"))
            XCTAssertTrue(prompt.contains("REWRITE"))
            XCTAssertFalse(prompt.contains("append a dated entry to `## Work Log`"))
            XCTAssertFalse(prompt.contains("append a dated `## Work Log` entry"))
        }
    }

    func testAllPromptBuildersMoveHistoryToWorklog() {
        for prompt in prompts(for: makeTask()) {
            XCTAssertTrue(prompt.contains("WORKLOG.md"))
            XCTAssertTrue(prompt.contains("append"))
        }

        let continuation = TaskPrompt.continuation(task: makeTask())
        XCTAssertTrue(continuation.contains("Read the Handoff and checklist"))
        XCTAssertTrue(continuation.contains("consult `WORKLOG.md` only when investigating regressions"))
    }

    func testAllPromptBuildersUseCommitAwareVerificationReceipts() {
        for prompt in prompts(for: makeTask()) {
            XCTAssertTrue(prompt.contains("Verified: <suite command> at <short SHA>"))
            XCTAssertTrue(prompt.contains("claiming `STATUS: COMPLETE`"))
            XCTAssertTrue(prompt.contains("not an ancestor"))
            XCTAssertTrue(prompt.contains("behavior-relevant files"))
            XCTAssertTrue(prompt.contains("no receipt exists"))
            XCTAssertTrue(prompt.contains("targeted checks suffice"))
            XCTAssertTrue(prompt.contains("refresh the receipt after every full-suite run"))
            XCTAssertFalse(prompt.contains("full verification suite once"))
            XCTAssertFalse(prompt.contains("full suite once"))
        }
    }

    func testEvergreenPromptsArchiveAndReseedBoundedCycles() {
        let task = makeTask(isEvergreen: true)

        for prompt in prompts(for: task) {
            XCTAssertTrue(prompt.contains("CYCLES.md"))
            XCTAssertTrue(prompt.contains("cycle number, dates, a one-paragraph summary, and the completed checklist"))
            XCTAssertTrue(prompt.contains("fresh checklist of 5–10 prioritized items"))
            XCTAssertTrue(prompt.contains("PLAN.md contains only the active cycle"))
            XCTAssertTrue(prompt.contains("`STATUS: CONTINUE`"))
            XCTAssertFalse(prompt.contains("checklist never runs dry"))
            XCTAssertFalse(prompt.contains("This task loops forever"))
        }
    }

    func testHandoffExcerptReturnsTrimmedSectionBody() {
        let plan = """
        # Context lifetime

        ## Handoff

        HEAD: abc1234
        - Decision: keep receipts in the handoff.

        ### Failed approaches
        - Appending history to PLAN.md.

        Next: add parser tests.

        ## Checklist
        - [ ] Implement parser
        STATUS: CONTINUE
        """

        XCTAssertEqual(
            PlanDocParser.handoffExcerpt(plan),
            """
            HEAD: abc1234
            - Decision: keep receipts in the handoff.

            ### Failed approaches
            - Appending history to PLAN.md.

            Next: add parser tests.
            """
        )
    }

    func testHandoffExcerptReturnsNilWhenMissingOrEmpty() {
        XCTAssertNil(PlanDocParser.handoffExcerpt("# Plan\n\n## Checklist\n- [ ] Work"))
        XCTAssertNil(PlanDocParser.handoffExcerpt("# Plan\n\n## Handoff\n\n## Checklist\n- [ ] Work"))
    }

    func testExportIncludesParsedHandoffExcerpt() {
        let plan = "# Plan\n\n## Handoff\nHEAD: abc1234\n\n## Checklist\n- [ ] Work"

        let prompt = TaskPrompt.export(task: makeTask(), planDoc: plan)

        XCTAssertTrue(prompt.contains("## Current Handoff excerpt\n\n```\nHEAD: abc1234\n```"))
    }
}
