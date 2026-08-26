# Account archiving, usage insights, and reliable Smart Switch routing

## Decision

CodexSwap will add four connected changes:

1. Five-hour quota windows show a localized reset time only. Weekly and other windows keep a localized date and time.
2. Accounts can be archived locally without deleting credentials or changing CodexBar. Archived accounts keep historical usage but leave every active routing, ranking, automation, quota, and pool surface.
3. Paused accounts automatically enter the archive after seven full days without CodexSwap-routed use.
4. The Usage Monitor gains decision-oriented derived metrics backed by local, metadata-only request telemetry.

The same release will repair the existing Smart Switch defect. Drain preference currently works in ranked selection but is bypassed by several round-robin and Task Board selection paths. Restricted quota polls can also erase valid drain observations for accounts they did not inspect.

## Goals

- Make the common five-hour reset label scannable without losing the full reset timestamp in storage or JSON output.
- Let the owner remove dormant accounts from operational views without removing their OAuth bundle or CodexBar-managed home.
- Keep the active roster clean automatically when a routing pause lasts at least seven days.
- Answer practical questions about capacity, caching, reliability, latency, retries, model mix, account mix, cost estimates, and bounded Task Board outcomes.
- Keep analytics local and content-free.
- Make Smart Switch drain preference consistent across ranked and round-robin automatic selection.

## Non-goals

- Deleting or revoking OAuth credentials.
- Editing CodexBar's roster, account files, settings, or polling behavior.
- Treating tokens, lines of code, keystrokes, or message volume as productivity.
- Inferring the quality or success of interactive conversations.
- Claiming estimated cost is provider billing.
- Uploading telemetry or adding a hosted analytics service.
- Recording prompts, responses, commands, file paths, headers, request bodies, raw error bodies, or session transcripts.
- Reordering the visible account ranking when Smart Switch makes a temporary routing choice.

## Terminology

- **Active roster:** every stored account whose `archivedAt` is `nil`. It includes routing-enabled and routing-paused accounts.
- **Routing-paused:** an active-roster account with `routingEnabled == false`.
- **Archived:** a stored account with a non-`nil` `archivedAt`.
- **Routed use:** an actual upstream model attempt made through CodexSwap. Settings views, imports, quota refreshes, reset-credit checks, and local log scans are not routed use.
- **Root request:** one client request before CodexSwap retries or changes accounts.
- **Attempt:** one upstream request made for a root request. A retry is a new attempt.
- **Metadata telemetry:** a strict allowlist of counts, categories, timestamps, and durations. It contains no request or response content.

## Reset-time presentation

`UsageWindow.resetAt` remains a full `Date`. Codable models, quota JSON, reset calculations, and scheduling keep the exact timestamp.

A shared `UsageResetPresentation` formatter in `SwapKit` becomes the only formatter for human-readable quota-window reset captions:

- `windowSeconds == 18_000`: `Resets 3:30 PM` in the current locale and time zone.
- `windowSeconds == 604_800`: `Resets Aug 30, 3:30 PM` using localized date and time styles.
- Any other known window: localized date and time.
- Missing timestamp: no caption in the app and `-` in the human CLI.
- Timestamp at or before the injected current time: `resetting…` in the app and `resetting` in the human CLI.

The formatter is used by account settings, menu rows, Usage Monitor cards, human-readable `swapd usage`, and notifications that know the quota-window label. Machine-readable `swapd quota --json` remains unchanged. Cooldowns that do not identify a quota window keep a date and time so the day is not ambiguous.

Tests inject `now`, locale, calendar, and time zone. They cover 12-hour and 24-hour locales, a daylight-saving boundary, missing timestamps, and expired timestamps.

## Account state and migration

`Account` gains two optional timestamps and one random local identifier:

```swift
public var archivedAt: Date?
public var routingPausedAt: Date?
public var telemetryID: UUID
```

`isArchived` is derived from `archivedAt != nil`; a second persisted Boolean is not added.

The account-store schema version increments. Decoding older accounts follows these rules:

1. Missing `archivedAt` decodes as `nil`.
2. Missing `routingPausedAt` on a routing-enabled account remains `nil`.
3. Missing `routingPausedAt` on a routing-paused account is set to the migration time and persisted once. This gives every legacy paused account a fresh seven-day grace period.
4. Migration never backdates a pause from `lastUsedAt` or `lastServedByUs`.
5. Dates later than the current clock are preserved and fail safe: they cannot cause early automatic archival.
6. A missing `telemetryID` receives one new random UUID during store migration. The store persists that UUID atomically with the schema migration before telemetry can record an event. Restarts and periodic imports preserve it; decoding must not generate a replacement on every load. Telemetry never uses an email-derived alias, email, or upstream account ID as its storage key.

