# 03 — Structured run telemetry, budgets, model fallback

- Feature branch: `feat/run-telemetry`
- Requirement mapping: Board v2 Wave 3 (audit items E4, E7, E10, E16, E18)
- Priority: P1
- Mission: parse codex's structured output so every run records tokens, session
  ID, and a human summary; use that data for admission headroom, model fallback,
  and bounded run history.

## Atomic steps

1. **Structured output.** Add `--json` and `--output-last-message <taskDir>/run-N.final.md`
   to `TaskRunner.launchArgs`. Codex then emits JSONL events on stdout. Keep the
   combined run-N.log capture unchanged (it now contains JSONL — the UI wave will
   render the final message instead). Write a tolerant `CodexEventDecoder`
   (new file) that scans the log after exit: extracts session/thread ID, token
   usage totals (input/cached/output/reasoning when present), the final agent
   message, and structured error codes. Unknown lines are ignored. IMPORTANT:
   probe the actual event shapes emitted by codex-cli 0.144 (`codex exec --json`
   on a trivial prompt in a scratch dir) before writing the decoder; do not
   guess field names.
2. **RunTelemetry persistence.** `TaskRunRecord` gains `sessionID: String?`,
   `inputTokens: Int?`, `cachedTokens: Int?`, `outputTokens: Int?`,
   `summary: String?` (first 2000 chars of final message), `servedAliases`
   already exists from Wave 2. All tolerant decoding. `handleTaskExit` fills
   them via the decoder + the final-message file (then deletes run-N.final.md;
   prune old ones in pruneArtifacts).
3. **Admission headroom.** New setting `automationMinHeadroomPercent: Int`
   (default 5, clamp 0...50). The scheduler's account pick for STARTING a run
   requires every reported window to have `100 - usedPercent >= minHeadroom`;
   the over-threshold fallback from rotation parity no longer applies to run
   starts (mid-run proxy failover keeps the fallback). Log a precise per-alias
   reason (`headroom<5%`) when this blocks a start.
4. **Model fallback.** `AutomationTask` gains `fallbackModels: [String]`
   (tolerant, default []). When a run fails with kind `.modelRejected` and a
   fallback exists that hasn't been tried this task, immediately reschedule with
   the next model (mutate `task.model`, record
   `lastError = "model X rejected — falling back to Y"`, outcome
   `model-fallback`) instead of terminal failure. Editor UI: token field
   accepting comma-separated fallbacks under the model picker.
5. **Bounded run history.** Cap `task.runs` at the newest 25 records when
   closing a run; append evicted records as JSONL to `<taskDir>/runs-archive.jsonl`.
   Maintain `totalRuns: Int` on the task (tolerant decoding, default
   `runs.count`) so the run numbering (`run-N.log`) stays monotonic — derive the
   next run number from `totalRuns`, not `runs.count`.
6. **Tests**: decoder against captured fixture lines (commit a small fixture
   from the probe in step 1); telemetry persistence round-trip; headroom
   admission table (blocks under min, allows at min, ignores accounts with no
   usage); model fallback transition (rejected → next model → exhausted
   fallbacks → failed); run-history cap + archive append + monotonic numbering.

## Constraints

Tolerant decoding everywhere; Swift 6; never log token values as secrets (they
are not secrets — fine to log); keep 0600/0700 permissions on new files.
`swift test` green; `swift build -c release` clean.
