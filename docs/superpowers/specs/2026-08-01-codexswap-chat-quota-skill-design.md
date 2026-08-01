# CodexSwap Chat Quota Skill Design

## Goal

Let VJ ask Codex natural questions such as “What are my Codex quotas?” from
any Codex chat on this Mac and receive a fresh, safe summary for every account
managed by CodexSwap.

The report covers both normal usage windows and manual reset credits. Checking
quota must never switch accounts, warm a quota window, redeem a reset credit,
or expose authentication material.

## User experience

The personal Codex skill triggers on requests for current CodexSwap quota,
usage, remaining capacity, reset times, or reset-credit availability across
accounts. It invokes one deterministic helper and summarizes the result in the
user's local timezone, Asia/Manila.

A successful report shows, for each account alias:

- plan when known;
- active, paused, or sign-in-required state;
- each available usage window's used and remaining percentages;
- each window's reset time;
- available manual reset-credit count and earliest expiry; and
- the fetch time.

The report does not show email addresses, access or refresh tokens, ChatGPT
account IDs, reset-credit IDs, or raw account-store content.

## Architecture

### Sanitized quota command

Add a read-only `swapd quota --json` command. The command loads the accounts
already managed by CodexSwap, fetches current usage windows through
`UsageClient`, and fetches reset-credit metadata through `QuotaResetClient`.

The command emits a versioned JSON document intended for machine consumption.
Its account objects contain only presentation-safe fields. Each remote lookup
has its own status so a failure in one endpoint or account does not discard the
remaining report.

The existing `swapd usage` behavior remains unchanged for compatibility.

### Testable report service

Place quota-report assembly in SwapKit behind the existing usage-fetching and
reset-credit-serving protocols. The service accepts account snapshots and
fetching dependencies, performs independent read-only lookups, calculates
remaining percentage as `max(0, 100 - usedPercent)`, and returns Codable report
values. This isolates network behavior from CLI serialization and lets tests
use deterministic fakes.

The service does not persist tokens, quota results, cooldowns, active-account
selection, or settings. It may use the current in-memory account information,
but it must not call account mutation methods.

### Personal Codex skill

Keep the version-controlled skill source at
`skills/codexswap-quotas/`. Install a copy at
`~/.codex/skills/codexswap-quotas/` so it is available outside this repository.

The skill contains:

- a concise `SKILL.md` with natural-language quota triggers and strict
  read-only/privacy rules;
- `agents/openai.yaml` generated from the skill metadata; and
- a deterministic helper that locates the installed CodexSwap `swapd` binary,
  invokes `quota --json`, validates the basic output shape, and prints only the
  sanitized report.

Binary resolution prefers `/Applications/CodexSwap.app/Contents/MacOS/swapd`,
then an explicit CodexSwap development binary on this Mac. Failure to locate a
compatible binary produces remediation guidance without reading the private
account store directly.

## Data flow

1. The user asks Codex for current quotas.
2. Codex loads `codexswap-quotas` from its trigger metadata.
3. The skill runs its helper.
4. The helper invokes `swapd quota --json`.
5. `swapd` reads the managed account list and performs read-only usage and
   reset-credit requests per account.
6. `swapd` emits sanitized JSON.
7. Codex presents a compact all-account summary and clearly labels partial or
   stale results.

## Error handling

- No managed accounts: return a successful empty report with guidance to open
  CodexSwap and import/sign in accounts.
- Missing or expired authentication: mark only that account as sign-in
  required; continue with other accounts.
- Usage endpoint failure: preserve any reset-credit result and report the usage
  error without raw response bodies.
- Reset-credit endpoint failure: preserve usage windows and report credit
  status as unavailable.
- Timeout or network failure: report a safe category and continue; do not print
  request headers, response bodies, or credentials.
- Unknown JSON schema or incompatible binary: fail closed with a short upgrade
  message.
- A user merely asking for quota never authorizes reset-credit consumption,
  quota warm-up, account switching, or account import.

## Acceptance scenarios

```gherkin
Feature: Ask Codex for all CodexSwap quotas

  Rule: Quota inspection is current and read-only

    Scenario: Report all available account quota data
      Given CodexSwap manages multiple signed-in accounts
      When the user asks Codex for the current quotas
      Then each account alias shows its available usage windows and reset times
      And each account shows its reset-credit availability
      And the report states when it was fetched

    Scenario: Preserve partial results
      Given one account lookup fails while another succeeds
      When Codex checks the current quotas
      Then the successful account data is still reported
      And the failed lookup has a safe account-specific error

    Scenario: Protect account secrets
      Given CodexSwap account records contain credentials and private identifiers
      When the quota command emits its report
      Then no token, email address, account ID, or credit ID is present

    Scenario: Do not consume or alter quota
      Given accounts have quota windows and manual reset credits
      When Codex checks the current quotas
      Then no warm-up, reset redemption, account switch, or settings change occurs

  Rule: The skill works outside the repository directory

    Scenario: Ask from another Codex chat
      Given the personal skill is installed and CodexSwap is installed
      When the user asks “What are my Codex quotas?” from another workspace
      Then Codex invokes the installed CodexSwap quota command
      And returns the sanitized all-account report
```

## Verification

- Run a baseline subagent prompt without the new skill and record that no
  deterministic all-account workflow is available.
- Add failing Swift tests for report assembly, partial failures, serialization,
  and secret exclusion before implementing the command.
- Run focused Swift tests, then the full `swift test` suite.
- Validate the skill with `quick_validate.py` and verify its metadata.
- Forward-test the same natural quota prompts with a fresh subagent using the
  installed skill.
- Run the helper against the installed or freshly built binary and inspect the
  output for every forbidden secret field.
- Build the CodexSwap application target and confirm the installed skill remains
  usable outside the repository working directory.

## Scope boundaries

This change does not add remote access, expose an HTTP status endpoint, change
CodexSwap routing, alter automatic reset policy, consume reset credits, warm
quota windows, or redesign the macOS settings UI.