The store receives an injectable clock for deterministic migration and seven-day boundary tests.

## Archive lifecycle

### Manual archive

Archiving an account is an idempotent local store operation:

- set `archivedAt` to the current time if it is not already set;
- set `routingEnabled` to `false`;
- set `routingPausedAt` if needed;
- clear the account as the active alias;
- clear any in-memory drain observation for the alias;
- remove the account from the active rank sequence and renumber only the remaining active roster;
- retain tokens, `managedHomePath`, usage windows, usage history, lifetime token totals, model totals, reset preferences, warm-up exclusions, and Task Board account preferences.

The operation does not call CodexBar, remove a managed home, delete an auth file, revoke a token, or run the existing permanent-remove path.

### Restore

Restoring is also idempotent:

- clear `archivedAt`;
- keep routing disabled;
- set `routingPausedAt` to the restore time, giving the owner seven days to re-enable routing before the account can auto-archive again;
- insert the account at the bottom of the active ranking and renumber active ranks;
- retain credentials, ownership, usage, history, and saved automation preferences;
- do not restore a stale drain observation.

The owner must explicitly enable routing after restore. Neither an archived nor a restored-but-paused account can be switched to directly.

### External roster changes

Periodic CodexBar and local-auth imports preserve `archivedAt`, `routingPausedAt`, routing state, priority overlay, usage, and telemetry fields. A re-import cannot unarchive an account.

CodexBar deletion remains an independent external action. If an account disappears from CodexBar's managed roster, the existing reconciliation behavior may remove the CodexSwap record. Every permanent removal path returns the removed account's `telemetryID` to the engine so request events and scoped daily/lifetime attempt aggregates for that identifier are purged in the same owner-visible operation. The archive command itself never triggers removal and never mutates CodexBar.

## Automatic archive

Automatic archive runs after store migration at startup and once per normal engine poll before network quota work.

An account is eligible when all conditions are true:

```text
archivedAt == nil
routingEnabled == false
routingPausedAt != nil
now >= max(routingPausedAt, lastServedByUs when later) + 604800 seconds
```

Rules:

- The comparison is inclusive at exactly seven full days.
- Enabling routing clears `routingPausedAt` and prevents automatic archive.
- Disabling routing stamps `routingPausedAt` only on the enabled-to-paused transition. Opening settings or saving an already-paused toggle does not extend the deadline.
- A later routed-use timestamp extends the deadline. This covers an attempt already in flight when routing is paused.
- Imports, quota polls, warm-up status checks, reset-credit refreshes, local session scans, and telemetry reads do not extend the deadline.
- A backward clock jump delays archival. A forward jump can archive only when the deadline derived from the persisted timestamps has passed.
- The automatic operation uses the same archive transaction as manual archive.
- A routing lease held by an in-flight proxy attempt or running Task Board pin defers automatic archival without changing the stored pause timestamp. The next tick archives immediately when the lease ends if the derived deadline is already due.
- Manual archive remains available during a lease but warns that the account is in use. After confirmation, the in-flight attempt may finish, no new attempt may use the account, and Task Board selects another allowed eligible account or pauses with `No eligible account` when none exists.

## Central active-roster guard

Archive exclusion is an invariant, not a collection of UI filters. `Account.isEligible` requires `archivedAt == nil`, and store APIs expose explicit active and archived collections.

Every automatic consumer must use the active collection or `isEligible`:

- ranked and round-robin selection;
- current account validation, manual switch, failover, cooldown recovery, and login recovery;
- Smart Switch detection and drain state;
- Task Board allowed-account resolution, initial selection, retries, fallback, and hard pins;
- automatic and manual warm-up candidate lists;
- quota polling, reset-credit refresh, and automatic reset;
- local session scanning and attribution;
- active pool, health, capacity, and ranking summaries;
- menu rows, paused rows, Settings ranking, and human CLI ranking;
- `swapd usage` and quota reports.

A hard-pinned task cannot bypass archive state. A saved alias may stay in automation preferences, but it resolves as unavailable until restored.

## No archived quota fetching

