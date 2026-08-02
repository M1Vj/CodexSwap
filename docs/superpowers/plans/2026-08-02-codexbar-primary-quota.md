# CodexBar-Primary Quota Retrieval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh and retrieve every managed account's quota through CodexBar first while preserving CodexSwap's sanitized schema and direct per-account fallback.

**Architecture:** A focused SwapKit adapter launches the fixed CodexBar CLI once, parses and privately matches all-account results, then returns safe snapshots keyed by local account identity. `QuotaReportService` consumes those snapshots independently for usage and reset credits and invokes its current clients only for missing dimensions. `swapd quota --json` remains the sole public entry point and never emits raw CodexBar content.

**Tech Stack:** Swift 6, Foundation `Process`, Swift concurrency, Codable, XCTest, Swift Package Manager, CodexBar CLI.

---

## File map

- Create `Sources/SwapKit/CodexBarQuotaClient.swift`: fixed command invocation, bounded output, Codable parsing, unique private matching, and safe snapshots.
- Create `Tests/SwapKitTests/CodexBarQuotaClientTests.swift`: parser/matcher/runner contract and privacy tests.
- Modify `Sources/SwapKit/QuotaReport.swift`: accept safe prefetched snapshots and fall back per dimension.
- Modify `Tests/SwapKitTests/QuotaReportTests.swift`: CodexBar precedence, stale-local-auth recovery, and partial fallback tests.
- Modify `Sources/swapd/main.swift`: perform the one-shot CodexBar prefetch before report assembly.

### Task 1: Build the safe CodexBar adapter with TDD

**Files:**
- Create: `Tests/SwapKitTests/CodexBarQuotaClientTests.swift`
- Create: `Sources/SwapKit/CodexBarQuotaClient.swift`

- [ ] **Step 1: Write failing parser and matching tests**

Use synthetic raw JSON whose private values contain markers such as
`RAW-EMAIL-MARKER`, `RAW-CREDIT-ID-MARKER`, and `RAW-ERROR-MARKER`. Cover:

```swift
func testFetchMapsUniqueEmailAndLocalPartToSafeSnapshots() async throws
func testFetchParsesSecondaryWindowAndResetCredits() async throws
func testFetchIgnoresAmbiguousAndUnmatchedItems() async throws
func testFetchRejectsMalformedOrOversizedOutputWithSafeError() async throws
func testFetchUsesFixedExecutableAndExactOneShotArguments() async throws
func testSafeSnapshotAndErrorsDoNotRetainRawPrivateMarkers() async throws
```

The runner fake captures the executable and arguments and returns a bounded
`CodexBarCommandResult`. The privacy test reflects/encodes all returned safe
snapshots and safe error descriptions and asserts no marker survives.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
rtk proxy swift test --filter CodexBarQuotaClientTests
```

Expected: compilation fails because `CodexBarQuotaClient`, its runner contract,
and safe snapshot types do not exist.

- [ ] **Step 3: Implement the minimal adapter contracts**

Create these focused interfaces, using equivalent access control where test
injection requires it:

```swift
public struct PrefetchedQuotaSnapshot: Sendable, Equatable {
    public let windows: [UsageWindow]?
    public let resetCredits: ResetCreditSnapshot?
}

public struct CodexBarCommandResult: Sendable {
    public let stdout: Data
    public let exitCode: Int32
}

public enum CodexBarQuotaError: Error, Sendable, Equatable {
    case unavailable
    case timeout
    case commandFailed
    case oversizedOutput
    case malformedResponse
}

public struct CodexBarQuotaClient: Sendable {
    public typealias Runner = @Sendable (URL, [String], Duration, Int) async throws -> CodexBarCommandResult

    public init(runner: @escaping Runner = CodexBarProcessRunner.run)
    public func fetch(accounts: [Account]) async throws -> [String: PrefetchedQuotaSnapshot]
}
```

Use the fixed bundle executable and exactly these arguments:

```swift
[
    "usage", "--provider", "codex", "--all-accounts",
    "--source", "oauth", "--format", "json", "--json-only",
]
```

The dictionary key is `Account.id`; matching compares only exact normalized
alias/email/email-local-part candidate intersections and requires one local
match. Parse primary/secondary/tertiary windows, use
`UsageWindow.label(forWindowSeconds:)`, clamp percentages, parse ISO-8601 with
and without fractional seconds, and retain only available reset-credit expiry
values. Do not make raw Codable DTOs public or conform them to printable error
types.

The production process runner must use `Foundation.Process` directly, cap
stdout/stderr, terminate on timeout or task cancellation, and map every failure
to `CodexBarQuotaError` without returning stderr or raw JSON.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
rtk proxy swift test --filter CodexBarQuotaClientTests
```

Expected: all adapter tests pass and the exact invocation assertion succeeds.

- [ ] **Step 5: Commit the adapter**

