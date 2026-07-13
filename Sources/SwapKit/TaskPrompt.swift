public enum TaskPrompt {
    public static func firstRun(task: AutomationTask) -> String {
        """
        # Task: \(task.title)

        Work only inside the repository that is already the current working directory: `\(task.repoPath)`.

        ## Safety and branch contract

        - Ensure branch `\(task.branch)` exists. If it is missing, create it from the current HEAD, then check it out.
        - Work only on `\(task.branch)` and never touch other branches.
        - Never push, never force-push, never run `git reset --hard`, and never delete anything outside the repository.
        - Make small conventional commits as work progresses.

        ## Plan-first protocol

        Before making any implementation change, create `\(task.planRelativePath)`. It must contain the task title, the original prompt, a `## Checklist` section of small verifiable `- [ ]` steps, a `## Work Log` section, and this final line:

        `STATUS: CONTINUE`

        Commit the initial plan. Then execute checklist items in order. After each completed and verified item, change its marker to `- [x]`, append a dated entry to `## Work Log`, and make a small conventional commit containing the related work and plan update.

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
        - Make small conventional commits as work progresses.

        Read `\(task.planRelativePath)` before changing code. If it does not exist yet (an earlier session ended before planning), first create it with the task title, the original prompt, a `## Checklist` of small verifiable `- [ ]` steps, a `## Work Log`, and a final `STATUS: CONTINUE` line, then commit it. Verify that every ticked `- [x]` item still holds, then continue from the first unchecked `- [ ]` item. Complete and verify items in order. After each item, tick it, append a dated `## Work Log` entry, and make a small conventional commit containing the related work and plan update.

        Maintain the checklist and keep the document's final line in exactly one of these forms:

        - `STATUS: COMPLETE` only when every checklist item is ticked and verification succeeded.
        - `STATUS: CONTINUE` when work remains because the session, time, or quota is ending.
        - `STATUS: BLOCKED: <reason>` when progress requires external input or an unavailable dependency.

        Replace the final status line before the session ends, commit the final plan update, and do not add content after it.

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
        3. Make small conventional commits as work progresses.
        4. Maintain `\(task.planRelativePath)`. If no plan exists, first create it with the task title, original prompt, a `## Checklist` of small verifiable `- [ ]` steps, a `## Work Log`, and a final `STATUS: CONTINUE` line, then commit it.
        5. Work through checklist items in order. Verify existing `- [x]` items, continue at the first `- [ ]` item, tick each completed item to `- [x]`, append a dated Work Log entry, and commit the related work and plan update.
        6. Before the session ends, make the plan document's final line `STATUS: COMPLETE` only when all items are ticked and verified, `STATUS: CONTINUE` when work remains, or `STATUS: BLOCKED: <reason>` when external input is required. Commit that update and add nothing after the status line.\(evergreenClause(task))
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