CodexSwap does not make usage, reset-credit, warm-up, or local-session scan calls for archived accounts. Their last stored quota windows are retained as historical data but are labeled stale and are not presented as live headroom.

`CodexBarQuotaClient` currently invokes `CodexBarCLI usage --all-accounts` even when the caller supplies a subset. To preserve the no-fetch guarantee:

- app polling continues to use per-account clients over active accounts only;
- `swapd usage` iterates active accounts only;
- if any archived account exists, `swapd quota --json` skips the global CodexBar prefetch and uses the direct active-account report path;
- a CodexSwap process must not launch CodexBar's `--all-accounts` quota command while its store contains an archived account.

CodexBar is a separate application and may perform its own polling. CodexSwap neither controls nor changes that behavior.

## Smart Switch repair

### Verified defect

Drain detection and ranked selection already work in isolation. The defect is inconsistent consumption of drain state:

- priority `current()` and `bestEligible()` use drain-aware ordering;
- round-robin `current()` returns an eligible active account before consulting drain state;
- round-robin `advanceRoundRobin()`, `rotateFrom()`, and `markNeedsLogin()` call an LRU helper that ignores drain state;
- interactive first-turn selection inherits the round-robin bypass;
- Task Board initial account selection sorts without drain state;
- restricted usage polls replace the full drain set, erasing observations for accounts they did not poll.

A focused diagnostic test reproduced the first failure: with round-robin enabled, `active` selected, and `draining` marked as draining, `current()` returned `active` instead of `draining`.

### Selection contract

Smart Switch is a preference inside existing hard constraints:

1. Exclude archived, routing-paused, logged-out, tokenless, cooled-down, and task-disallowed accounts.
2. Respect an explicit manual switch and a Task Board hard pin while they remain valid.
3. Among the remaining automatic candidates, put currently draining accounts first.
4. Within the draining group, compare five-hour used percent descending, then weekly used percent descending, then the configured rank or LRU order, then alias ascending.
5. Within the non-draining group, preserve ranking or round-robin order.

This contract applies to ranked and round-robin `current`, new-turn advance, quota rotation, login recovery, interactive selection, Task Board initial selection, Task Board retry/fallback selection, and fresh-alternative selection.

Explicit warm-up remains exempt because the owner chose its account set. A valid Task Board hard pin remains exempt until it becomes ineligible. Neither exemption can route an archived account.

### Detection and state propagation

Drain detection compares the current quota reading to the oldest successful baseline from the same quota window inside a dynamic lookback. `WindowSample` gains the optional reset timestamp needed to distinguish windows:

```text
lookback = min(3600 seconds, max(900 seconds, 2 * configured poll interval))
draining when current used percent - baseline used percent >= 2 points
and CodexSwap has not routed the account at or after the baseline timestamp
```

This replaces the broad fixed 30-minute suppression with evidence tied to the measured interval. CodexSwap stamps `lastServedByUs` for every real upstream attempt, not only when the active alias changes or a usage trailer is decoded.

Drain observations are runtime state and do not persist across app restarts. Their update rules are:

- a successful assessment updates or clears only the assessed alias;
- a restricted poll merges results and never clears unpolled aliases;
- a transient fetch failure leaves the prior observation unchanged;
- an observation expires after the dynamic lookback without successful confirmation;
- a quota reset, archive, restore, routing pause, login failure, or successful non-drain assessment clears the observation;
- a changed reset timestamp or lower used percent marks a quota reset, clears the observation, and starts a new baseline;
- turning Smart Switch off clears all observations;
- turning it on starts an immediate full active-roster poll. The first reading may show `Learning`; detection needs a baseline.

## Metadata telemetry

### Event allowlist

`UsageTelemetryStore` is a new `SwapKit` actor with a separate versioned file under CodexSwap Application Support. Each upstream attempt may store only:

- random local `eventID` and `rootRequestID`;
- attempt index and retry relationship;
- start and finish timestamps;
- random per-account `telemetryID`, never alias, email, upstream account ID, or OAuth token;
- normalized provider family and bounded model identifier;
- request category: interactive, Task Board, or warm-up;
- optional Task Board run UUID, never task title, prompt, repository, branch, log name, or session ID;
- outcome category: success, HTTP error, transport error, cancelled;
- bounded HTTP status code;
- low-cardinality error class: rate limit, quota exhausted, authentication, timeout, network, upstream 5xx, malformed response, cancelled, or other;
- total duration and optional time to first streamed response chunk;
- input, cached-input, cache-write, output, and reasoning token counts when reported;
- completeness for every optional token category;
- estimated USD cost, cost completeness, pricing source, and pricing revision when calculable.

