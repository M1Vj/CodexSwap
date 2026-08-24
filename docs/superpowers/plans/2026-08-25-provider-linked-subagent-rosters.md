# Provider-linked Subagent Rosters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve separate OpenAI and Alpha native subagent rosters, select the matching roster for each Task Board parent, and expose the matching profile safely in Advanced settings.

**Architecture:** Replace the single saved policy value with a backward-compatible `SubagentPolicyProfiles` container under the same settings JSON key. Task Board resolves the parent provider before selecting a profile; interactive settings select the profile from the configured parent and keep Apply explicit because global role files cannot switch inside a running Codex session.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Foundation Codable, XCTest, Swift Package Manager.

---

### Task 1: Add provider-linked policy storage and legacy migration

**Files:**
- Modify: `Sources/SwapKit/SubagentModelPolicy.swift`
- Modify: `Sources/SwapKit/Settings.swift`
- Modify: `Tests/SwapKitTests/SubagentModelPolicyTests.swift`

- [ ] **Step 1: Write failing migration and round-trip tests**

Add tests that require:

```swift
let profiles = try JSONDecoder().decode(
    SubagentPolicyProfiles.self,
    from: legacyGPTPolicyData
)
XCTAssertEqual(profiles.openAI.roleAssignments, legacyGPTAssignments)
XCTAssertTrue(profiles.bridged.roleAssignments.allSatisfy {
    $0.modelID == SubagentPolicyValidator.alphaModelID && $0.reasoningEffort == .ultra
})

let selected = profiles.policy(for: .openAI)
XCTAssertEqual(selected, profiles.openAI)
XCTAssertNil(profiles.policy(for: .unknown))
```

Cover a legacy Alpha-only policy, the current mixed-eligibility GPT legacy shape, malformed nested profiles, and new-shape encode/decode.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
rtk swift test --filter SubagentModelPolicyTests
rtk swift test --filter Settings
```

Expected: tests fail because `SubagentPolicyProfiles` and provider selection do not exist.

- [ ] **Step 3: Implement the minimal profile container**

Add a bounded two-family value:

```swift
public struct SubagentPolicyProfiles: Codable, Sendable, Equatable {
    public var openAI: SubagentModelPolicy
    public var bridged: SubagentModelPolicy

    public static let `default` = SubagentPolicyProfiles(
        openAI: .default,
        bridged: .alphaDefault
    )

    public func policy(for family: CodexModelProviderFamily) -> SubagentModelPolicy? {
        switch family {
        case .openAI: return openAI
        case .bridged: return bridged
        case .unknown: return nil
        }
    }
}
```

Give the type a custom decoder that distinguishes `{ openAI, bridged }` from the legacy single-policy keys, splits cross-provider eligibility, preserves custom GPT assignments, and carries the legacy Alpha Ultra choice into an all-Alpha bridged profile. Change `Settings.subagentModelPolicy` to this container while keeping the existing JSON key.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the same two commands. Expected: all selected tests pass with no unexpected warnings.

- [ ] **Step 5: Inspect the diff before the next slice**

Run:

```bash
rtk git diff -- Sources/SwapKit/SubagentModelPolicy.swift Sources/SwapKit/Settings.swift Tests/SwapKitTests
```

Confirm no account, credential, routing, or Alpha MCP behavior changed.

### Task 2: Select profiles during Task Board materialization

**Files:**
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Sources/SwapKit/CodexTaskPolicyMaterializer.swift`
- Modify: `Tests/SwapKitTests/TaskAutomationTests.swift`

- [ ] **Step 1: Write failing Task Board selection tests**

Add one fixture with both profiles and assert:

```swift
try materializer.materialize(
    policyProfiles: profiles,
    targetCodexHome: alphaTarget,
    proxyURL: proxyURL,
    allowedAliases: aliases,
    runID: UUID(),
    parentModelID: "x-preview-f-free",
    bridgedModels: bridgedModels
)
XCTAssertTrue(try roleText(alphaTarget, "worker").contains("model = \"x-preview-f-free\""))

try materializer.materialize(
    policyProfiles: profiles,
    targetCodexHome: gptTarget,
    proxyURL: proxyURL,
    allowedAliases: aliases,
    runID: UUID(),
    parentModelID: "gpt-5.6-sol",
    bridgedModels: bridgedModels
)
XCTAssertTrue(try roleText(gptTarget, "worker").contains("model = \"gpt-5.6-luna\""))
```

