# Subagent Model Policy Design

## Goal

Give people one understandable place in CodexSwap to decide which models may be used by Codex subagents, while keeping the parent model unchanged. Preserve the original role-aware roster—Luna Max for ordinary work and Sol High for adversarial review—and make bridged models such as 0x Alpha eligible without pretending unsupported mixed-provider delegation works.

## Product principles

- Parent and child routing are separate. Applying this policy never edits the global `model` or parent `model_reasoning_effort`.
- Roles are deterministic, not randomly pooled. Each role has one selected eligible model and one effort.
- Eligibility is an explicit safety boundary. A disabled model cannot remain assigned to a role.
- Existing global agent instructions, permissions, comments, and unknown TOML fields are user-owned and must survive every global apply. Isolated Task Board homes use a deliberately smaller safe projection described below.
- Alpha Ultra is a Codex orchestration workflow. The provider still receives `max`; CodexSwap never sends `ultra` as a provider-native Alpha effort.
- Unsupported paths fail clearly. Native Codex V2 cannot currently pass a GPT parent's encrypted task to an Alpha child, so the UI warns and blocks that mixed-provider assignment instead of silently creating an empty-task agent.

## User experience

Advanced Settings gains a **Subagent Models** section with three compact states:

1. **Available to subagents** lists the live Codex catalog plus enabled bridged models. Each row has an eligibility toggle and shows supported efforts. Refresh is explicit and also runs on first appearance.
2. **Role assignments** lists the known installed role files. Each row chooses an eligible model and one effort supported by that model. The ordinary roles default to GPT-5.6 Luna / max; `sol_adversarial` defaults to GPT-5.6 Sol / high.
3. **Apply policy** validates the whole draft, writes all affected role files as one logical transaction, and reports either success or an actionable error. Unsaved edits remain visible after an error so the person can correct them.

Loading, empty, stale, and failure states use plain language. If Codex is missing or catalog JSON changes, the current saved policy remains visible and no configuration is overwritten. The section explains that new Codex sessions are required before role changes are guaranteed to take effect.

Alpha gets an **Offer Ultra workflow** capability when its bridged catalog entry is enabled. This adds `ultra` to Codex-facing catalog metadata while retaining `max` as the provider effort. It does not automatically change the current parent or assign Alpha to every role.

## Data model

`SubagentModelPolicy` is stored inside CodexSwap's existing settings JSON:

- `eligibleModelIDs: [String]`
- `roleAssignments: [SubagentRoleAssignment]`
- `alphaUltraEnabled: Bool`

Each assignment contains `roleID`, `modelID`, and `reasoningEffort`. Decoding is backward compatible: old settings receive the original Luna/Sol roster. Unknown role assignments are retained in settings but are not written until a matching role file exists.

`CodexModelDescriptor` is runtime data, not persisted authority. It contains model ID, display name, supported efforts, provider family, and whether Ultra is a synthetic Codex workflow. The catalog service executes the resolved Codex binary with `debug models`, applies a timeout and output cap, parses JSON defensively, and merges enabled bridged models without hard-coding the future GPT list. Configured bridge settings are the routing authority: a disabled configured bridge suppresses any stale matching raw-catalog row, while an unconfigured bridge-looking model remains unknown rather than silently becoming assignable.

## Configuration application

`CodexSubagentPolicyManager` owns role-file and catalog-overlay changes. It receives explicit URLs in tests and defaults to `~/.codex` in the app.

Before writing, it:

1. validates that at least one model is eligible;
2. validates every installed managed role has exactly one eligible assignment;
3. validates the selected effort is supported;
4. rejects provider-incompatible GPT-parent-to-Alpha-child configurations when the current parent family is known to be GPT;
5. reads and stages every original file in memory.

It changes only top-level `model` and `model_reasoning_effort` in global role files. Existing provider bindings, instructions, permissions, comments, tables, and unrelated bytes remain untouched. Writes use same-directory temporary files and atomic replacement. If any write or post-write validation fails, every already-written file is restored from the in-memory originals. The settings policy is persisted only after the configuration transaction succeeds.

The catalog overlay updater changes only managed bridge metadata and retains every unrelated model and unknown JSON key. When an enabled future bridge is absent from the raw Codex catalog, it clones a validated full model entry as a schema template and normalizes the bridge identity, visibility, and advertised efforts; it fails closed when no valid template exists. Disabling Alpha Ultra removes only the synthetic `ultra` value that CodexSwap added.

Task Board parents run with a deliberately isolated `CODEX_HOME`, so they cannot inherit global role files. Immediately before a Task Board launch, the materializer projects only safe role identity, description, nickname, and instruction fields plus the selected model and effort into that task's private home. It intentionally drops unknown tables, permission profiles, provider blocks, endpoints, paths, and environment material; forces every staged child to `sandbox_mode = "read-only"` and `approval_policy = "never"`; and rewrites the provider binding to the run-scoped `codexswap-task` provider so child traffic preserves the task's account allowlist and run ID. The staged config explicitly enables multi-agent operation. It never copies authentication, sessions, history, plugins, or unrelated global configuration, and it rejects symlinks or paths that escape the expected task, `agents`, and `model-catalogs` directories.

