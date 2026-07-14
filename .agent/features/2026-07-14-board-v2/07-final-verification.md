# 07 — Final verification: audit, test, live E2E, docs

- Feature branch: `feat/board-v2-verification` (fixes only; docs may land on main)
- Requirement mapping: Board v2 Wave 7 (user-mandated final double-check)
- Priority: P0 (gate for declaring the initiative done)
- Mission: independently audit everything Waves 1–6 shipped, prove it live, and
  sync all documentation.

## Atomic steps

1. **Fresh adversarial audit.** A codex subagent (that did NOT write the code)
   reviews the full `git diff <pre-wave-1>..main` for: regressions against
   learned-rules 9/10/16/22/24/24a/27, decoding compatibility with pre-v2
   tasks.json/settings.json, actor re-entrancy races (lease/scheduling sets),
   prompt contract contradictions, and UI phase-switch exhaustiveness. Findings
   fixed on the verification branch, each with a test.
2. **Full suite + release build** at head; zero failures, zero warnings-as-errors.
3. **Compatibility probe.** Copy the production tasks.json/settings.json into a
   temp support dir, decode through the current binaries (small test or script),
   confirming nothing is dropped or defaulted unexpectedly.
4. **Live E2E.** Deploy the built app (quit → ditto → open). Verify in
   automation.log + UI: engine start reconciles, evergreen task resumes on an
   eligible account, inspector tabs render live log/runs/plan, waiting reasons
   show on paused cards, retry badge renders, run records carry telemetry
   (tokens, servedAliases, SHAs) on the next completed run. Exercise Retry Now,
   Requeue, Duplicate, Archive on a scratch task pointed at a throwaway repo.
5. **Docs sync.** README task-board section rewritten for the new capabilities
   with a fresh masked screenshot; CHANGELOG entries consolidated;
   `.agent/checklist.md` board-v2 section ticked; learned-rules updated with
   anything discovered; DATABASE-EDR-RLS not applicable (no DB).
6. **Quota + resource check.** Confirm resource telemetry CSV shows no CPU/RSS
   regression from the inspector's log polling (idle board must stay near-zero).

## Definition of Done

All fixes merged via PR, deployed build running the evergreen task, docs synced,
checklist ticked, goal condition satisfied.