```bash
rtk git add Sources/SwapKit/CodexBarQuotaClient.swift Tests/SwapKitTests/CodexBarQuotaClientTests.swift
rtk git commit -m "feat: add private CodexBar quota adapter"
```

### Task 2: Add CodexBar precedence and per-dimension fallback

**Files:**
- Modify: `Tests/SwapKitTests/QuotaReportTests.swift`
- Modify: `Sources/SwapKit/QuotaReport.swift`

- [ ] **Step 1: Write failing orchestration tests**

Add these tests with actor fakes that record direct lookup calls:

```swift
func testPrefetchedSnapshotBypassesDirectUsageAndCredits() async throws
func testPrefetchedAuthorizationOverridesStaleLocalCredentialState() async throws
func testMissingPrefetchedUsageFallsBackWithoutRefetchingCredits() async throws
func testMissingPrefetchedCreditsFallsBackWithoutRefetchingUsage() async throws
func testUnmatchedAccountUsesExistingDirectLookup() async throws
```

The stale-auth test supplies `needsLogin: true` and an empty local access token,
but a complete prefetched snapshot. Assert its routing-derived state is active,
available, or paused rather than `signInRequired`, its data is reported, and no
direct client is called.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
rtk proxy swift test --filter QuotaReportTests
```

Expected: the new tests fail because `fetch` has no prefetched snapshot input.

- [ ] **Step 3: Implement prefetched precedence**

Extend the existing method compatibly:

```swift
public func fetch(
    accounts: [Account],
    activeAlias: String?,
    prefetched: [String: PrefetchedQuotaSnapshot] = [:]
) async throws -> CodexQuotaReport
```

Pass the matching snapshot into each bounded account task. For usage and credits
independently, use a non-nil prefetched dimension with `.ok`; otherwise call the
existing client. Treat any non-nil prefetched dimension as current
authorization when deriving account state. Preserve all current ordering,
sanitization, concurrency limits, cancellation, percent clamping, and safe
error mapping.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
rtk proxy swift test --filter QuotaReportTests
```

Expected: every existing and new report test passes.

- [ ] **Step 5: Commit report integration**

```bash
rtk git add Sources/SwapKit/QuotaReport.swift Tests/SwapKitTests/QuotaReportTests.swift
rtk git commit -m "feat: prefer refreshed CodexBar quota snapshots"
```

### Task 3: Wire the one-shot prefetch into `swapd quota`

**Files:**
- Modify: `Sources/swapd/main.swift`

- [ ] **Step 1: Add the prefetch call without changing the public schema**

Load accounts once, attempt the adapter once, and safely degrade:

```swift
let accounts = await store.all()
let prefetched = (try? await CodexBarQuotaClient().fetch(accounts: accounts)) ?? [:]
let report = try await service.fetch(
    accounts: accounts,
    activeAlias: await store.activeAlias(),
    prefetched: prefetched
)
```

Do not print the adapter error, raw stderr, raw JSON, account identities, or an
extra top-level field. Do not call `serve`, account mutation APIs, token
persistence, routing mutation, warm-up, or credit consumption.

- [ ] **Step 2: Run command and schema checks**

Run:

```bash
rtk proxy swift test --filter 'CodexBarQuotaClientTests|QuotaReportTests'
rtk proxy swift build --product swapd
rtk proxy .build/debug/swapd quota --json
```

Expected: build succeeds; JSON remains schema version 1 and contains only
`accounts`, `fetchedAt`, and `schemaVersion` at top level.

- [ ] **Step 3: Commit the CLI wiring**

```bash
rtk git add Sources/swapd/main.swift
rtk git commit -m "feat: refresh quota through CodexBar first"
```

### Task 4: Verify, install, and live-test the skill path

**Files:** No source changes expected unless verification finds a defect.

- [ ] **Step 1: Run proportional repository verification**

```bash
rtk proxy swift test
rtk proxy swift build
```

Expected: the complete suite and all products pass.

- [ ] **Step 2: Build and replace the installed application**

Use the repository's documented macOS build/install workflow, preserve the
current application as a reversible backup, install the rebuilt app at
`/Applications/CodexSwap.app`, and verify its signature and executable.

- [ ] **Step 3: Exercise the installed skill outside the repository**

Run the globally installed `codexswap-quotas` helper from a temporary directory.
Validate only the sanitized schema and account statuses. Confirm the previously
unavailable enabled account now has live quota data and no forbidden raw fields
appear. Do not print or persist raw CodexBar output.

- [ ] **Step 4: Run independent privacy/auth review**

Review the complete diff and runtime evidence for fixed-command execution,
timeout/cancellation, output bounds, identity ambiguity, raw-data retention,
fallback correctness, stale-local-auth state, and absence of account/quota
mutations. Resolve every BLOCK or REVISE finding and rerun affected checks.

- [ ] **Step 5: Reconcile branch state**

Confirm the worktree is clean, list the resulting commits, and use the
finishing-development-branch workflow. Do not push or merge without the user's
explicit branch disposition.