Provider request IDs are not analytics identifiers. Raw model strings longer than the bounded limit or outside the normalized catalog collapse to `other`.

The serializer is allowlist-based. It cannot accept a prompt, response, request body, command, path, header map, raw error, stack trace, stdout, stderr, final message, or task summary. Existing Task Board logs and summaries remain operational artifacts and are not copied into telemetry.

### Attempt instrumentation

The proxy creates a root request ID on client request receipt and a new event ID for every upstream attempt. It records start time, first streamed chunk, completion, status, retry index, selected account/model, safe error class, and reported usage.

Telemetry is best effort:

- a write, decode, or aggregation failure never changes proxy status, response bytes, retry behavior, account selection, or task outcome;
- counters use non-negative validation and saturating arithmetic;
- invalid durations, token counts, status codes, and timestamps are discarded rather than coerced;
- missing token fields remain unknown, never zero;
- duplicate event IDs are ignored.

`CodexEventDecoder` adds reasoning-token extraction for Task Board totals, but it still discards item text for analytics. Reasoning tokens are a subset of output tokens and are never added to output a second time.

Metadata telemetry is explicit opt-in. New and migrated settings default `Collect local metadata telemetry` to off. The Usage Monitor explains the exact allowlist and local retention before enabling it. Disabling collection stops new events; retention pruning still runs, existing aggregates remain available, and the clear action remains separate.

`Settings.metadataTelemetryEnabled: Bool` owns the persisted choice in `Settings.swift`. Its initializer and decoder default to `false` when the key is absent. The Usage Monitor toggle writes this field through the existing settings update path.

### Retention and persistence

The telemetry file contains three layers:

1. Request-level events for the newest 30 days, capped at 50,000 events.
2. Daily attempt aggregates for the newest 365 days, plus separate unscoped root-request aggregates for each local day and request category.
3. Compact lifetime attempt aggregates plus separate unscoped lifetime root-request aggregates.

Daily and lifetime attempt aggregates store mergeable counters, sums, completeness state, and fixed-boundary millisecond histograms. They may be grouped by account telemetry ID, provider, model, and request category.

Root-request terminal aggregates are separate and keyed only by local day and request category. They increment request count, success, retries, and account/model fallback counters exactly once. A request that starts on one account/model and succeeds on another remains one root request in this unscoped aggregate. Per-account and per-model reliability views use attempt error, 429, latency, token, and cost metrics; they do not claim root-request success or fallback attribution. Because root aggregates contain no account identifier, permanent account removal does not subtract their anonymous counts. The opt-in disclosure states this; `Clear Telemetry History…` removes them. Range queries merge both aggregate families, so 7-day, 30-day, and Lifetime metrics do not depend on retained request events.

Latency histograms use these inclusive upper bounds in milliseconds:

```text
0, 25, 50, 100, 200, 350, 500, 750, 1000, 1500, 2000, 3000,
5000, 7500, 10000, 15000, 20000, 30000, 45000, 60000, 90000,
120000, 180000, 300000, 600000, overflow
```

Negative, non-finite, and nonrepresentable values are omitted. Values above 600,000 ms enter `overflow`. Histograms merge by saturating addition of corresponding buckets. Percentiles use nearest rank: `ceil(percentile * sampleCount)`, then return the first inclusive bucket whose cumulative count reaches that rank. No interpolation is used. The UI renders the chosen finite bound with `≤` and renders the overflow result as `>10m`.

Retention rules:

- an event with `finishedAt < now - 30 days` is pruned; the boundary timestamp is retained;
- daily buckets older than the start of the local day 365 days ago are removed after the store confirms their contribution is already present in lifetime totals;
- lifetime totals remain until the owner clears telemetry or permanently removes the associated account;
- archive and restore retain all three layers;
- future-dated or malformed events are rejected during compaction;
- pruning runs on load, after insert, and once per day while the app is running;
- one atomic temp-file replacement commits an accepted event and its aggregates together;
- files and directories use permissions `0600` and `0700` respectively;
- when the cap is reached, the oldest request events are removed after their aggregate contribution is committed;
- the store records request-event coverage start and whether the 50,000-event cap truncated the nominal 30-day detail range. Aggregate metrics remain available, while any request-detail view reports the shorter coverage instead of claiming 30 complete days.

