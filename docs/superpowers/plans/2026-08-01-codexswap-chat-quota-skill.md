# CodexSwap Chat Quota Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a globally discoverable Codex skill that safely reports fresh usage windows and reset-credit availability for every account managed by CodexSwap.

**Architecture:** A new SwapKit report service converts private `Account` values and two existing read-only clients into sanitized Codable report values. `swapd quota --json` exposes that report without mutating CodexSwap state, and a personal skill invokes the installed command through a small schema-validating helper.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, Bash, Python 3, Codex Agent Skills.

---

## File map

- Create `Sources/SwapKit/QuotaReport.swift`: sanitized quota DTOs, safe error categories, and the report service.
- Create `Tests/SwapKitTests/QuotaReportTests.swift`: report assembly, partial-failure, read-only, and serialization tests.
- Modify `Sources/swapd/main.swift`: add `quota --json` orchestration and help text.
- Create `skills/codexswap-quotas/SKILL.md`: trigger and presentation instructions.
- Create `skills/codexswap-quotas/agents/openai.yaml`: generated UI metadata.
- Create `skills/codexswap-quotas/scripts/check-quotas.sh`: binary discovery and JSON shape validation.
- Install a copy at `~/.codex/skills/codexswap-quotas/`: global discovery outside this repository.

### Task 1: Establish the skill baseline

**Files:** None.

- [ ] **Step 1: Run the natural request without the new skill**

Dispatch a fresh general-purpose subagent with no reference to the intended implementation:

```text
What are my current Codex quotas for every account managed by CodexSwap on this Mac? Report the five-hour and weekly windows, reset times, and manual reset-credit availability. Keep the operation read-only and do not expose credentials or private identifiers. Return the commands used, exit codes, verified results, unresolved gaps, and confidence.
```

- [ ] **Step 2: Record the expected baseline gap**

Confirm the agent can find `swapd usage` at most, but cannot produce one deterministic sanitized report containing both quota windows and per-account reset-credit data. Save the exact gap in the parent task notes; do not add a repository artifact.

### Task 2: Build the sanitized report service with TDD

**Files:**

- Create: `Sources/SwapKit/QuotaReport.swift`
- Create: `Tests/SwapKitTests/QuotaReportTests.swift`

- [ ] **Step 1: Write failing report assembly tests**

Create `QuotaReportTests.swift` with deterministic usage and reset-credit fakes. The primary test constructs two accounts containing unmistakable secret marker strings and asserts:

```swift
func testReportShowsAllAccountQuotaDataWithoutSecrets() async throws {
    let now = Date(timeIntervalSince1970: 1_754_044_800)
    let usage = StubQuotaUsage(results: [
        "alpha": .success([
            UsageWindow(label: "5h", usedPercent: 35, windowSeconds: 18_000, resetAt: now.addingTimeInterval(3_600)),
            UsageWindow(label: "Weekly", usedPercent: 80, windowSeconds: 604_800, resetAt: now.addingTimeInterval(86_400)),
        ]),
        "beta": .success([
            UsageWindow(label: "5h", usedPercent: 100, windowSeconds: 18_000, resetAt: now.addingTimeInterval(7_200)),
        ]),
    ])
    let credits = StubQuotaCredits(results: [
        "alpha": .success(ResetCreditSnapshot(
            availableCount: 2,
            credits: [
                ResetCredit(id: "SECRET-CREDIT-ID", resetType: "manual", status: "available", grantedAt: now, expiresAt: now.addingTimeInterval(172_800))
            ],
            fetchedAt: now
        )),
        "beta": .success(ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: now)),
    ])
    let service = QuotaReportService(usageService: usage, resetService: credits, clock: { now })
    let report = await service.fetch(
        accounts: [
            Account(alias: "alpha", email: "SECRET-EMAIL", accountID: "SECRET-ACCOUNT-ID", planType: "plus", accessToken: "alpha", refreshToken: "SECRET-REFRESH"),
            Account(alias: "beta", accessToken: "beta", routingEnabled: false),
        ],
        activeAlias: "alpha"
    )

    XCTAssertEqual(report.schemaVersion, 1)
    XCTAssertEqual(report.accounts.map(\.alias), ["alpha", "beta"])
    XCTAssertEqual(report.accounts[0].state, .active)
    XCTAssertEqual(report.accounts[0].windows.map(\.remainingPercent), [65, 20])
    XCTAssertEqual(report.accounts[0].availableResetCredits, 2)
    XCTAssertEqual(report.accounts[0].earliestResetCreditExpiry, now.addingTimeInterval(172_800))
    XCTAssertEqual(report.accounts[1].state, .paused)

    let encoded = try QuotaReportJSON.encode(report)
    let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
    for forbidden in ["SECRET-EMAIL", "SECRET-ACCOUNT-ID", "SECRET-REFRESH", "SECRET-CREDIT-ID"] {
        XCTAssertFalse(text.contains(forbidden))
    }
}
```

