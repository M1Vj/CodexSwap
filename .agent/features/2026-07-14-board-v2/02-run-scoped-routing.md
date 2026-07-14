# 02 — Run-scoped proxy routing

- Feature branch: `feat/run-scoped-routing`
- Requirement mapping: Board v2 Wave 2 (audit item E1)
- Priority: P0
- Mission: quota events and turn stickiness must target the specific run that
  caused them, not every running task.

## Defect

`AppEngine.forwardProxyEvent` `.exhausted` calls `noteQuotaExhausted` on EVERY
running task; with concurrency > 1 one exhausted account pauses unrelated tasks.
`taskTurns` in ProxyServer is keyed by the joined alias list, so two tasks with
identical account lists share turn state. `ProxyEvent` has no run identity, and
the run record never learns which account actually served it.

## Atomic steps

1. `TaskRunner.launchArgs` gains a `runID: UUID` parameter and injects a second
   provider header `X-CodexSwap-Task-Run: <uuid>` alongside the accounts header.
   `TaskRunner.start` passes the new run's record ID (AppEngine already appends
   the open `TaskRunRecord` before launch — thread its ID through, or have
   TaskRunner accept it explicitly). Keep a `runID → taskID` map in TaskRunner.
2. `ProxyRequestMode.task` carries `(allowed: [String], runID: String?)`; parse
   the new header; absent header (old clients) keeps nil and current behavior.
3. Key `ProxyServer.taskTurns` by `runID ?? joinedAliases`.
4. `ProxyEvent` gains `runID: String?`; the task branch populates it on
   exhausted/needsLogin events.
5. `AppEngine.forwardProxyEvent` `.exhausted`: when `event.runID` maps to a
   running task, call `noteQuotaExhausted` on that task only; fall back to the
   broadcast only when runID is nil (old behavior, plus a log line).
6. Record the serving alias: on each task-mode selection the proxy already calls
   `touchLastUsed`; additionally emit/collect the set of aliases that actually
   served the run and persist `servedAliases: [String]` on `TaskRunRecord`
   (tolerant decoding). Simplest wiring: TaskRunner keeps a per-run alias set fed
   by a ProxyEvent kind or a callback from AppEngine on rotated/selected events;
   acceptable alternative: AppEngine records the scheduler-selected alias at
   start and appends aliases seen on run-scoped proxy events.
7. Tests: header round-trip parse; turn keying by run; targeted quota pause
   (two fake running IDs, event with one runID → only that one noted);
   broadcast fallback with nil runID; servedAliases persistence decoding.

## Constraints

Tolerant decoding; Swift 6; loopback-only headers stripped before upstream
(extend `proxyUpstreamHeaders` to remove the new header); never touch
activeAlias in task mode (rule 22). `swift test` green.
