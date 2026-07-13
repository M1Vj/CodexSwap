# 01 — Task Board Automation (Kanban + quota-driven codex exec runs)

- **Feature branch:** `feat/task-board-automation`
- **Requirement mapping:** UR-TaskBoard (user request 2026-07-13)
- **Priority:** High
- **Assigned to:** Claude (orchestrator) + codex subagents
- **Mission:** A kanban board window (To Do / In Queue / In Progress / Done) whose queued tasks run
  automatically as non-interactive `codex exec` sessions the moment quota returns on any of the
  user-selected automation accounts. Plan-first protocol so unfinished tasks resume on the next
  quota window, and every task exports as a portable handoff prompt.

## Full Context

CodexSwap already owns the routing layer: a loopback SwiftNIO proxy injects per-account auth,
rotates on 429, refreshes on 401, and tracks usage windows (5h / weekly) per account. Warm-up
proves the "drive codex CLI headless through the proxy" pattern: `CodexLauncher.warmupArgs`
defines an ephemeral provider whose `http_headers` carry `X-CodexSwap-Warmup-Account: <alias>`,
`env_key="CODEXSWAP_WARMUP_TOKEN"` satisfies codex's auth requirement with a dummy token, and the
proxy overwrites Authorization with the real account token. This feature generalizes that into a
**task mode**.

## Design

### 1. Proxy task mode (ProxyServer.swift, AccountStore.swift)

- New header `X-CodexSwap-Task-Accounts` (constant on `ProxyRequestMode`), value =
  comma-separated account aliases. Parsed into `case task(allowed: [String])` (trim whitespace,
  drop empties; empty list ⇒ treat as `.normal`… no: empty/blank header ⇒ `.normal`).
- `proxyRequestMode` gate stays the same (loopback + POST + path suffix `/responses`); warmup
  header wins if both present.
