# Task Board v2 — drastic improvement initiative

Research-driven overhaul of the task automation system. Inputs: live production
monitoring (runs 1–21), codex engine audit (19 items), codex UX audit (15 items),
and external research (vibe-kanban, Codex cloud, Devin playbooks, long-horizon
agent reliability literature).

## Verified correctness defects driving Wave 1

1. `AppEngine.forwardProxyEvent` `.exhausted` calls `noteQuotaExhausted` on EVERY
   running task — one exhausted account pauses unrelated concurrent tasks.
2. `handleTaskExit` accepts `STATUS: COMPLETE` → Done regardless of exit code or
   `done == total`; a stale COMPLETE line mid-document also counts because the
   parser keeps the last STATUS match anywhere in the file.
3. Any launch exception or unclassified nonzero exit → terminal `.failed`, a dead
   end the scheduler never retries; transient network errors and permanent
   misconfigurations get identical treatment.
4. Stagnation guard (3 identical continue-runs) goes straight to `.failed` with
   no attempt to repair the plan.
5. Two concurrent tasks sharing one `repoPath` race checkouts/commits in the same
   working tree.

## Waves (one branch + PR each, codex subagents implement, orchestrator reviews)

| Wave | Branch | Scope | Guide |
| --- | --- | --- | --- |
| 1 | `feat/engine-correctness` | Outcome reducer extraction, completion gate, typed failures + retry backoff, auto-replan, repo lease | `01-engine-correctness.md` |
| 2 | `feat/run-scoped-routing` | Run-scoped proxy headers/events, targeted quota pause, per-run turn stickiness | `02-run-scoped-routing.md` (to write) |
| 3 | `feat/run-telemetry` | `--json` + `--output-last-message`, token/session telemetry, run summaries, headroom admission, model fallback, bounded run metadata | `03-telemetry.md` (to write) |
| 4 | `feat/context-lifetime` | Bounded handoff section vs append-only history, evergreen cycles, commit-aware verification receipts | `04-context-lifetime.md` (to write) |
| 5 | `feat/board-cockpit` | Task inspector (live log tail, run timeline, plan tab), pause reasons + countdown, retry/requeue buttons, filters | `05-board-cockpit.md` (to write) |
| 6 | `feat/board-power` | Changes/commits tab, quota attribution UI, menu-bar cockpit, actionable notifications, archive, reorder, duplicate/templates | `06-board-power.md` (to write) |

Full audit texts: engine + UX audits stored in session scratchpad; key findings
reproduced in each wave guide. External references: vibe-kanban README, Codex
best-practices guide (Goal/Context/Constraints/Done-when prompt structure,
tests as external truth), Zylos long-horizon reliability research (checkpoint
summarization, plans-are-disposable/goal-persists).
