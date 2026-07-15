public enum TaskPrompt {
    public static func firstRun(task: AutomationTask) -> String {
        """
        # Task: \(task.title)

        Work only inside the repository that is already the current working directory: `\(task.repoPath)`.

        ## Safety and branch contract

        - Ensure branch `\(task.branch)` exists. If it is missing, create it from the current HEAD, then check it out.
        - Work only on `\(task.branch)` and never touch other branches.
        - Never push, never force-push, never run `git reset --hard`, and never delete anything outside the repository.
        - Commit with clear conventional messages; batching several items — or the whole session's work — into one bulk commit is fine. If the original prompt specifies commit metadata or trailers, copy it verbatim and inspect the final commit message before continuing; amend any local mismatch.
        - You run unattended: no one can answer questions or grant approvals. Never end the session asking for input or "awaiting approval". When a decision has multiple defensible options, pick the most reasonable default yourself, record the decision and rationale in `WORKLOG.md`, and keep going. `STATUS: BLOCKED` is only for genuinely external obstacles (missing credentials, unavailable services) — a design choice is never one.
        - Use your native subagents for bounded parallelizable work — deep research sweeps, independent review of a finished unit, broad exploration — while you continue on the critical path. Keep each subagent brief small and timeboxed; narrow or absorb any that overruns its scope. Never sit idle waiting on a subagent and never block the session's end or final commit on one. After one wait without a result, continue useful local work; if none remains, interrupt and absorb the subtask instead of issuing another wait-only turn.

        ## Plan-first protocol

        Before making any implementation change, create `\(task.planRelativePath)`. It must contain the task title, the `## Handoff` section described below directly under the title, the original prompt, a `## Checklist` section of small verifiable `- [ ]` steps, and this final line:

        `STATUS: CONTINUE`

        Create `WORKLOG.md` next to the plan and append dated progress and rationale there. Then execute checklist items in order, and complete as many items as the session allows — never end the session after a single item when time and quota remain. After each completed item, change its marker to `- [x]` and append its dated history to `WORKLOG.md`. Commits may be batched — one bulk commit covering many items, or the whole session's implementation, is fine — as long as all work and the plan document are committed before the session ends. While working, verify each item with fast checks scoped to what it touched.

        \(contextLifetimeContract(task: task))

        Keep `\(task.planRelativePath)` current throughout the session. Its final line must always use exactly one of these forms:

        - `STATUS: COMPLETE` only when every checklist item is ticked and verification succeeded.
        - `STATUS: CONTINUE` when work remains because the session, time, or quota is ending.
        - `STATUS: BLOCKED: <reason>` when progress requires external input or an unavailable dependency.

        Replace the status line before the session ends, keep it as the document's final line, and commit the final plan update. Do not add content after it.

        ## Original prompt

        \(fencedBlock(task.prompt))\(evergreenClause(task))
        """
    }

    public static func continuation(task: AutomationTask) -> String {
        """
        # Continue task: \(task.title)

        Work only inside the repository that is already the current working directory: `\(task.repoPath)`.

        - Ensure branch `\(task.branch)` exists. If it is missing, create it from the current HEAD, then check it out.
        - Work only on `\(task.branch)` and never touch other branches.
        - Never push, never force-push, never run `git reset --hard`, and never delete anything outside the repository.
        - Commit with clear conventional messages; batching several items — or the whole session's work — into one bulk commit is fine. If the original prompt specifies commit metadata or trailers, copy it verbatim and inspect the final commit message before continuing; amend any local mismatch.
        - You run unattended: no one can answer questions or grant approvals. Never end the session asking for input or "awaiting approval". When a decision has multiple defensible options, pick the most reasonable default yourself, record the decision and rationale in `WORKLOG.md`, and keep going. `STATUS: BLOCKED` is only for genuinely external obstacles (missing credentials, unavailable services) — a design choice is never one.
        - Use your native subagents for bounded parallelizable work — deep research sweeps, independent review of a finished unit, broad exploration — while you continue on the critical path. Keep each subagent brief small and timeboxed; narrow or absorb any that overruns its scope. Never sit idle waiting on a subagent and never block the session's end or final commit on one. After one wait without a result, continue useful local work; if none remains, interrupt and absorb the subtask instead of issuing another wait-only turn.

        Read the Handoff and checklist in `\(task.planRelativePath)` before changing code; consult `WORKLOG.md` only when investigating regressions. If the plan does not exist yet (an earlier session ended before planning), first create it with the task title, the `## Handoff` section described below directly under the title, the original prompt, a `## Checklist` of small verifiable `- [ ]` steps, and a final `STATUS: CONTINUE` line; create `WORKLOG.md` next to it, then commit them. Spot-check only the most recently ticked items with fast, targeted checks — do not re-run full suites to revalidate old work unless the verification policy below requires it. Continue from the first unchecked `- [ ]` item and complete as many items as the session allows — never end after a single item when time and quota remain. After each item, tick it and append dated history to `WORKLOG.md`. Commits may be batched — one bulk commit covering many items, or the whole session's implementation, is fine — as long as all work and the plan update are committed before the session ends.

        \(contextLifetimeContract(task: task))

        Maintain the checklist and keep the document's final line in exactly one of these forms:

        - `STATUS: COMPLETE` only when every checklist item is ticked and verification succeeded.
        - `STATUS: CONTINUE` when work remains because the session, time, or quota is ending.
        - `STATUS: BLOCKED: <reason>` when progress requires external input or an unavailable dependency.

        Replace the final status line before the session ends, commit the final plan update, and do not add content after it.

        ## Original prompt

        \(fencedBlock(task.prompt))\(evergreenClause(task))
        """
    }

    public static func replan(task: AutomationTask) -> String {
        """
        # Repair and continue task plan: \(task.title)

        Work only inside the repository that is already the current working directory: `\(task.repoPath)`.

        - Ensure branch `\(task.branch)` exists. If it is missing, create it from the current HEAD, then check it out.
        - Work only on `\(task.branch)` and never touch other branches.
        - Never push, never force-push, never run `git reset --hard`, and never delete anything outside the repository.
        - Commit with clear conventional messages; batching several packages — or the whole session's implementation — into one bulk commit is fine. If the original prompt specifies commit metadata or trailers, copy it verbatim and inspect the final commit message before continuing; amend any local mismatch.
        - You run unattended: decide autonomously, record rationale in `WORKLOG.md`, and reserve `STATUS: BLOCKED` for genuinely external obstacles.
        - Use your native subagents for bounded parallelizable work — deep research sweeps, independent review of a finished unit, broad exploration — while you continue on the critical path. Keep each subagent brief small and timeboxed; narrow or absorb any that overruns its scope. Never sit idle waiting on a subagent and never block the session's end or final commit on one. After one wait without a result, continue useful local work; if none remains, interrupt and absorb the subtask instead of issuing another wait-only turn.

        Read the Handoff and checklist in `\(task.planRelativePath)`; consult `WORKLOG.md` only when investigating regressions. Then audit the checklist against the actual repository state; delete obsolete items, remove work that is already complete, and merge micro-items into 3–15 executable work packages. Give every package concrete acceptance criteria and order the packages by dependency and impact.

        Rewrite the checklist and append a dated `WORKLOG.md` entry explaining the repair. Then immediately execute the first package and continue through as many packages as time and quota allow. This run must not end without either concrete checklist progress or a materially rewritten plan that removes the cause of stagnation.

        Verify changed work with targeted checks. Commit all implementation and plan changes before the session ends. Keep the plan's final line in exactly one of these forms and add nothing after it:

        - `STATUS: COMPLETE` only when every checklist item is ticked and verification succeeded.
        - `STATUS: CONTINUE` when executable work remains.
        - `STATUS: BLOCKED: <reason>` only when an external dependency prevents progress.

        \(contextLifetimeContract(task: task))

        ## Original prompt

        \(fencedBlock(task.prompt))\(evergreenClause(task))
        """
    }

    public static func export(task: AutomationTask, planDoc: String?) -> String {
        let planSection = planDoc.flatMap { $0.isEmpty ? nil : fencedBlock($0) } ?? "no plan yet"
        let handoffSection = planDoc.flatMap(PlanDocParser.handoffExcerpt).map(fencedBlock) ?? "no handoff yet"
        return """
        # Task handoff: \(task.title)

        - Repository: `\(task.repoPath)`
        - Branch: `\(task.branch)`
        - Model hint: `\(task.model)`
        - Plan document: `\(task.planRelativePath)`

        ## Original prompt

        \(fencedBlock(task.prompt))

        ## Current plan document

        \(planSection)

        ## Current Handoff excerpt

        \(handoffSection)

        ## Execution contract

        1. Work only inside the repository. Ensure branch `\(task.branch)` exists; if missing, create it from the current HEAD, then check it out. Work only on that branch and never touch other branches.
        2. Never push, never force-push, never run `git reset --hard`, and never delete anything outside the repository.
        3. Commit with clear conventional messages; batching the session's work into one bulk commit is fine. If the original prompt specifies commit metadata or trailers, copy it verbatim and inspect the final commit message before continuing; amend any local mismatch.
        4. Maintain `\(task.planRelativePath)`. If no plan exists, first create it with the task title, the `## Handoff` section described below directly under the title, original prompt, a `## Checklist` of small verifiable `- [ ]` steps, and a final `STATUS: CONTINUE` line; create `WORKLOG.md` next to it, then commit them.
        5. Read the Handoff and checklist, and consult `WORKLOG.md` only when investigating regressions. Work through checklist items in order, completing as many as the session allows. Spot-check recently ticked items with targeted checks only, continue at the first `- [ ]` item, tick each completed item to `- [x]`, and append dated history to `WORKLOG.md`; commits may be batched into one bulk commit for the session, as long as everything including the plan update is committed before the session ends.
        6. Before the session ends, make the plan document's final line `STATUS: COMPLETE` only when all items are ticked and verified, `STATUS: CONTINUE` when work remains, or `STATUS: BLOCKED: <reason>` when external input is required. Commit that update and add nothing after the status line.
        7. If you run unattended, never end a session asking for input or approval: pick the most reasonable default yourself, record the decision and rationale in `WORKLOG.md`, and continue. `STATUS: BLOCKED` is only for genuinely external obstacles, never a design choice.
        8. If your harness supports subagents, delegate bounded parallelizable work (research sweeps, independent review, broad exploration) to them with small timeboxed briefs, and never block the session's end on one. After one wait without a result, continue useful local work; if none remains, interrupt and absorb the subtask instead of issuing another wait-only turn.\(evergreenClause(task))

        \(contextLifetimeContract(task: task))
        """
    }

    static func evergreenClause(_ task: AutomationTask) -> String {
        guard task.isEvergreen else { return "" }
        return """


        ## Evergreen task

        NEVER write `STATUS: COMPLETE` for this task. When every current-cycle item is ticked, append the finished cycle to `CYCLES.md` next to the plan, including the cycle number, dates, a one-paragraph summary, and the completed checklist. Then reseed PLAN.md with a fresh checklist of 5–10 prioritized items and write `STATUS: CONTINUE`. PLAN.md contains only the active cycle.
        """
    }

    private static func contextLifetimeContract(task: AutomationTask) -> String {
        """
        ## Context lifetime contract

        Maintain a `## Handoff` section directly under the title in `\(task.planRelativePath)`. Keep it to about 30 lines and include the current branch HEAD short SHA, up to 5 bullet decisions that constrain future work, failed approaches to avoid, the exact next action, and the verification receipt described below. At the end of every session, REWRITE this section to represent current state; never append session history to it. Append chronological progress and rationale to `WORKLOG.md` next to the plan instead.

        Record a `Verified: <suite command> at <short SHA>` line in the Handoff whenever the full suite runs. Run the full suite only when claiming `STATUS: COMPLETE`; when the receipt SHA is not an ancestor of the work about to be committed and this session changed behavior-relevant files; or when no receipt exists. Otherwise targeted checks suffice. Always refresh the receipt after every full-suite run. When a full suite is required, commit the behavior-relevant work first, run the suite against that clean HEAD, then update and commit the Handoff receipt; this receipt-only commit is compatible with batching the implementation into one bulk commit.
        """
    }

    private static func fencedBlock(_ text: String) -> String {
        let fence = markdownFence(for: text)
        return "\(fence)\n\(text)\n\(fence)"
    }

    private static func markdownFence(for text: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in text {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: max(3, longestRun + 1))
    }
}
