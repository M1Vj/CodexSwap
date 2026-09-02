# Routing decision log

CodexSwap keeps a small, local-only JSONL record of proxy routing decisions so
429 failover can be diagnosed without retaining request content. The log is
always on; it is independent of the optional metadata telemetry setting.

## Location and retention

The active file is:

`~/Library/Application Support/CodexSwap/routing-decisions-v1.jsonl`

The directory is mode `0700` and the active and rotated files are mode `0600`.
The active file is capped at 1 MiB. When it would exceed that cap, it is moved
to `routing-decisions-v1.jsonl.1`; only that one rotated file is retained.
Each append is followed by a file synchronization before the handle closes.
The hidden `.routing-decisions-v1.jsonl.lock` file is a `0600` interprocess
lock sentinel, not event data and not part of the retained JSONL files.

## Safe fields

Every line is one JSON object with schema version `1`, an ISO-8601 UTC
`timestamp`, an `event`, and a `rootRequestID`. Other fields are closed enums,
bounded attempt/count/status values, a bounded Retry-After delay, and random
account telemetry UUIDs when available. The logger does not accept or persist
prompts, responses, provider headers/bodies/errors, aliases, emails, session
identifiers, account IDs, or tokens.

## Read-only inspection

Inspection should not modify or truncate the files. For example:

```sh
LOG="$HOME/Library/Application Support/CodexSwap/routing-decisions-v1.jsonl"
sed -n '1,120p' "$LOG"
sed -n '1,120p' "$LOG.1"
```

Treat the UUIDs and timestamps as local diagnostic metadata. Sanitize any
excerpt before sharing it outside the device.
