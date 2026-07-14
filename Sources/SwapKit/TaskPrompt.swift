public enum TaskPrompt {
    public static func firstRun(task: AutomationTask) -> String {
        """
        # Task: \(task.title)

        Work only inside the repository that is already the current working directory: `\(task.repoPath)`.

        ## Safety and branch contract

        - Ensure branch `\(task.branch)` exists. If it is missing, create it from the current HEAD, then check it out.
        - Work only on `\(task.branch)` and never touch other branches.
        - Never push, never force-push, never run `git reset --hard`, and never delete anything outside the repository.
        - Commit with clear conventional messages; batching several items — or the whole session's work — into one bulk commit is fine.
        - You run unattended: no one can answer questions or grant approvals. Never end the session asking for input or "awaiting approval". When a decision has multiple defensible options, pick the most reasonable default yourself, record the decision and rationale in the Work Log, and keep going. `STATUS: BLOCKED` is only for genuinely external obstacles (missing credentials, unavailable services) — a design choice is never one.

        ## Plan-first protocol

        Before making any implementation change, create `\(task.planRelativePath)`. It must contain the task title, the original prompt, a `## Checklist` section of small verifiable `- [ ]` steps, a `## Work Log` section, and this final line:

        `STATUS: CONTINUE`

        Then execute checklist items in order, and complete as many items as the session allows — never end the session after a single item when time and quota remain. After each completed item, change its marker to `- [x]` and append a dated entry to `## Work Log`. Commits may be batched — one bulk commit covering many items, or the whole session, is fine — as long as all work and the plan document are committed before the session ends. While working, verify each item with fast checks scoped to what it touched; run the repository's full verification suite once, before your final commit — not after every item.

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
        - Commit with clear conventional messages; batching several items — or the whole session's work — into one bulk commit is fine.
        - You run unattended: no one can answer questions or grant approvals. Never end the session asking for input or "awaiting approval". When a decision has multiple defensible options, pick the most reasonable default yourself, record the decision and rationale in the Work Log, and keep going. `STATUS: BLOCKED` is only for genuinely external obstacles (missing credentials, unavailable services) — a design choice is never one.

        Read `\(task.planRelativePath)` before changing code. If it does not exist yet (an earlier session ended before planning), first create it with the task title, the original prompt, a `## Checklist` of small verifiable `- [ ]` steps, a `## Work Log`, and a final `STATUS: CONTINUE` line, then commit it. Spot-check only the most recently ticked items with fast, targeted checks — do not re-run full suites to revalidate old work; the previous session's evidence stands unless your changes touch it. Continue from the first unchecked `- [ ]` item and complete as many items as the session allows — never end after a single item when time and quota remain. After each item, tick it and append a dated `## Work Log` entry. Commits may be batched — one bulk commit covering many items, or the whole session, is fine — as long as all work and the plan update are committed before the session ends. Run the repository's full verification suite once, before your final commit — not after every item.

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
        - You run unattended: decide autonomously, record rationale in the Work Log, and reserve `STATUS: BLOCKED` for genuinely external obstacles.

        Read `\(task.planRelativePath)`, then audit the checklist against the actual repository state; delete obsolete items, remove work that is already complete, and merge micro-items into 3–15 executable work packages. Give every package concrete acceptance criteria and order the packages by dependency and impact.

        Rewrite the checklist and append a dated Work Log entry explaining the repair. Then immediately execute the first package and continue through as many packages as time and quota allow. This run must not end without either concrete checklist progress or a materially rewritten plan that removes the cause of stagnation.

        Verify changed work with targeted checks and run the repository's full verification suite once before the final commit. Commit all implementation and plan changes before the session ends. Keep the plan's final line in exactly one of these forms and add nothing after it:

        - `STATUS: COMPLETE` only when every checklist item is ticked and verification succeeded.
        - `STATUS: CONTINUE` when executable work remains.
        - `STATUS: BLOCKED: <reason>` only when an external dependency prevents progress.

        ## Original prompt

        \(fencedBlock(task.prompt))\(evergreenClause(task))
        """
    }

    public static func export(task: AutomationTask, planDoc: String?) -> String {
        let planSection = planDoc.flatMap { $0.isEmpty ? nil : fencedBlock($0) } ?? "no plan yet"
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

        ## Execution contract

        1. Work only inside the repository. Ensure branch `\(task.branch)` exists; if missing, create it from the current HEAD, then check it out. Work only on that branch and never touch other branches.
        2. Never push, never force-push, never run `git reset --hard`, and never delete anything outside the repository.
        3. Commit with clear conventional messages; batching the session's work into one bulk commit is fine.
        4. Maintain `\(task.planRelativePath)`. If no plan exists, first create it with the task title, original prompt, a `## Checklist` of small verifiable `- [ ]` steps, a `## Work Log`, and a final `STATUS: CONTINUE` line, then commit it.
        5. Work through checklist items in order, completing as many as the session allows. Spot-check recently ticked items with targeted checks only, continue at the first `- [ ]` item, tick each completed item to `- [x]`, and append a dated Work Log entry; commits may be batched into one bulk commit for the session, as long as everything including the plan update is committed before the session ends. Run the full verification suite once before the final commit.
        6. Before the session ends, make the plan document's final line `STATUS: COMPLETE` only when all items are ticked and verified, `STATUS: CONTINUE` when work remains, or `STATUS: BLOCKED: <reason>` when external input is required. Commit that update and add nothing after the status line.
        7. If you run unattended, never end a session asking for input or approval: pick the most reasonable default yourself, record the decision and rationale in the Work Log, and continue. `STATUS: BLOCKED` is only for genuinely external obstacles, never a design choice.\(evergreenClause(task))
        """
    }

    static func evergreenClause(_ task: AutomationTask) -> String {
        guard task.isEvergreen else { return "" }
        return """


        ## Evergreen task

        This task loops forever. NEVER write `STATUS: COMPLETE`. End every session with `STATUS: CONTINUE` and append fresh, prioritized unchecked checklist items for the next session so the checklist never runs dry.
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