A `Clear Telemetry History…` action requires confirmation and clears request events, daily buckets, anonymous root aggregates, and lifetime telemetry totals. It does not clear provider quota windows. Permanent removal of any standalone or managed account purges request events and scoped attempt aggregates under its telemetry ID; anonymous root-request totals remain until the global clear action. No telemetry export is added in this release.

## Derived metrics

Every metric displays its selected range, sample count where relevant, and one of `complete`, `partial`, or `unknown`. Unknown fields do not contribute a zero.

### Capacity and forecasting

Operational capacity uses active accounts and fresh quota snapshots only:

- **Headroom:** `100 - usedPercent` for the five-hour and weekly windows.
- **Burn rate:** positive quota-percentage-point change divided by elapsed hours inside the same reset window.
- **Projected usage at reset:** `current usedPercent + burnPerHour * hoursUntilReset`, clamped to `0...100`.
- **Time to exhaustion:** `(100 - current usedPercent) / burnPerHour`, shown only for positive burn.
- **Forecast confidence:** low with fewer than three samples or less than 15 minutes of span; medium with at least three samples over 30 minutes; high with at least five samples over 60 minutes and no reset/decrease inside the span.

Forecasts are hidden below the existing meaningful-usage threshold and after a reset discontinuity. The dashboard may show a `Best available now` explanation based on eligibility, drain preference, headroom, and forecast, but it does not modify saved ranking.

Archived accounts show their last saved quota observation as historical, never as current headroom or a routing recommendation.

### Cache and token efficiency

- **Cache-hit rate:** `cached input tokens / input tokens` when cached-input completeness is not unknown.
- **Cache-write rate:** `cache-write input tokens / input tokens` when cache-write completeness is not unknown.
- **Fresh input:** `input - cached input - cache-write input`, clamped at zero.
- **Reasoning share:** `reasoning tokens / output tokens`, with reasoning treated as an output subset.
- **Estimated cache savings:** cached input multiplied by the difference between known uncached and cached input list prices.
- **Tokens per root request:** total observed tokens across all attempts divided by distinct root requests.

Partial token coverage produces a partial metric and explanatory caption. No ratio is shown with a zero denominator.

### Reliability and retry waste

- **Root-request success rate:** root requests with any successful terminal attempt divided by root requests with a terminal outcome. It is available overall and by request category, not by account or model.
- **Attempt error rate:** failed attempts divided by all terminal attempts.
- **429 rate:** rate-limited attempts divided by all terminal attempts.
- **Retry amplification:** all attempts divided by distinct root requests.
- **Retry waste tokens:** observed tokens on failed attempts.
- **Retry waste time:** summed duration of failed attempts.
- **Fallback frequency:** root requests that changed account or model after the first attempt divided by root requests. It is available overall and by request category.

Attempt metrics can be grouped by account, provider, model, and request category. Root-request metrics follow the unscoped attribution rule above. The dashboard never labels a necessary successful retry as waste; it reports failed-attempt cost and time separately from recovered requests.

### Latency

- Total latency is local wall-clock time from attempt dispatch through the completed response body.
- Time to first chunk is local wall-clock time from dispatch to the first streamed response body chunk.
- p50 appears with at least three valid samples.
- p95 appears with at least twenty valid samples.
- Streaming and non-streaming attempts are not mixed for time-to-first-chunk.
- Cancelled attempts are excluded from success latency and shown separately.

Percentiles are approximate values from documented fixed-boundary histograms, including Lifetime. The UI labels them `~p50` and `~p95`. These values include local and network time. They are not labeled server processing time.

### Trends and mix

The 7-day and 30-day ranges use daily buckets in the current local time zone. Lifetime uses compact totals and does not pretend to reconstruct missing daily history.

The dashboard shows:

- requests, attempts, tokens, cache reads/writes, estimated cost, errors, 429s, p50 latency, and p95 latency by day;
- request, token, and estimated-cost share by account and model;
- active and archived accounts as separate scopes;
- an explicit `Other` bucket for bounded-cardinality overflow.

Changing time zone affects future bucket assignment only. Stored dates keep their original local-day key and offset so prior totals do not silently move between days.

### Task Board outcomes

Task Board is the only surface with a defensible completion signal:

