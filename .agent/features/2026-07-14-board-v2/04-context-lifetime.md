# 04 — Context lifetime: handoff, evergreen cycles, verification receipts

- Feature branch: `feat/context-lifetime`
- Requirement mapping: Board v2 Wave 4 (audit items E9, E15, E14)
- Priority: P1
- Mission: stop the PLAN.md from growing into a permanent context tax; give
  evergreen tasks bounded cycles; make expensive full-suite verification
  commit-aware instead of per-session.

## Atomic steps

1. **Handoff section contract.** All prompt builders (first run, continuation,
   replan, export) require PLAN.md to maintain a `## Handoff` section directly
   under the title: current branch HEAD short SHA, up to 5 bullet decisions that
   constrain future work, failed approaches to avoid, and the exact next action.
   Cap ~30 lines; each session REWRITES it (not appends). The Work Log moves to
   `WORKLOG.md` next to PLAN.md — sessions append there instead, and
   continuations are told to read the Handoff + checklist and consult WORKLOG.md
   only when investigating regressions. Continuation/export builders stop
   claiming the Work Log lives in PLAN.md.
2. **Evergreen cycles.** Evergreen clause changes: when every current-cycle item
   is ticked, the session archives the finished cycle by appending it to
   `CYCLES.md` (cycle number, dates, one-paragraph summary, the completed
   checklist), then reseeds PLAN.md with a fresh checklist of 5–10 prioritized
   items and writes `STATUS: CONTINUE`. PLAN.md therefore always contains ONLY
   the active cycle. Remove the "append fresh items so the checklist never runs
   dry" phrasing (it caused unbounded growth). Engine: no change needed —
   cycle-complete detection stays (COMPLETE + evergreen), but the prompt now
   makes in-session reseeding the norm so COMPLETE rarely surfaces.
3. **Verification receipts.** Prompts change from "run the full suite once
   before your final commit" to: record in the Handoff a `Verified: <suite
   command> at <short SHA>` line when the full suite last ran; run the FULL
   suite only when (a) claiming COMPLETE, (b) the Handoff's receipt SHA is not
   an ancestor of the work about to be committed AND the session changed
   behavior-relevant files, or (c) no receipt exists. Otherwise targeted checks
   suffice. Always update the receipt line after a full run.
4. **PlanDocParser**: tolerate the new sections (already ignores unknown lines);
   add `PlanDocParser.handoffExcerpt(_:) -> String?` returning the Handoff
   section text (for the export builder and later UI).
5. **Tests**: prompts contain handoff/WORKLOG/cycle/receipt contract strings and
   no longer contain the removed phrasings; handoffExcerpt extraction; existing
   prompt tests updated.

## Constraints

Prompt-only + parser helper — no scheduler changes. Keep the batching, bulk
commit, unattended, and native-subagent clauses intact. `swift test` green.
