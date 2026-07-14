# 05 — Board cockpit: inspector, reasons, recovery actions

- Feature branch: `feat/board-cockpit`
- Requirement mapping: Board v2 Wave 5 (UX audit items U1, U2, U3, U4, U7, U13)
- Priority: P1
- Mission: turn the board into an operational console — see what a run is doing
  live, why a task waits, and recover without hunting through menus.

## Atomic steps

1. **Task inspector.** Single-click selects a card; a trailing inspector panel
   (HSplitView) opens with tabs:
   - **Log**: live tail of the selected run's log (1s timer poll of the file,
     last ~500 lines, monospaced, auto-scroll with pause-on-scroll-up, Copy and
     Open Externally buttons). When telemetry (Wave 3) recorded a summary,
     show it above the raw log.
   - **Runs**: timeline rows `Run N · start · duration · outcome · exit · d/t`,
     newest first, outcome icon+color; clicking selects that run's log; rows
     whose log file was pruned show "log expired" and disable the Log tab.
   - **Plan**: parsed PLAN.md checklist grouped Done/Remaining with the Handoff
     excerpt on top (PlanDocParser.handoffExcerpt).
   AppEngine additions: `runLogURL(taskID:runNumber:)`, `planDocument(taskID:)`
   accessors; keep file reads off the main thread.
2. **Waiting reasons.** Expose the per-alias eligibility reasons the tick
   already computes: store the latest `schedulingReasons: [String: String]`
   (taskID → reason line) on the engine, surface through the snapshot, render on
   pausedQuota/retryWaiting cards ("m3uio: cooldown until Jul 21 02:40",
   "retrying in 3m", "repo busy") with a countdown via TimelineView when a date
   is known (next account resetAt / nextRetryAt).
3. **Recovery actions.** Failed/stopped cards get visible buttons: Retry Now
   (runTaskNow) and Requeue (move to queued + phase idle). runTaskNow returns a
   typed result (`started`/`queued`/`blocked(reason)`) shown as a transient
   inline label instead of silence.
4. **Filters.** Header gains a search field (title/prompt/repo match) and a
   Needs Attention toggle (failed/blocked/retryWaiting only). Counts update
   per column ("3/18").
5. **Menu bar**: status item menu adds one line per running task (title +
   plan progress) and a "next reset in Xm" line when everything waits on quota.
6. **Tests** for any new pure logic (reason formatting, filter predicate,
   timeline row model). UI smoke: `swift build -c release`.

## Constraints

SwiftUI, macOS 14; no blocking file IO on the main actor; keep board usable at
50+ tasks (lazy stacks). Match existing view styling. `swift test` green.