Add tests named:

- `testPartialFailuresPreserveSuccessfulDataAndUseSafeCategories`
- `testMissingAuthenticationSkipsNetworkAndMarksSignInRequired`
- `testEmptyAccountListProducesValidEmptyReport`
- `testRemainingPercentageClampsAtZero`
- `testServiceDoesNotMutateAccountValuesOrAccountStore`

Use actor fakes keyed by the access token, returning `Result` values and call counts. Use only safe synthetic marker values.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
rtk proxy swift test --filter QuotaReportTests
```

Expected: compilation fails because `QuotaReportService`, report DTOs, and `QuotaReportJSON` do not exist.

- [ ] **Step 3: Implement the minimal sanitized report types**

Create `QuotaReport.swift` with these public interfaces:

```swift
public enum AccountQuotaState: String, Codable, Sendable {
    case active, available, paused, signInRequired
}

public enum QuotaLookupStatus: String, Codable, Sendable {
    case ok, signInRequired, unauthorized, timeout, network, serviceError, malformedResponse
}

public struct QuotaWindowReport: Codable, Sendable, Equatable {
    public let label: String
    public let usedPercent: Int
    public let remainingPercent: Int
    public let resetAt: Date?
}

public struct AccountQuotaReport: Codable, Sendable, Equatable {
    public let alias: String
    public let plan: String?
    public let state: AccountQuotaState
    public let usageStatus: QuotaLookupStatus
    public let windows: [QuotaWindowReport]
    public let resetCreditStatus: QuotaLookupStatus
    public let availableResetCredits: Int?
    public let earliestResetCreditExpiry: Date?
}

public struct CodexQuotaReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let fetchedAt: Date
    public let accounts: [AccountQuotaReport]
}

public struct QuotaReportService: Sendable {
    public init(
        usageService: any UsageFetching,
        resetService: any QuotaResetServing,
        clock: @escaping @Sendable () -> Date = Date.init
    )

    public func fetch(accounts: [Account], activeAlias: String?) async -> CodexQuotaReport
}

public enum QuotaReportJSON {
    public static func encode(_ report: CodexQuotaReport) throws -> Data
}
```

Implement account-state precedence as `signInRequired`, `paused`, `active`, then `available`. Sort active first and remaining aliases case-insensitively. For authenticated accounts, fetch usage and credits independently so either result survives the other's failure. Construct DTOs field-by-field; never encode `Account`, `ResetCredit`, raw `Error`, request data, or response bodies.

Map errors only to the `QuotaLookupStatus` enum:

```swift
private static func usageStatus(for error: Error) -> QuotaLookupStatus {
    if let usageError = error as? UsageClient.UsageError {
        switch usageError {
        case .unauthorized: return .unauthorized
        case .http: return .serviceError
        case .malformed: return .malformedResponse
        }
    }
    if let urlError = error as? URLError {
        return urlError.code == .timedOut ? .timeout : .network
    }
    return .serviceError
}
```

Map `QuotaResetClientError` without associated status values: unauthorized, timeout, network, malformed response, and service error. Encode dates as ISO 8601, keys sorted, and output pretty-printed.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
rtk proxy swift test --filter QuotaReportTests
```

Expected: all `QuotaReportTests` pass with no warnings.

- [ ] **Step 5: Commit the report service**

```bash
rtk git add Sources/SwapKit/QuotaReport.swift Tests/SwapKitTests/QuotaReportTests.swift
rtk git commit -m "feat: add sanitized multi-account quota reports"
```

### Task 3: Expose `swapd quota --json`

**Files:**

- Modify: `Sources/swapd/main.swift`
- Test: `Tests/SwapKitTests/QuotaReportTests.swift`

- [ ] **Step 1: Add a failing serialization-contract assertion**