- **Selection** (`selectProxyAccount`): for `.task(allowed)`, hydrate each allowed alias from its
  managed home (like warmup does) and pick the best eligible: priority desc, then
  least-recently-used, then alias — i.e. the same ordering as `AccountStore.eligibleSorted`.
  Add `AccountStore.bestEligible(among aliases: [String], now: Date) -> Account?` (hydration is
  done by the caller in ProxyServer via `hydrateFromManagedHome`; the store method just filters
  `data.accounts` to the alias set, applies `isEligible`, sorts like `eligibleSorted`, returns
  first). Task selection must NOT call `activate()` — task traffic must never change
  `activeAlias` (the user's interactive session keeps its account). Update `lastUsedAt` for the
  chosen alias via a new `touchLastUsed(_ alias: String, now: Date)` store method so LRU spreads
  task load.
- **429 usage-limit in task mode:** `store.markLimited(alias, …)` (NOT `rotateFrom` — again, do
  not disturb activeAlias), then re-select among allowed; if another allowed account is eligible,
  continue the retry loop with it; if none, emit `ProxyEvent(kind: .exhausted, from: alias,
  limit:, resetAt:)` and forward the buffered 429 upstream response (so codex exits with its
  normal usage-limit error).
- **401/needs-login in task mode:** same refresh path as normal; on `sessionInvalidated`, call
  `store.markNeedsLoginOnly(alias)` + emit `.needsLogin`, then re-select among allowed and
  continue, or forward the 401 if none left.
- Round-robin turn advance (`advanceRoundRobin`) must be skipped for task mode (guard already
  checks `!mode.isWarmup`; extend to only run for `.normal`).

### 2. Settings (Settings.swift)

New fields (all with tolerant-decoder defaults, same pattern as existing):

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `automationEnabled` | Bool | false | Master switch for the scheduler |
| `automationAccounts` | [String] | [] | Aliases the automation may use (board checklist) |
| `automationMaxConcurrent` | Int | 1 | Max simultaneous running tasks (clamp 1...4 on decode) |
| `automationConsumeBankedWindow` | Bool | false | When false, only run on accounts whose 5h window is already started (usedPercent > 0); when true, a task may start (consume) a fresh/banked window |
| `automationDefaultModel` | String | "gpt-5.6-sol" | Default model for new tasks |
| `notifyOnTaskEvents` | Bool | true | Notifications for task start/finish/pause/fail |

### 3. Task model + store (new files: AutomationTask.swift, TaskStore.swift)

```swift
public enum TaskColumn: String, Codable, Sendable, CaseIterable { case todo, queued, inProgress, done }
public enum TaskPhase: String, Codable, Sendable {
    case idle          // never run (todo/queued)
    case planning      // first run in flight (writes the plan doc)
    case running       // continuation/work run in flight
    case pausedQuota   // stopped because allowed accounts were exhausted; scheduler re-queues it
    case failed        // last run failed for a non-quota reason
    case stopped       // user pressed Stop
    case completed     // plan doc reported STATUS: COMPLETE
}
public struct TaskRunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID; public var startedAt: Date; public var finishedAt: Date?
    public var exitCode: Int32?; public var outcome: String   // "completed"|"continue"|"paused-quota"|"failed"|"stopped"
    public var logFileName: String                            // "run-3.log" inside the task dir
}
public struct AutomationTask: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var prompt: String            // the user's task description / prompt
    public var repoPath: String          // absolute path to the working repo
    public var branch: String            // git branch the task must work on (created if missing)
    public var model: String             // e.g. "gpt-5.6-sol", "gpt-5.6-codex-sol"
    public var reasoningEffort: String   // "low"|"medium"|"high" (default "high")
    public var allowNetwork: Bool        // sandbox_workspace_write.network_access (default false)
    public var column: TaskColumn
    public var phase: TaskPhase
    public var orderIndex: Int           // ordering inside a column (queue order)
    public var createdAt: Date
    public var updatedAt: Date
    public var runs: [TaskRunRecord]
    public var lastError: String?        // bounded excerpt for the card
    public var planProgress: PlanProgress? // parsed after each run; nil before first plan
}
public struct PlanProgress: Codable, Sendable, Equatable {
    public var done: Int; public var total: Int; public var status: String? // COMPLETE|CONTINUE|BLOCKED
}
```

- Tolerant decoding for `AutomationTask` (decodeIfPresent + defaults) so new fields never
  invalidate `tasks.json`.
- `planRelativePath` computed: `.codexswap/tasks/<slug>/PLAN.md` where slug =
  lowercased title, non-alphanumerics → "-", collapsed, trimmed, max 40 chars, suffixed with the
  first 8 chars of the UUID for uniqueness. Also `taskDirURL(supportDir:)` for CodexSwap-side
  artifacts: `<support>/tasks/<uuid>/` (codex home + logs live here).
- `TaskStore` actor, persisted at `AppPaths.tasksFile()` (`tasks.json`, add via
  `extension AppPaths` in TaskStore.swift, 0700 dir / 0600 file, atomic write — copy the
  `WarmupLedgerStore.persist` pattern). API: `all()`, `task(id:)`, `add`, `update(_ task:)`,
  `remove(id:)`, `move(id:to:index:)` (reassigns orderIndex compactly for source+target columns),
  `tasks(in column:)` sorted by orderIndex.
- `PlanDocParser` (in AutomationTask.swift): given plan-doc text, count `- [ ]` / `- [x]`
  (case-insensitive x, allow leading whitespace/nesting) and find the last line matching
  `STATUS: <WORD>` (allow `**STATUS:** COMPLETE` bold form too) → `PlanProgress`.

### 4. Prompt protocol + export (new file: TaskPrompt.swift)

`public enum TaskPrompt` with:

- `firstRun(task:) -> String` — instructs codex to:
  1. Work only inside the repo (already cwd). Ensure git branch `task.branch` exists — create from
     the current HEAD if missing — and check it out. Never touch other branches, never push,
     never run destructive commands (`rm -rf` outside repo, `git reset --hard`, force-push are
     all forbidden).
  2. FIRST write the plan doc at `<planRelativePath>`: task title, original prompt, a section
     `## Checklist` of small verifiable steps (`- [ ]`), `## Work Log`, and a final line
     `STATUS: CONTINUE`. Commit it to the branch.
  3. Then execute checklist items in order; after each item tick it `- [x]`, append a dated Work
     Log line, and make a small conventional commit.
  4. Before the session ends update STATUS to `COMPLETE` (all boxes ticked + verified),
     `CONTINUE` (quota/time ran out mid-way), or `BLOCKED: <reason>`.
  5. The original task prompt embedded verbatim in a fenced block.
- `continuation(task:) -> String` — read `<planRelativePath>` on branch `task.branch`, verify
  ticked items still hold, continue from the first unchecked item, same commit/log/STATUS rules.
- `export(task:planDoc:) -> String` — a self-contained handoff prompt for ANY other AI harness:
  title, repo path, branch, model hint, the original prompt verbatim, the current plan doc
  contents (or "no plan yet"), and the same execution rules. Plain markdown, no CodexSwap-specific
  references beyond the plan-doc path.

Keep the prompts compact but explicit; they are the contract the runner + parser rely on
(`STATUS:` line, `- [ ]` checklist).

### 5. TaskRunner (new file: TaskRunner.swift)

Actor. Mirrors `ProcessWarmupRunner` mechanics (termination-handler + continuation, never
`waitUntilExit`; Swift 6 strict concurrency — no shared non-Sendable statics).

- `launchArgs(task:proxyURL:allowedAliases:)` (static, pure, testable):
  `["exec", "--skip-git-repo-check" NO — omit; repo required]`
  ```
  exec
  -s workspace-write
  -c approval_policy="never"
  -m <task.model>
  -c model_reasoning_effort="<task.reasoningEffort>"
  -c model_providers.codexswap-task={ name="CodexSwap Task", base_url="<proxy>/backend-api/codex", wire_api="responses", env_key="CODEXSWAP_TASK_TOKEN", http_headers={ "X-CodexSwap-Task-Accounts"="<a,b,c>" } }
  -c model_provider="codexswap-task"
  [-c sandbox_workspace_write.network_access=true]   // only when task.allowNetwork
  <prompt>
  ```
  TOML-escape header values (reuse the escaping approach from `CodexLauncher.warmupArgs`; move
  `tomlEscape` to an internal shared helper if needed — smallest diff wins).
  SECURITY: never pass `--dangerously-bypass-approvals-and-sandbox` or `-s danger-full-access`.
- `start(task:allowedAliases:proxyURL:onExit:)`:
  - task dir `<support>/tasks/<uuid>/`: `codex-home/` (0700, persistent across runs so codex
    keeps session history), `run-N.log` (0600, N = runs.count + 1, stdout+stderr merged).
  - env: `CODEX_HOME` = task codex-home, `HOME` = real home is NOT given — set `HOME` to the
    codex-home too (matches warmup isolation), `PATH` passthrough, `CODEXSWAP_TASK_TOKEN=
    local-loopback-only`, `NO_COLOR=1`.
  - cwd = task.repoPath (validate it exists and is a directory before launch; fail the run
    otherwise).
  - prompt = `TaskPrompt.firstRun` when `task.runs.isEmpty`, else `.continuation`.
  - No timeout (tasks are long); but keep a hard cap of 6h per run as a safety backstop.
  - `stop(taskID:)` → `process.terminate()`, outcome "stopped".
  - `runningIDs() -> Set<UUID>`; on exit call `onExit(taskID, RunExit)` where
    `RunExit { exitCode, quotaExhausted: Bool, stderrTail: String }`. `quotaExhausted` is set
    when the engine observed a task-mode `.exhausted` proxy event during the run **or** the log
    tail matches "usage limit"/"usage_limit_reached"/"429". (Runner exposes
    `noteQuotaExhausted(taskID:)` for the engine to call.)

### 6. AppEngine integration (AppEngine.swift)

- Engine owns `TaskStore` + `TaskRunner` (init params with defaults, like other services).
- New `AppEvent` cases: `taskStarted(title: String, account: String?)`,
  `taskCompleted(title: String)`, `taskPausedQuota(title: String)`,
  `taskFailed(title: String, reason: String)`.
- `EngineSnapshot` gains `tasks: [AutomationTask]` and `runningTaskIDs: Set<UUID>` (default `[]`
  in init for source compatibility).
- Poller tick calls `await automationTick()` after usage polling. Also call it from
  `expireCooldownsAndNotify` when a window reset fires, and expose `runTaskNow(id:)` for the UI
  (moves task to queued+tick, ignoring `automationEnabled` master switch but still requiring an
  eligible account).
- `automationTick()` logic:
  1. Guard: settings.automationEnabled, proxy running, allowed aliases non-empty.
  2. Resume first: tasks in `.inProgress` with phase `.pausedQuota` count as waiting work and are
     preferred over `.queued` (FIFO by orderIndex within each group).
  3. While runningCount < automationMaxConcurrent and a waiting task exists:
     - Find an account: hydrate allowed aliases, filter `isEligible`; if
       `!automationConsumeBankedWindow`, additionally require its short window (windowSeconds <
       604800) to exist with usedPercent > 0 (banked/unstarted window preserved), unless NO
       account satisfies that and one has `usedPercent == 0` — no, strict: skip run (that is the
       point of the toggle).
     - None eligible → stop (stay queued).
     - Start via runner (allowed aliases = settings.automationAccounts so mid-run rotation works),
       move task to `.inProgress`, phase `.planning` (first run) / `.running`, emit
       `.taskStarted`.
  4. On runner exit callback: reload plan doc from the task repo (branch checkout not needed —
     read the file from the worktree since codex left the branch checked out), parse
     `PlanProgress`, then:
     - outcome stopped → phase `.stopped`, stays `.inProgress`.
     - quotaExhausted → phase `.pausedQuota`, stays `.inProgress`, emit `.taskPausedQuota`.
     - STATUS COMPLETE → column `.done`, phase `.completed`, emit `.taskCompleted`.
     - exit 0 + STATUS CONTINUE → phase `.pausedQuota`-like wait? No: exit 0 without COMPLETE
       means codex ended its session with work left → keep `.inProgress`, phase `.pausedQuota`
       is wrong; use phase `.running`→ re-queue by leaving phase `.pausedQuota`? Decision:
       treat as `.pausedQuota` (it will be resumed on next tick when an account is eligible —
       which may be immediately; that is fine and gives natural multi-session tasks).
     - nonzero exit otherwise → phase `.failed`, `lastError` = stderr tail, emit `.taskFailed`.
  5. Proxy `.exhausted` events while a task runs → `runner.noteQuotaExhausted` for all running
     task IDs (conservative; the 429 killed whichever was talking).

### 7. UI (Sources/CodexSwapApp — new: TaskBoardWindowController.swift, TaskBoardView.swift, TaskBoardViewModel.swift; edits: AppDelegate.swift, AutomationSettingsView.swift)

- Menu: "Task Board…" item (key `t`, ⌘) above Settings; opens `TaskBoardWindowController`
  (pattern-copy SettingsWindowController; min size 1000×620, resizable).
- `TaskBoardViewModel` (@MainActor ObservableObject): published tasks, runningIDs, settings,
  accounts; `TaskBoardActions` struct of closures wired in AppDelegate (add/update/delete/
  move/runNow/stop/export/setAutomationEnabled/setAutomationAccounts/setConsumeBanked/
  setMaxConcurrent). AppDelegate updates it inside `refreshSnapshot()`.
- `TaskBoardView`: header row = automation master Toggle ("Automation"), status dot
  (green = running N task(s), orange = waiting for quota with queued>0, gray = idle/off),
  accounts filter `Menu` with checkmark toggles per account alias (the checklist), max-concurrent
  stepper (1–4), "consume banked window" toggle, Add Task button. Body = HStack of 4
  `TaskColumnView`s with `ScrollView`s.
- Cards: title, repo last path component + branch (secondary), model chip, phase badge with
  color (planning/running = green + ProgressView spinner, pausedQuota = orange "Waiting for
  quota", failed = red, stopped = gray, completed = green check), checklist progress
  ("3/7 steps" when planProgress != nil), context menu + hover buttons: Run Now, Stop,
  Export Prompt (writes `TaskPrompt.export` to NSPasteboard + confirmation message), Edit,
  Delete (confirm). Cards draggable between columns via `.draggable(String)` (UUID string) /
  `.dropDestination(for: String.self)` per column. Dropping into In Queue = enqueue; into
  To Do = park; In Progress/Done are also allowed targets but just reorder state (moving a
  running task out does NOT stop it — Stop is explicit).
- Task editor sheet (add/edit): title, prompt TextEditor, repo folder picker (NSOpenPanel via
  fileImporter), branch text field (default suggestion `codexswap/<slug>`), model Picker
  (gpt-5.6-sol / gpt-5.6-codex-sol / gpt-5.6-terra / gpt-5.5-codex / custom text), reasoning effort Picker,
  allow-network Toggle with warning text. Validate: nonempty title/prompt/repo/branch.
- AppDelegate: handle new AppEvents → notifications (respect `notifyOnTaskEvents`); status-bar
  icon shows a small badge/tint when tasks are running (running task ⇒ `contentTintColor =
  .systemGreen` even if idle proxy — reuse `working` logic OR-ed with `!runningTaskIDs.isEmpty`).
- AutomationSettingsView: add a "Task Automation" section — master toggle, notify toggle,
  consume-banked toggle, max concurrent stepper, and a hint that accounts are picked on the
  board. Keep the board as the primary control surface.

### 8. Tests (Tests/SwapKitTests/SwapKitTests.swift or a new TaskAutomationTests.swift file)

1. Settings: decoding `{}` yields all automation defaults; automationMaxConcurrent clamps.
2. TaskStore: add/update/move/reorder/persist round-trip (temp dir).
3. PlanDocParser: counts boxes, reads STATUS (incl. bold form, BLOCKED reason).
4. TaskPrompt: firstRun contains plan path, branch, STATUS contract; continuation references
   plan path; export contains repo, branch, original prompt, plan doc text.
5. ProxyRequestMode: task header parse (spaces, empties), warmup precedence; selectProxyAccount
   task mode picks eligible-among-allowed, skips ineligible, returns nil when none.
6. TaskRunner.launchArgs: workspace-write present, danger flags absent, model + effort + header
   with aliases present, network flag only when allowNetwork.
7. AutomationTask decode tolerance: minimal JSON decodes with defaults.

## Key Files

New: `Sources/SwapKit/AutomationTask.swift`, `TaskStore.swift`, `TaskPrompt.swift`,
`TaskRunner.swift`; `Sources/CodexSwapApp/TaskBoardWindowController.swift`, `TaskBoardView.swift`,
`TaskBoardViewModel.swift`.
Edited: `Sources/SwapKit/ProxyServer.swift`, `Settings.swift`, `AccountStore.swift`,
`AppEngine.swift`; `Sources/CodexSwapApp/AppDelegate.swift`, `AutomationSettingsView.swift`;
`Tests/SwapKitTests/*`.

## Constraints (from .agent/learned-rules.md — binding)

- Swift 6 strict concurrency: no shared non-Sendable statics; use computed factories
  (`JSONEncoder.codex` pattern). Never block the concurrency executor with `waitUntilExit`.
- `-c` overrides only work AFTER the subcommand token.
- TOML string values quoted; header/base_url values TOML-escaped.
- Tolerant decoders everywhere a persisted format grows.
- No comments in code unless a constraint can't be expressed otherwise; match existing style.
- Task traffic must never mutate `activeAlias` or interfere with interactive rotation.

## Verification Gates

- `swift build` clean, `swift test` all green (existing 60+ tests must stay green).
- Manual: app launches, board opens, task CRUD + drag-drop works, export copies, automation
  toggle + account checklist persist across relaunch.

## Definition of Done

All checklist items in `.agent/checklist.md` addendum ticked; PR text delivered; no push.