- **Completed:** run outcome is exactly `completed`.
- **Failed:** terminal outcome is `failed` or `invalid-complete`.
- **Stopped/cancelled:** reported separately and excluded from the success-rate denominator.
- **Completion rate:** completed divided by completed plus failed.
- **Run duration:** `finishedAt - startedAt` for terminal runs.
- **Tokens and estimated cost per completed run:** totals for completed runs only, with completeness and pricing provenance.
- **Retry and model-fallback frequency:** derived from recorded run attempts and fallback counters.

Interactive traffic receives no success score. A high token count, low cost, or fast response is not presented as quality or productivity.

## Usage Monitor information architecture

The existing window keeps its title and adds a range picker: `7 days`, `30 days`, `Lifetime`.

Sections appear in this order:

1. **Capacity:** active-account headroom, reset time, burn, forecast, and `Best available now` explanation.
2. **Efficiency:** fresh/cached/cache-write input, cache rates, reasoning share, tokens per request, and estimated cache savings.
3. **Reliability:** success, errors, 429s, retry amplification, failed-attempt tokens/time, and fallback frequency.
4. **Latency:** p50/p95 total latency and time to first chunk with sample counts.
5. **Trends:** compact daily charts for requests, tokens, estimated cost, errors, and latency.
6. **Accounts and models:** sortable share and comparison tables. Archived history is hidden by default behind `Include archived history`.
7. **Task Board:** completion rate, run duration, tokens/cost per completed run, retries, and model fallbacks.

When collection is off, the monitor keeps existing quota and historical usage views and shows a concise `Enable local metadata metrics` panel. The panel lists the stored categories, forbidden content, 30-day event retention, longer aggregate retention, and clear control before opt-in.

The footer states that telemetry is local and metadata-only, costs are estimates, latency includes local/network time, and interactive quality is not inferred. It also contains the opt-in telemetry setting and confirmed clear action.

Charts use Swift Charts available on the macOS 14 deployment target. Tables and accessibility labels expose the same values without requiring color or chart interpretation.

## Account settings and menu behavior

Account Settings contains two sections:

- **Accounts:** active roster only, including routing-paused accounts. Rank count excludes archived accounts.
- **Archived:** alias, ownership badge, archive date, last historical usage summary, and `Restore` action. It contains no routing, warm-up, reset, quota-refresh, or rank controls.

The account card adds `Archive…` with confirmation. CodexBar-managed cards keep `Manage in CodexBar`; archive does not replace or invoke it. Standalone cards keep the distinct permanent `Remove…` action.

The menu bar omits archived accounts from ranked and paused rows. If archives exist, it adds a compact `Archived Accounts (N)` item that opens Account Settings without exposing credentials or stale quota as live.

## Observable contract