Extend `testReportShowsAllAccountQuotaDataWithoutSecrets` to decode the generated JSON as a dictionary and assert exact top-level keys:

```swift
let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
XCTAssertEqual(Set(object.keys), ["schemaVersion", "fetchedAt", "accounts"])
XCTAssertNotNil(object["accounts"] as? [[String: Any]])
```

Add `testJSONEncodingIsStableAndISO8601` asserting the encoded output contains `"schemaVersion" : 1` and the exact ISO-8601 fetch timestamp.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
rtk proxy swift test --filter QuotaReportTests/testJSONEncodingIsStableAndISO8601
```

Expected: failure until encoder formatting and date strategy meet the contract.

- [ ] **Step 3: Add the CLI command**

In `Sources/swapd/main.swift`, add before the mutating commands:

```swift
case "quota":
    guard args.dropFirst().elementsEqual(["--json"]) else {
        FileHandle.standardError.write("usage: swapd quota --json\n".data(using: .utf8)!)
        exit(64)
    }
    let service = QuotaReportService(usageService: UsageClient(), resetService: QuotaResetClient())
    let report = await service.fetch(accounts: await store.all(), activeAlias: await store.activeAlias())
    do {
        let data = try QuotaReportJSON.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
        FileHandle.standardError.write("failed to encode sanitized quota report\n".data(using: .utf8)!)
        exit(1)
    }
```

Add `quota --json` to `printHelp()` with wording that it reads fresh usage and reset credits for every account. Do not call `updateUsage`, `setActive`, `hydrateFromManagedHome`, warm-up, reset consumption, or account import.

- [ ] **Step 4: Verify the CLI contract**

Run:

```bash
rtk proxy swift test --filter QuotaReportTests
rtk proxy swift build --product swapd
rtk proxy .build/debug/swapd help
```

Expected: tests and build pass; help contains `quota --json`.

- [ ] **Step 5: Commit the CLI**

```bash
rtk git add Sources/swapd/main.swift Tests/SwapKitTests/QuotaReportTests.swift
rtk git commit -m "feat: expose read-only quota JSON command"
```

### Task 4: Create and install the Codex skill with skill TDD

**Files:**

- Create: `skills/codexswap-quotas/SKILL.md`
- Create: `skills/codexswap-quotas/agents/openai.yaml`
- Create: `skills/codexswap-quotas/scripts/check-quotas.sh`
- Install: `~/.codex/skills/codexswap-quotas/`

- [ ] **Step 1: Initialize the skill**

Read `references/openai_yaml.md` from the system `skill-creator` directory. Then run:

```bash
rtk proxy python3 /Users/vjmabansag/.codex/skills/.system/skill-creator/scripts/init_skill.py codexswap-quotas --path skills --resources scripts --interface 'display_name=CodexSwap Quotas' --interface 'short_description=Check every local CodexSwap account quota' --interface 'default_prompt=Show the current CodexSwap quotas for all accounts without changing anything.'
```

- [ ] **Step 2: Write the deterministic helper**

Replace the generated placeholder with `scripts/check-quotas.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

candidates=(
  "/Applications/CodexSwap.app/Contents/MacOS/swapd"
  "/Users/vjmabansag/Projects/CodexSwap/.build/release/swapd"
  "/Users/vjmabansag/Projects/CodexSwap/.build/debug/swapd"
)

for binary in "${candidates[@]}"; do
  [[ -x "$binary" ]] || continue
  if output="$($binary quota --json 2>/dev/null)"; then
    printf '%s' "$output" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if data.get("schemaVersion") != 1 or not isinstance(data.get("accounts"), list):
    raise SystemExit("incompatible CodexSwap quota schema")
json.dump(data, sys.stdout, sort_keys=True)
sys.stdout.write("\n")
'
    exit 0
  fi
done

