#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/../../.." && pwd -P)"

warm_binary=""
warm_candidates=(
  "/Applications/CodexSwap.app/Contents/MacOS/swapd"
  "$HOME/Applications/CodexSwap.app/Contents/MacOS/swapd"
  "$repo_root/.build/release/swapd"
  "$repo_root/.build/debug/swapd"
)
for candidate in "${warm_candidates[@]}"; do
  if [[ -x "$candidate" ]]; then
    warm_binary="$candidate"
    break
  fi
done

if [[ -z "$warm_binary" ]]; then
  printf '%s\n' "No compatible CodexSwap warm-up command was found. Build or update CodexSwap first." >&2
  exit 1
fi

tmp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codexswap-warm-and-check.XXXXXX")"
trap '/bin/rm -rf "$tmp_dir"' EXIT
warm_file="$tmp_dir/warmup.json"
quota_file="$tmp_dir/quota.json"

if ! "$warm_binary" warmup --all --json >"$warm_file" 2>/dev/null; then
  printf '%s\n' "CodexSwap warm-up failed. Open CodexSwap and try again." >&2
  exit 1
fi

if ! /bin/bash "$script_dir/check-quotas.sh" >"$quota_file" 2>/dev/null; then
  printf '%s\n' "CodexSwap quota check failed after warm-up. Try again." >&2
  exit 1
fi

if ! /usr/bin/python3 - "$warm_file" "$quota_file" <<'PY'
import json
import re
import sys
from datetime import datetime

WARM_ALLOWED_STATUS = {
    "warmed",
    "skippedProxyUnavailable",
    "skippedRoutingDisabled",
    "skippedExcluded",
    "skippedNeedsLogin",
    "skippedMissingCredentials",
    "skippedCooldown",
    "skippedAlreadyRunning",
    "skipped",
    "failed",
}
WARM_TOP_ALLOWED = {"schemaVersion", "status", "startedAt", "finishedAt", "accounts", "counts"}
WARM_ACCOUNT_ALLOWED = {"alias", "status"}
WARM_COUNTS_ALLOWED = {"total", "warmed", "skipped", "failed"}
QUOTA_TOP_ALLOWED = {"schemaVersion", "fetchedAt", "accounts"}
QUOTA_ACCOUNT_ALLOWED = {
    "alias",
    "plan",
    "state",
    "usageStatus",
    "windows",
    "resetCreditStatus",
    "availableResetCredits",
    "earliestResetCreditExpiry",
}
QUOTA_ACCOUNT_REQUIRED = {"alias", "state", "usageStatus", "windows", "resetCreditStatus"}
WINDOW_ALLOWED = {"label", "usedPercent", "remainingPercent", "resetAt"}
WINDOW_REQUIRED = {"label", "usedPercent", "remainingPercent"}
WINDOW_LABELS = {"5h", "Weekly", "30d"}
QUOTA_STATES = {"active", "available", "paused", "signInRequired"}
LOOKUP_STATUSES = {
    "ok",
    "signInRequired",
    "unauthorized",
    "timeout",
    "network",
    "serviceError",
    "malformedResponse",
}
FORBIDDEN_KEY = re.compile(r"email|token|accountid|creditid|authorization|bearer", re.IGNORECASE)
FORBIDDEN_VALUE = re.compile(r"email|token|account[\s_-]*id|credit[\s_-]*id|authorization|bearer", re.IGNORECASE)
EMAIL_VALUE = re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+")


def reject():
    raise ValueError("invalid report")


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            reject()
        value[key] = item
    return value


def parse_constant(_value):
    reject()


def read(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle, object_pairs_hook=unique_object, parse_constant=parse_constant)


def keys(value, allowed, required=None):
    if not isinstance(value, dict) or any(FORBIDDEN_KEY.search(str(key)) for key in value):
        reject()
    if set(value) - allowed:
        reject()
    if required is not None and not required.issubset(value):
        reject()


def optional_string(value):
    if value is None:
        return
    if not isinstance(value, str) or FORBIDDEN_VALUE.search(value) or EMAIL_VALUE.search(value):
        reject()


