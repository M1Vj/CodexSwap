# Diagnostics

Open **Diagnostics…** from the menu bar, or **Settings → Diagnostics**. The
timeline refreshes every three seconds while visible. Filter by component and
severity, then search a correlation ID to follow a request or operation.

## What is recorded

| Area | Operation boundaries |
| --- | --- |
| App | Startup, shutdown, wake, network availability, notification results |
| Proxy and routing | Upstream attempts, status, retries, selection, authentication recovery, terminal decisions |
| Accounts | Import and verified recovery outcomes, persistence failures |
| Quota | Usage fetches, reset attempts, eligibility skips and results |
| Warmup | Run and attempt starts, busy/offline skips, duration and results |
| Tasks | Launch, queue/run events, cancellation, timeout, stall and exit |
| Alpha | Bridge request lifecycle and failures |
| Settings and storage | Configuration changes, save failures and corrupt task data |

Records use a closed schema: timestamp, process-session UUID, component,
operation, outcome, severity, error category, and optional correlation UUID,
  HTTP status, duration and count. Error categories deliberately replace raw
provider messages. A launcher starting successfully does not mean an account
has signed in; a request failure does not by itself prove credential revocation.

## Exporting an incident

1. Note the time and action that failed.
2. Open Diagnostics and filter the relevant component or warning/error level.
3. Copy the correlation ID, if present, to find related records.
4. Choose **Export Diagnostics** and select the destination yourself.

The display contains the latest 500 matching records. Export includes up to
2,000 recent records across all components, not just the current UI filter.
For local automation, the sanitized CLI returns up to 500 records:

```sh
/Applications/CodexSwap.app/Contents/MacOS/swapd agent diagnostics --json
```

Exports contain structured diagnostics only. They do not bundle account stores,
credentials, prompts, response bodies, paths, environment values, task output,
or the older automation log. Nothing is uploaded automatically. Export files
are created with owner-only permissions; review them before sharing.

## Retention and limits

The local store is `diagnostics-v1.jsonl` in CodexSwap's Application Support
directory, with three rotated segments. Each segment is capped at 2 MiB,
for an 8 MiB total. Old events expire through rotation, not an unbounded archive.
Files are private to the local owner. Unsafe or malformed input is rejected.
The size cap applies to files produced by the logger. Externally enlarged or
corrupt files are read only within fixed bounds and reported, not automatically
deleted or repaired.

The UI reports read/write failures, dropped events and truncated results.
Health counters belong to the logger instance in the current process: they do
not survive restart, and a separate CLI process cannot report the app's
in-memory failure counters. A busy writer can drop an event rather than stall
traffic. Logging is best-effort, not an audit guarantee: a crash, forced quit,
disk failure or unavailable filesystem can prevent the final event from being
saved. A missing event is not proof that an operation did not happen.

A successful warmup command means the command completed. It is not proof that
a quota window advanced; subsequent usage observations determine verification.

Existing task output and the legacy automation log remain separate. Do not
share those files as if they had the structured export's privacy guarantees.
Diagnostics starts recording when this version runs; it cannot reconstruct
older incidents or explain a provider-side revocation without provider evidence.