echo "No compatible CodexSwap quota command was found. Build or update CodexSwap first." >&2
exit 1
```

Make it executable. The helper must never read `accounts.json`, authentication files, or Keychain data itself.

- [ ] **Step 3: Write the concise skill instructions**

Use this trigger-only frontmatter:

```yaml
---
name: codexswap-quotas
description: Use when the user asks for current Codex quota, usage, remaining capacity, reset times, or reset-credit availability across accounts managed by CodexSwap on this Mac.
---
```

In the body, require running the helper through `rtk proxy`, reporting every account alias with 5-hour/weekly used and remaining percentages, reset times in Asia/Manila, reset-credit count/expiry, fetched time, and partial errors. Explicitly prohibit account switching, warm-up, import, reset redemption, and disclosure of emails, tokens, account IDs, credit IDs, or raw JSON fields outside the sanitized schema.

- [ ] **Step 4: Validate and install the skill**

Run:

```bash
rtk proxy python3 /Users/vjmabansag/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/codexswap-quotas
rtk proxy bash skills/codexswap-quotas/scripts/check-quotas.sh
rtk proxy mkdir -p /Users/vjmabansag/.codex/skills/codexswap-quotas
rtk proxy ditto skills/codexswap-quotas /Users/vjmabansag/.codex/skills/codexswap-quotas
rtk proxy python3 /Users/vjmabansag/.codex/skills/.system/skill-creator/scripts/quick_validate.py /Users/vjmabansag/.codex/skills/codexswap-quotas
```

Expected: both validation runs pass; the helper emits schema version 1 and an account array.

- [ ] **Step 5: Register the personal skill installation**

Register the small, reversible user-scoped skill copy in the privacy-safe hygiene ledger using an opaque resource ID and rollback reference:

```bash
rtk proxy python3 /Users/vjmabansag/.codex/hygiene/hygiene_ledger.py register 74f32068ab9f2d76492df72a719ff65b --category skill --manager codex --scope user --owner-task 019fbdabec867bc2b12dc61626116d5c --removal-test codexswap-quota-skill-copy --rollback-ref 5ef23a1e975c1ed6cb3cd3917d483c5f --reversible
```

- [ ] **Step 6: Commit the skill source**

```bash
rtk git add skills/codexswap-quotas
rtk git commit -m "feat: add CodexSwap quota chat skill"
```

### Task 5: Forward-test, install the app command, and verify end-to-end

**Files:**

- Build: `dist/CodexSwap.app`
- Install/update: `/Applications/CodexSwap.app`

- [ ] **Step 1: Forward-test the installed skill**

Dispatch a fresh general-purpose subagent with:

```text
Use $codexswap-quotas at /Users/vjmabansag/.codex/skills/codexswap-quotas to answer: What are my current Codex quotas for every CodexSwap account? Include five-hour and weekly windows plus manual reset credits. Do not change accounts or quota. Return the user-facing answer, commands and exit codes, secret-safety check, unresolved risks, and confidence.
```

Expected: the agent runs only the helper, reports all available accounts, and exposes none of the forbidden fields.

- [ ] **Step 2: Run complete project verification**

Run:

```bash
rtk proxy swift test
rtk proxy swift build --target CodexSwapApp
rtk git diff --check
```

Expected: all tests and builds pass; diff check is clean.

- [ ] **Step 3: Build and install the updated local app bundle**

Run:

```bash
rtk proxy Scripts/build-app.sh
rtk proxy ditto dist/CodexSwap.app /Applications/CodexSwap.app
rtk proxy codesign --verify --deep --strict /Applications/CodexSwap.app
rtk proxy /Applications/CodexSwap.app/Contents/MacOS/swapd help
```

Expected: signing verification passes and installed help contains `quota --json`.

- [ ] **Step 4: Verify from outside the repository**

From `/private/tmp`, run:

```bash
rtk proxy bash /Users/vjmabansag/.codex/skills/codexswap-quotas/scripts/check-quotas.sh
```

Validate the output with Python: schema version 1, unique aliases, expected quota fields, and absence of keys or values matching `email`, `token`, `accountID`, `creditID`, `Authorization`, or bearer-token patterns.

- [ ] **Step 5: Reconcile managed-resource hygiene**

Run:

```bash
rtk proxy python3 /Users/vjmabansag/.codex/hygiene/hygiene_ledger.py use 74f32068ab9f2d76492df72a719ff65b
rtk proxy python3 /Users/vjmabansag/.codex/hygiene/hygiene_ledger.py reconcile
rtk proxy python3 /Users/vjmabansag/.codex/hygiene/hygiene_ledger.py verify
```

Expected: the resource use is recorded and ledger verification returns success.

- [ ] **Step 6: Record acceptance evidence**

Report every Gherkin scenario from the design as passed, failed, blocked, or not tested, with the exact test/build/runtime command supporting the status. Record the installed command path, skill path, and final commit IDs. Do not include live account aliases or quota values in commit messages or persistent metadata.