def safe_alias(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 64:
        reject()
    optional_string(value)
    if any(not (character.isalnum() or character in " ._+-") for character in value):
        reject()


def timestamp(value):
    if not isinstance(value, str):
        reject()
    optional_string(value)
    normalized = value[:-1] + "+00:00" if value.endswith(("Z", "z")) else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except (TypeError, ValueError):
        reject()
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        reject()


def optional_timestamp(value):
    if value is not None:
        timestamp(value)


def validate_warm(report):
    keys(report, WARM_TOP_ALLOWED, WARM_TOP_ALLOWED)
    if type(report["schemaVersion"]) is not int or report["schemaVersion"] != 1:
        reject()
    if report["status"] not in {"ok", "proxyUnavailable", "failed"}:
        reject()
    timestamp(report["startedAt"])
    timestamp(report["finishedAt"])

    accounts = report["accounts"]
    if not isinstance(accounts, list):
        reject()
    aliases = set()
    status_counts = {"warmed": 0, "failed": 0}
    for account in accounts:
        keys(account, WARM_ACCOUNT_ALLOWED, WARM_ACCOUNT_ALLOWED)
        safe_alias(account["alias"])
        if account["alias"].lower() in aliases:
            reject()
        aliases.add(account["alias"].lower())
        if account["status"] not in WARM_ALLOWED_STATUS:
            reject()
        if account["status"] in status_counts:
            status_counts[account["status"]] += 1

    counts = report["counts"]
    keys(counts, WARM_COUNTS_ALLOWED, WARM_COUNTS_ALLOWED)
    for field in WARM_COUNTS_ALLOWED:
        if type(counts[field]) is not int or counts[field] < 0:
            reject()
    if counts["total"] != len(accounts):
        reject()
    if counts["warmed"] != status_counts["warmed"] or counts["failed"] != status_counts["failed"]:
        reject()
    if counts["skipped"] != counts["total"] - counts["warmed"] - counts["failed"]:
        reject()


def validate_quota(report):
    keys(report, QUOTA_TOP_ALLOWED, QUOTA_TOP_ALLOWED)
    if type(report["schemaVersion"]) is not int or report["schemaVersion"] != 1:
        reject()
    timestamp(report["fetchedAt"])
    accounts = report["accounts"]
    if not isinstance(accounts, list):
        reject()

    aliases = set()
    for account in accounts:
        keys(account, QUOTA_ACCOUNT_ALLOWED, QUOTA_ACCOUNT_REQUIRED)
        safe_alias(account["alias"])
        if account["alias"].lower() in aliases:
            reject()
        aliases.add(account["alias"].lower())
        plan = account.get("plan")
        if plan is not None:
            safe_alias(plan)
        if account["state"] not in QUOTA_STATES:
            reject()
        if account["usageStatus"] not in LOOKUP_STATUSES or account["resetCreditStatus"] not in LOOKUP_STATUSES:
            reject()

        windows = account["windows"]
        if not isinstance(windows, list):
            reject()
        if account["usageStatus"] == "ok" and not windows:
            reject()
        if account["usageStatus"] != "ok" and windows:
            reject()
        labels = set()
        for window in windows:
            keys(window, WINDOW_ALLOWED, WINDOW_REQUIRED)
            if window["label"] not in WINDOW_LABELS or window["label"] in labels:
                reject()
            labels.add(window["label"])
            for field in ("usedPercent", "remainingPercent"):
                if type(window[field]) is not int or not 0 <= window[field] <= 100:
                    reject()
            if window["remainingPercent"] != max(0, 100 - window["usedPercent"]):
                reject()
            optional_timestamp(window.get("resetAt"))

        credits_present = "availableResetCredits" in account
        credits = account.get("availableResetCredits")
        expiry = account.get("earliestResetCreditExpiry")
        optional_timestamp(expiry)
        if account["resetCreditStatus"] == "ok":
            if not credits_present or type(credits) is not int or credits < 0:
                reject()
            if credits == 0 and expiry is not None:
                reject()
        elif credits is not None or expiry is not None:
            reject()

        if account["state"] == "signInRequired":
            if (
                account["usageStatus"] != "signInRequired"
                or account["resetCreditStatus"] != "signInRequired"
                or windows
                or credits is not None
                or expiry is not None
            ):
                reject()


try:
    warm = read(sys.argv[1])
    quota = read(sys.argv[2])
    validate_warm(warm)
    validate_quota(quota)
    json.dump(
        {"schemaVersion": 1, "warmup": warm, "quota": quota},
        sys.stdout,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    sys.stdout.write("\n")
except Exception:
    raise SystemExit(1)
PY
then
  printf '%s\n' "CodexSwap warm-up or quota output was invalid. Build or update CodexSwap first." >&2
  exit 1
fi