```gherkin
Feature: Compact quota reset presentation

  Rule: Five-hour windows show time while longer windows stay unambiguous

    Scenario: A future five-hour window is rendered
      Given a fixed current time, locale, and time zone
      When a five-hour reset is displayed in the app or human CLI
      Then the caption contains the localized reset time
      And it contains no calendar date

    Scenario: A future weekly window is rendered
      Given a fixed current time, locale, and time zone
      When a weekly reset is displayed
      Then the caption contains a localized date and time

Feature: Local account archive

  Rule: Archive removes operational behavior without deleting ownership or history

    Scenario: A CodexBar-managed account is archived
      Given the account has credentials, saved preferences, quota history, and telemetry
      When the owner confirms Archive
      Then the account leaves ranking, routing, automation, warm-up, quota polling, and active pool summaries
      And its credentials, managed-home ownership, preferences, and historical usage remain stored
      And no CodexBar or OAuth file is changed

    Scenario: An archived account is restored
      Given an archived account with retained history
      When the owner restores it
      Then it returns at the bottom of the active ranking with routing paused
      And its history and saved preferences remain intact
      And it cannot route until the owner enables routing

    Scenario: CodexBar imports an archived account again
      Given an archived managed account receives refreshed imported credentials
      When CodexSwap performs its periodic upsert
      Then the archive and pause timestamps remain unchanged
      And the account remains excluded from active behavior

  Rule: Paused inactivity archives only after seven full days

    Scenario: A paused account reaches its archive deadline
      Given routing was paused at a fixed time
      And no later CodexSwap-routed attempt touched the account
      When the clock reaches exactly seven days after the pause
      Then CodexSwap archives the account before quota network work

    Scenario: Passive observation does not postpone archival
      Given a paused account is approaching its archive deadline
      When CodexSwap opens settings, imports it, scans logs, or refreshes quota metadata
      Then its pause deadline is unchanged

    Scenario: A legacy paused account is migrated
      Given its stored record has no routing-pause timestamp
      When the new store first loads it
      Then the migration time becomes its pause timestamp
      And it receives a full seven-day grace period

Feature: Metadata-only usage telemetry

  Rule: Analytics never persist model interaction content

    Scenario: A request and response contain sensitive-looking text
      When CodexSwap records successful, failed, and retried attempts
      Then the telemetry file contains only allowlisted metadata fields
      And it contains no prompt, response, command, path, header, request body, raw error, or provider request ID

    Scenario: Request-level retention crosses thirty days
      Given request events before, at, and after the retention cutoff
      When telemetry compaction runs
      Then events before the cutoff are removed
      And the boundary and newer events remain
      And their committed daily and lifetime aggregates are not double-counted

    Scenario: The owner has not enabled metadata telemetry
      Given CodexSwap is newly installed or migrated from an older version
      When model requests pass through the proxy
      Then no metadata event is persisted
      And the Usage Monitor offers an informed local opt-in

    Scenario: The owner enables metadata telemetry
      Given metadata telemetry is disabled
      When the owner reviews the disclosure, enables collection, and routes a completed request
      Then the setting persists across restart
      And one allowlisted root request and its upstream attempts are recorded
      And no model interaction content is stored

    Scenario: A request retries across accounts and models
      Given one root request fails on one account and succeeds on another model and account
      When CodexSwap updates daily and lifetime aggregates
      Then it counts one root request in the request-category aggregate
      And it counts each attempt in its own account and model aggregate
      And it does not attribute root-request success to both accounts

    Scenario: A managed account is removed externally
      Given telemetry exists under the account's random telemetry identifier
      When CodexBar reconciliation permanently removes the account
      Then CodexSwap purges request events and scoped daily and lifetime attempt telemetry for that identifier
      And anonymous root-request totals remain without an account identifier until the owner clears all telemetry

    Scenario: A migrated telemetry identifier survives restart and removal
      Given a legacy account has no telemetry identifier
      When CodexSwap migrates, restarts, and imports the same account again
      Then one generated identifier is persisted and preserved across each load
      And permanent removal purges every scoped telemetry row under that identifier

  Rule: Derived metrics expose uncertainty

    Scenario: Cache fields are absent from some attempts
      When the dashboard computes cache rate and estimated cost
      Then it marks the result partial or unknown
      And it never treats missing cache values as zero

    Scenario: Latency has too few samples
      When fewer than twenty successful samples exist
      Then p95 is withheld with its sample requirement

Feature: Reliable Smart Switch preference

  Rule: Drain preference applies inside every automatic selection strategy

    Scenario Outline: A non-draining account is active and another eligible account is draining
      Given Smart Switch is enabled with <strategy> selection
      When CodexSwap performs <selection>
      Then it selects the draining account

      Examples:
        | strategy    | selection             |
        | ranking     | current routing       |
        | round-robin | current routing       |
        | round-robin | new-turn advance      |
        | round-robin | quota rotation        |
        | round-robin | login recovery        |
        | ranking     | Task Board start      |
        | round-robin | Task Board start      |

    Scenario: A restricted usage poll inspects one account
      Given another account has a valid unexpired drain observation
      When a task-specific poll assesses only the first account
      Then the unpolled account keeps its drain observation

    Scenario: A hard-pinned account remains valid
      Given a Task Board run has an eligible hard pin
      And another account is marked draining
      When the pinned turn continues
      Then CodexSwap keeps the hard pin

    Scenario: A paused account is due for archive while a task holds its routing lease
      When automatic archive runs
      Then CodexSwap defers archive without extending the persisted pause timestamp
      And it archives on the first tick after the lease ends

    Scenario: A quota window resets
      Given an account has a current drain observation
      When the reset timestamp changes or used percent decreases
      Then CodexSwap clears the observation
      And the new reading becomes a fresh baseline

    Scenario: A draining account is archived
      Given an account has a current drain observation
      When it is archived
      Then the observation is cleared
      And no automatic selector can return the account
```

## Implementation map

