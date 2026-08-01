#!/bin/bash
set -euo pipefail

candidates=(
  "/Applications/CodexSwap.app/Contents/MacOS/swapd"
  "/Users/vjmabansag/Projects/CodexSwap/.build/release/swapd"
  "/Users/vjmabansag/Projects/CodexSwap/.build/debug/swapd"
)

for binary in "${candidates[@]}"; do
  [[ -x "$binary" ]] || continue

  if output="$("$binary" quota --json 2>/dev/null)"; then
    if normalized="$(
      printf '%s\n' "$output" | /usr/bin/python3 -c '
import json
import re
import sys
from datetime import datetime

TOP_ALLOWED = {"schemaVersion", "fetchedAt", "accounts"}
TOP_REQUIRED = TOP_ALLOWED
ACCOUNT_ALLOWED = {
    "alias",
    "plan",
    "state",
    "usageStatus",
    "windows",
    "resetCreditStatus",
    "availableResetCredits",
    "earliestResetCreditExpiry",
}
ACCOUNT_REQUIRED = {"alias", "state", "usageStatus", "windows", "resetCreditStatus"}
WINDOW_ALLOWED = {"label", "usedPercent", "remainingPercent", "resetAt"}
WINDOW_REQUIRED = {"label", "usedPercent", "remainingPercent"}
WINDOW_LABELS = {"5h", "Weekly"}
FORBIDDEN_KEY = re.compile(r"email|token|accountid|creditid|authorization|bearer", re.IGNORECASE)
FORBIDDEN_VALUE = re.compile(
    r"email|token|account[\s_-]*id|credit[\s_-]*id|authorization|bearer",
    re.IGNORECASE,
)
EMAIL_VALUE = re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+")


def reject(_message="invalid quota report"):
    raise ValueError(_message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            reject()
        result[key] = value
    return result


def parse_constant(_value):
    reject()


def validate_keys(value, allowed, required):
    if not isinstance(value, dict):
        reject()
    for key in value:
        if FORBIDDEN_KEY.search(key) or key not in allowed:
            reject()
    if not required.issubset(value):
        reject()


def optional_string(value):
    if value is None:
        return
    if not isinstance(value, str):
        reject()
    if FORBIDDEN_VALUE.search(value) or EMAIL_VALUE.search(value):
        reject()


def display_string(value, maximum):
    if not isinstance(value, str) or not 1 <= len(value) <= maximum:
        reject()
    optional_string(value)
    if any(not (character.isalnum() or character in " ._+-") for character in value):
        reject()


def require_timestamp(value):
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
        require_timestamp(value)


try:
    report = json.load(
        sys.stdin,
        object_pairs_hook=unique_object,
        parse_constant=parse_constant,
    )
    validate_keys(report, TOP_ALLOWED, TOP_REQUIRED)
    if type(report["schemaVersion"]) is not int or report["schemaVersion"] != 1:
        reject()
    require_timestamp(report["fetchedAt"])
    accounts = report["accounts"]
    if not isinstance(accounts, list):
        reject()

    aliases = set()
    for account in accounts:
        validate_keys(account, ACCOUNT_ALLOWED, ACCOUNT_REQUIRED)
        alias = account["alias"]
        if not isinstance(alias, str) or alias in aliases:
            reject()
        display_string(alias, 64)
        aliases.add(alias)

        plan = account.get("plan")
        if plan is not None:
            display_string(plan, 32)
        if account["state"] not in {"active", "available", "paused", "signInRequired"}:
            reject()
        usage_status = account["usageStatus"]
        if usage_status not in {
            "ok",
            "signInRequired",
            "unauthorized",
            "timeout",
            "network",
            "serviceError",
            "malformedResponse",
        }:
            reject()
        reset_credit_status = account["resetCreditStatus"]
        if reset_credit_status not in {
            "ok",
            "signInRequired",
            "unauthorized",
            "timeout",
            "network",
            "serviceError",
            "malformedResponse",
        }:
            reject()

        windows = account["windows"]
        if not isinstance(windows, list):
            reject()
        if usage_status == "ok" and not windows:
            reject()
        if usage_status != "ok" and windows:
            reject()
        labels = set()
        for window in windows:
            validate_keys(window, WINDOW_ALLOWED, WINDOW_REQUIRED)
            if not isinstance(window["label"], str):
                reject()
            optional_string(window["label"])
            label = window["label"]
            if label not in WINDOW_LABELS or label in labels:
                reject()
            labels.add(label)
            for field in ("usedPercent", "remainingPercent"):
                value = window[field]
                if type(value) is not int or not 0 <= value <= 100:
                    reject()
            if window["remainingPercent"] != max(0, 100 - window["usedPercent"]):
                reject()
            optional_timestamp(window.get("resetAt"))

        credits_present = "availableResetCredits" in account
        credits = account.get("availableResetCredits")
        expiry = account.get("earliestResetCreditExpiry")
        optional_timestamp(expiry)
        if reset_credit_status == "ok":
            if not credits_present or type(credits) is not int or credits < 0:
                reject()
            if credits == 0 and expiry is not None:
                reject()
        elif credits is not None or expiry is not None:
            reject()

        if account["state"] == "signInRequired":
            if (
                usage_status != "signInRequired"
                or reset_credit_status != "signInRequired"
                or windows
                or credits is not None
                or expiry is not None
            ):
                reject()

    json.dump(report, sys.stdout, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
except (ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)
sys.stdout.write("\n")
'
    )"; then
      printf '%s\n' "$normalized"
      exit 0
    fi
  fi
done

printf '%s\n' "No compatible CodexSwap quota command was found. Build or update CodexSwap first." >&2
exit 1
