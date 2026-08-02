# CodexBar-Primary Quota Retrieval Design

## Goal

Make `swapd quota --json` refresh and retrieve quota data through the installed
CodexBar account homes before using CodexSwap's stored credentials. This must
fix accounts whose CodexSwap routing toggle is enabled but whose stored token is
stale, including the reported `mabansagbj` case, without changing the existing
sanitized JSON contract.

## Source decision

Use the installed CodexBar one-shot CLI as the primary quota source:

```text
/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI
  usage --provider codex --all-accounts --source oauth --format json --json-only
```

CodexBar is already installed and signed on this Mac. Its official Codex
provider refreshes sufficiently old OAuth credentials before requesting the
usage endpoint, and `--all-accounts` scopes each request to its managed Codex
home. The foreground `serve` mode is deliberately excluded because it would
add a long-lived unauthenticated loopback service to a one-shot inspection
workflow.

CodexSwap remains the public interface and privacy boundary. Raw CodexBar JSON
must never reach stdout, stderr, logs, thrown error descriptions, or the Codex
skill. CodexSwap continues to emit schema version 1 with only safe aliases,
plans, account state, quota windows, reset-credit count/expiry, and safe status
categories.

## Components

### CodexBar command runner

Add a small process runner that launches only the fixed app-bundle executable
with the fixed argument list. It uses `Foundation.Process`, not a shell. It
caps captured stdout and stderr, enforces a bounded timeout, terminates the
child on cancellation/timeout, and reports only typed safe failures. Stderr is
never included in an error description.

The executable location is capability-checked at runtime. An absent,
non-executable, timed-out, non-zero, oversized, or malformed result causes the
existing direct CodexSwap lookup to run; it never prevents a quota report.

### CodexBar parser and matcher

Parse only these fields:

- top-level `account`, `usage`, and `error`;
- `usage.accountEmail` and `usage.identity.accountEmail` for private matching;
- `usage.primary`, `secondary`, and `tertiary` quota windows;
- `usage.codexResetCredits.availableCount` and credit status/expiry.

Match a raw item to a local `Account` only when exactly one local account shares
an exact normalized identity candidate. Candidates are the alias, email, and
email local-part. Matching is internal and raw values are discarded after the
safe snapshot map is built. Ambiguous or unmatched items are ignored and use
the direct fallback.

Translate `windowMinutes` to `UsageWindow.label(forWindowSeconds:)`, clamp
percentages to 0 through 100, parse ISO-8601 reset timestamps, and sort windows
by duration. Translate reset credits to a count and the earliest unexpired
available-credit expiry. Credit IDs, descriptions, titles, grant times, and raw
errors are never retained.

### Report orchestration

`swapd quota --json` performs one CodexBar prefetch for the full account list,
then passes the safe snapshots to `QuotaReportService`.

For each account and data dimension:

1. use a valid CodexBar usage window set or reset-credit snapshot;
2. otherwise call the existing `UsageClient` or `QuotaResetClient` with the
   stored CodexSwap credential;
3. preserve the existing safe status categorization if both paths fail.

A successfully matched CodexBar snapshot proves current authorization even if
the stored CodexSwap account has `needsLogin` or a stale access token. It does
not enable routing, switch the active account, persist a refreshed token into
CodexSwap, warm a quota window, redeem a credit, import an account, or modify
settings. Routing state remains controlled by `routingEnabled`.

## Acceptance scenarios

```gherkin
Feature: Refresh all CodexSwap quotas through CodexBar

  Rule: Current CodexBar authorization is preferred

    Scenario: Recover quota for a locally stale enabled account
      Given an enabled CodexSwap account has a stale stored credential
      And CodexBar can refresh and fetch that managed account
      When the user asks for current quotas
      Then the account shows the CodexBar quota windows and reset credits
      And it is not labeled sign-in-required solely because of the stale store

    Scenario: Fall back when CodexBar has no usable item
      Given CodexBar is absent, fails, or cannot uniquely match an account
      When current quotas are requested
      Then CodexSwap uses its existing direct quota clients for that account
      And other successful CodexBar account results are preserved

  Rule: Raw CodexBar data stays private

    Scenario: Sanitize identities and credit metadata
      Given CodexBar returns emails, account labels, raw errors, and credit IDs
      When `swapd quota --json` emits the report
      Then none of those raw private values appear in output or safe errors
      And the schema version 1 public shape is unchanged

  Rule: Inspection does not alter account or quota state

    Scenario: Run a one-shot refreshed inspection
      When CodexSwap invokes CodexBar usage
      Then it does not start CodexBar serve mode
      And it does not switch accounts, change routing, redeem credits, or write
          refreshed credentials into the CodexSwap store
```

## Verification

- Parser fixtures cover all three window positions, malformed dates, reset
  credits, raw errors, ambiguous matching, and forbidden-marker exclusion.
- Report-service tests prove CodexBar precedence and independent direct fallback
  for usage and reset credits.
- Command-runner tests prove the exact executable/arguments and safe failure
  categories without embedding raw output in errors.
- Focused tests run first, followed by the complete Swift suite and app build.
- The rebuilt app and globally installed skill are exercised outside the repo;
  the sanitized result must show the previously unavailable account with live
  quota data.

## Scope boundaries

No UI redesign, account import, routing change, credential-store migration,
background daemon, HTTP service, quota warm-up, credit redemption, or public
schema change is included.