Add unknown, missing, duplicate-parent, invalid-selected-profile, and sequential Alpha-to-GPT cases. Assert the target remains absent or byte-identical on every failure.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
rtk swift test --filter TaskAutomationTests
```

Expected: new calls or assertions fail because the materializer still accepts one policy.

- [ ] **Step 3: Implement selection after catalog resolution**

Change the materializer input to `policyProfiles`. Rewrite the catalog with `policyProfiles.bridged.alphaUltraEnabled`, resolve `parentModelID`, select the profile through `policy(for:)`, then validate and stage only the selected profile. Update `AppEngine` to pass the profiles unchanged.

Keep these checks before any transaction:

```swift
guard let selectedPolicy = policyProfiles.policy(for: parentFamily) else {
    throw CodexTaskPolicyMaterializerError.validationFailed([unknownParentIssue])
}
let validation = SubagentPolicyValidator.validateForApply(
    policy: selectedPolicy,
    catalog: resolvedCatalog,
    installedRoleIDs: installedRoleIDs,
    parentProviderFamily: parentFamily
)
guard validation.canApply else {
    throw CodexTaskPolicyMaterializerError.validationFailed(validation.blockingIssues)
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run `rtk swift test --filter TaskAutomationTests`. Expected: all Task Board policy tests pass.

- [ ] **Step 5: Check the transaction boundary**

Inspect the materializer diff and confirm profile selection occurs before target-directory mutation, rollback manifests remain unchanged, and the source Codex home stays read-only.

### Task 3: Load and persist the configured parent's interactive profile

**Files:**
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`
- Modify: `Sources/CodexSwapApp/SettingsViewModel.swift` only if a provider-profile label cannot stay in presentation state
- Modify: `Sources/SwapKit/SubagentPolicyPresentation.swift`
- Modify: `Sources/CodexSwapApp/SubagentModelsSection.swift`
- Modify: `Tests/SwapKitTests/SubagentPolicyPresentationTests.swift`
- Modify or create a focused app-state test under `Tests/CodexSwapAppTests/`

- [ ] **Step 1: Write failing profile-isolation and copy tests**

Test that refresh with `.bridged` loads `profiles.bridged`, refresh with `.openAI` loads `profiles.openAI`, applying one replaces only that family, restore changes only the visible draft, and UI copy includes the new-session boundary.

Use behavior assertions such as:

```swift
var profiles = fixtureProfiles
profiles.update(alphaDraft, for: .bridged)
XCTAssertEqual(profiles.bridged, alphaDraft)
XCTAssertEqual(profiles.openAI, fixtureProfiles.openAI)
XCTAssertEqual(state.providerProfileLabel, "Editing Alpha parent profile")
XCTAssertTrue(SubagentPolicyPresentationState.interactiveSessionBoundary.contains("new Codex session"))
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
rtk swift test --filter SubagentPolicyPresentationTests
rtk swift test --filter CodexSwapAppTests
```

Expected: tests fail because refresh/apply still read and replace one global policy.

- [ ] **Step 3: Implement family-scoped refresh and Apply**

In `AppDelegate`:

1. Resolve the current parent family.
2. Load only `currentSettings.subagentModelPolicy.policy(for: family)` into the presentation state.
3. Apply the draft to role files through the existing manager.
4. Persist with `profiles.update(draft, for: family)` only after the role transaction succeeds.
5. Re-read roles and reconcile only the same family profile.
6. Fail before role or settings writes when the family is missing or unknown.

Add short UI copy for the profile label, Task Board auto-selection, explicit interactive Apply, and new-session requirement. Preserve existing accessibility identifiers and add one stable identifier for the profile label if the app test needs it.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the same focused commands. Expected: all selected tests pass.

- [ ] **Step 5: Inspect state and UI diffs**

Verify loading/error/applying phases remain coherent, no background file watcher was added, and cross-provider native assignments remain disabled.

### Task 4: Update the design contract and run integrated verification

**Files:**
- Modify only if needed: `docs/superpowers/plans/2026-08-23-subagent-model-policy-design.md`
- Verify: every intended source/test/doc file in the existing release candidate

- [ ] **Step 1: Align existing policy documentation**

Add one concise note to the prior policy design only if it contradicts the approved provider-linked behavior. Do not duplicate the full new spec.

- [ ] **Step 2: Run the policy-focused aggregate**

Run:

```bash
rtk swift test --filter Subagent
rtk swift test --filter TaskAutomationTests
```

Expected: zero failures.

- [ ] **Step 3: Run the full release gate**

Run once on the final source state:

```bash
rtk swift test
rtk proxy bash Scripts/test-release-tools.sh
rtk proxy bash Scripts/build-app.sh
rtk git diff --check
rtk proxy codesign --verify --deep --strict dist/CodexSwap.app
```

Expected: all commands exit 0. Record the test count and candidate hash.

- [ ] **Step 4: Repeat the packaged security/runtime probes**

Run the existing packaged MCP handshake, tool-list, attachment-only confidentiality, cancellation/descendant, registration-identity, proxy-listener, and settings-migration probes. Expected: the helper advertises only `codexswap_alpha_review`, cannot inspect the live workspace, and leaves the running installed app untouched until installation.

- [ ] **Step 5: Request independent frozen-diff reviews**

Provide the exact candidate hash and bounded diff to one correctness/release reviewer and one security reviewer. Both must return PASS or all reproducible findings must be fixed and re-reviewed against the new hash.

### Task 5: Install and close out without disturbing active sessions

**Files:**
- Stage only the files listed by the recovered task ledger and this plan
- Never stage or edit: `ACTIVE_LANES.md`

- [ ] **Step 1: Preserve rollback evidence**

Create or refresh the task-owned rollback bundle using the existing release workflow, record its exact location in the task ledger, and verify it contains the pre-install app/source identity.

- [ ] **Step 2: Replace the installed app safely**

Resolve the current listener PID from `127.0.0.1:58432`, prove it belongs to CodexSwap, terminate only that PID, install the verified bundle, reopen `/Applications/CodexSwap.app` immediately, and poll until the listener returns. Never use `killall` or `pkill`.

- [ ] **Step 3: Verify the installed result**

Verify the running bundle signature, executable hash, listener, saved profile migration, configured MCP command identity, and one new Task Board materialization for each provider family without exposing private task content.

- [ ] **Step 4: Stage and inspect explicit files**

Use explicit paths from `rtk git status --short`. Run the repository secret scan or pre-commit gate, then inspect `rtk git diff --cached --stat` and `rtk git diff --cached` before committing. Confirm `ACTIVE_LANES.md`, task rollback artifacts, and unrelated files are absent.

- [ ] **Step 5: Commit and push**

Create grouped Conventional Commits, with the provider-linked behavior included in the recovered release feature commit. Push `main` without force, verify `origin/main` matches the local commit, leave CodexSwap running, and record exact verification evidence in the task ledger.
