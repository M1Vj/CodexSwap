# 06 — Board power: changes review, attribution, lifecycle

- Feature branch: `feat/board-power`
- Requirement mapping: Board v2 Wave 6 (UX audit items U5, U6, U8, U9, U10, U11, U12, U14)
- Priority: P2
- Mission: review what a run actually changed, attribute quota burn, and round
  out daily-flow ergonomics.

## Atomic steps

1. **Git capture per run.** At run start, record `baseSHA` (repo HEAD) and at
   exit `headSHA` + actual branch on `TaskRunRecord` (tolerant decoding; use a
   small `GitProbe` helper shelling `git -C <repo> rev-parse` — read-only,
   never mutates). Inspector gains a **Changes** tab: commit list
   `git log --oneline base..head`, `--shortstat` totals, and a warning when the
   actual branch differs from `task.branch`. Lazy load, cap output.
2. **Quota attribution.** Runs display `servedAliases` + token totals
   (Waves 2–3 data) in the Runs timeline rows and the run detail header.
   Card chip shows the last run's account alias.
3. **Positional reordering.** Drops compute a real target index from the drop
   location (card-level drop zones with insertion indicator); context menu gets
   Move to Top/Up/Down/Bottom. Queue cards show `#N` position badges.
4. **Lane policy.** Drops into In Progress trigger runTaskNow (with its typed
   result feedback) instead of silently parking; drops into Done from
   non-completed phases are rejected with a shake/beep; In Progress header
   counts only running/planning as WIP (`Active 1/2`), listing
   failed/retryWaiting under a "Needs attention" divider.
5. **Menu-bar cockpit + notifications.** Status menu: running tasks with
   progress, waiting count with next-reset countdown, failed count. Notification
   categories with actions: failure → Open Log / Retry; quota pause → Open
   Board; completion → Open Board. Put taskID in userInfo; clicking focuses the
   board with that task selected.
6. **Archive + duplicate.** `archivedAt: Date?` on AutomationTask (tolerant);
   archived tasks hidden from the board; Done column menu gets Archive All Done;
   card context menu gets Archive (Done/failed only), Duplicate (new UUID,
   "Copy" title suffix, cleared runs/progress/errors), and an Archived sheet
   (list, Restore, Delete Permanently).
7. **Tests** for pure logic: reorder index math, lane policy table, archive
   filtering, duplicate reset, GitProbe parsing (against a fixture repo created
   in the test's temp dir).

## Constraints

GitProbe is read-only (`rev-parse`, `log`, `diff --shortstat` only — never
checkout/reset). Swift 6; tolerant decoding; `swift test` green;
`swift build -c release` clean.