Task Board keeps the real `HOME` so sandboxed Git and user tools can read established identity/configuration, while `CODEX_HOME` remains isolated and no private Codex state is copied. This is a read boundary, not a claim that the whole home directory is hidden. Materialization is serialized with an OS-level lock and an owned journal. Every journal names a random transaction ID that must match owner markers in both staging and backup artifacts; recovery rejects symlinks and non-regular managed entries before any move or deletion. If the app exits between directory swaps, the next launch validates those exact artifacts, restores the prior managed paths, and retries; malformed, mismatched, or path-escaping artifacts fail closed. A hostile process running as the same macOS user can forge a fully self-consistent regular-file transaction just as it can directly edit that user's task home; preventing that requires a separate authenticated secret boundary and is explicitly outside this local same-user trust model. Task-home session pruning, telemetry ingestion, log-tail reads, and run-archive writes use the same no-symlink containment boundary.

## Compatibility rules

| Parent | Child role | Result |
|---|---|---|
| GPT | GPT | Allowed |
| Alpha | Alpha | Allowed |
| Alpha | GPT | Blocked until a live Codex version proves readable cross-provider task transport |
| GPT | Alpha | Blocked while upstream encrypted cross-provider V2 transport remains unsupported |
| Unknown | Mixed provider | Warned and blocked by default; an unknown is not treated as proof of safety |

The manager's compatibility rule is versioned and centralized so a later Codex release can safely relax it after a sentinel probe.

## Failure and recovery cases

- Missing Codex binary: show the saved policy read-only; do not write.
- Catalog timeout, malformed JSON, or no models: retain the last successful in-memory view for the screen session and show Refresh.
- Model removed after an upgrade: keep the assignment visibly marked unavailable and require reassignment before Apply.
- Effort removed after an upgrade: mark it invalid; never silently downgrade.
- Disabling an assigned model: prevent Apply and identify every affected role.
- Missing role file: retain the assignment but show “not installed”; do not create an instruction-less role implicitly.
- Duplicate or malformed managed keys: reject the file and name it; do not guess which occurrence is authoritative.
- Partial write, disk-full, or permission error: roll back every touched file and leave saved policy unchanged.
- App or Codex restart during a global apply: atomic per-file writes prevent torn TOML; the next load reconciles settings against actual files and reports drift.
- Concurrent external edit: compare the file bytes immediately before replacement and abort if they differ from the staged original.
- Unsupported mixed provider: explain why the child would receive an empty task and suggest a homogeneous roster.
- Task-home staging failure or interrupted swap: do not start the Task Board parent; recover only journal-owned managed paths, or report the exact safe staging error rather than running with a misleading fallback roster.

## Acceptance scenarios

```gherkin
Feature: Role-bound subagent model policy

  Rule: Parent routing remains independent
    Scenario: Apply the default roster
      Given the parent is using GPT-5.6 Sol
      When the default subagent policy is applied
      Then ordinary roles use GPT-5.6 Luna at max
      And the adversarial role uses GPT-5.6 Sol at high
      And the parent model and effort are unchanged

  Rule: Only eligible and supported assignments can be applied
    Scenario: Disable a model that is still assigned
      Given Luna is assigned to an ordinary role
      When Luna is disabled for subagents
      Then Apply is blocked
      And the affected role is identified

    Scenario: A catalog effort disappears
      Given a role was saved with an effort no longer advertised by its model
      When the catalog refreshes
      Then the assignment is shown as invalid
      And no silent effort downgrade occurs

  Rule: Configuration writes are recoverable
    Scenario: One role write fails
      Given several valid role updates are staged
      When a later role file cannot be replaced
      Then every earlier role file is restored byte-for-byte
      And the saved policy remains unchanged

    Scenario: A role contains custom instructions
      Given a role file contains comments and custom fields
      When its model and effort are changed
      Then all unrelated content remains byte-for-byte unchanged

  Rule: Alpha uses Codex orchestration safely
    Scenario: Enable Alpha Ultra
      Given Alpha advertises provider efforts through max
      When Offer Ultra workflow is enabled
      Then Codex can select ultra for Alpha
      And Alpha receives max as its provider effort

    Scenario: Assign Alpha below a GPT parent
      Given native cross-provider V2 task encryption is incompatible
      When Alpha is assigned to a child role under a GPT parent
      Then Apply is blocked with a compatibility explanation
      And the existing working role configuration remains unchanged

  Rule: Task Board runs honor the same policy without inheriting private state
    Scenario: Start a Task Board parent
      Given a valid subagent policy has been applied
      When the isolated task home is prepared
      Then only selected role files and managed catalog metadata are staged
      And child roles use the run-scoped task provider
      And multi-agent mode is enabled in the isolated home
      And every child role is read-only and non-interactive
      And no authentication, session, history, or plugin state is copied
```

## Verification

- Unit tests cover settings migration, catalog decoding/merging, validation, text-preserving TOML updates, concurrent-edit detection, rollback, Ultra metadata, compatibility errors, and isolated Task Board materialization.
- The full Swift test suite and release build run once after the coherent change.
- The installed app is replaced only after exact process ownership is re-established.
- Live probes verify GPT text/tools, Alpha text/tools, GPT-to-GPT delegation, and Alpha-to-Alpha delegation. Mixed-provider probes are expected to fail closed with a useful explanation.