- `Account.swift`: archive and pause timestamps, random telemetry identifier, archive eligibility invariant, Codable defaults.
- `AccountStore.swift`: migration, active/archive reads, archive/restore, active-only dense ranking, drain-aware strategy helpers, routed-use stamping, and autoarchive transaction.
- `AppEngine.swift`: archive actions, periodic autoarchive, active-only polling/scanning/reset/warm-up/task plumbing, Smart Switch toggle refresh, and telemetry snapshots.
- `SmartSwitchPolicy.swift`: same-window baseline attribution, dynamic lookback, deterministic drain-group ordering, reset detection, and observation expiry semantics.
- `ProxyServer.swift`: root/attempt IDs, safe attempt telemetry, first-chunk timing, retry linkage, consistent routed-use stamps, and drain-aware automatic selection.
- `CodexEventDecoder.swift` and `AutomationTask.swift`: reasoning-token completeness and bounded Task Board outcome inputs without copying content into telemetry.
- `Settings.swift`: persisted opt-in field with false defaults for new and migrated settings.
- New `UsageTelemetry.swift`: event schema, actor store, exact histograms, separate attempt/root aggregates, retention, formulas, and crash-safe persistence.
- `UsageAnalytics.swift`: range-aware derived views and active-versus-archived scopes.
- `AccountsSettingsView.swift`, `SettingsPresentation.swift`, `AppDelegate.swift`, and `MenuAccountRow.swift`: archive/restore surfaces and active-only presentation.
- `UsageMonitorWindow.swift`: range control, metrics, charts, scope controls, privacy copy, and clear action.
- `README.md`, `PRIVACY.md`, and `SECURITY.md`: replace the absolute no-telemetry claim with the exact opt-in, local-only metadata contract and retention controls while preserving the no-upload promise.
- `swapd/main.swift`, `QuotaReport.swift`, and `CodexBarQuotaClient.swift`: active-only human reports and no global prefetch when archives exist.
- New shared reset-presentation helper used by app and CLI.

## Verification gates

- RED-to-GREEN deterministic tests for reset formatting across locale, time zone, DST, missing, and expired states.
- RED-to-GREEN Codable migration, generate-once telemetry ID persistence, restart/re-import preservation, removal purge, manual archive, restore, idempotency, active-only ranking, and exact seven-day boundary tests.
- Zero-call spies for every archived quota, reset, warm-up, log-scan, Task Board, and CodexBar-prefetch path.
- RED-to-GREEN Smart Switch tests for every row in the scenario outline, restricted-poll merge, fetch failure retention, observation expiry, archive interaction, and explicit pin exemptions.
- Telemetry schema allowlist tests with malicious content-shaped inputs; no forbidden string may appear in serialized output.
- Retention boundary, event-cap, idempotency, future-date, overflow, partial-completeness, percentile-threshold, and aggregate-consistency tests.
- Task Board outcome tests that exclude stopped runs and never infer interactive success.
- Focused UI presentation tests for active/archive sections, range selection, archived-history opt-in, metric disclaimers, and accessibility values.
- Existing quota, routing, proxy retry, Alpha bridge, Task Board, settings, and usage suites remain green.
- Full Swift test suite, release build, `git diff --check`, secret scan, code-sign verification, independent frozen-diff correctness/privacy review, packaged install, and live listener verification before release.

## Research basis

- [OpenAI Responses usage schema](https://developers.openai.com/api/reference/cli/resources/responses/methods/retrieve) documents input, cached-input, cache-write, output, and reasoning-token details.
- [OpenAI model guidance](https://developers.openai.com/api/docs/guides/latest-model) distinguishes cache-read and cache-write accounting.
- [OpenTelemetry GenAI metrics](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-metrics.md) defines token usage, operation duration, time to first chunk, model/provider dimensions, and bounded error type.
- [ccusage JSON output](https://github.com/ccusage/ccusage/blob/main/docs/guide/json-output.md) demonstrates daily, session, model, cache, burn-rate, and projected-usage views.
- [LangSmith dashboards](https://docs.langchain.com/langsmith/dashboards) and [cost tracking](https://docs.langchain.com/langsmith/cost-tracking) use trace/run counts, errors, latency, token types, and estimated cost.
- [GitHub Copilot usage metrics](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics) shows why acceptance metrics need both exposure and accepted-event denominators.
- [WakaTime's developer API](https://wakatime.com/developers) exposes activity signals, but those signals are intentionally excluded from CodexSwap's productivity claims.
- [CodexBar's usage formatter](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/UsageFormatter.swift) and [CLI documentation](https://github.com/steipete/CodexBar/blob/main/docs/cli.md) informed reset-display and quota-prefetch compatibility boundaries.
