#!/usr/bin/env bash
set -euo pipefail

candidates=()
if [[ -n "${CODEXSWAP_QUOTA_BINARY:-}" ]]; then
  candidates+=("$CODEXSWAP_QUOTA_BINARY")
fi
candidates+=(
  "/Applications/CodexSwap.app/Contents/MacOS/swapd"
  "/Users/vjmabansag/Projects/CodexSwap/.build/release/swapd"
  "/Users/vjmabansag/Projects/CodexSwap/.build/debug/swapd"
)

for binary in "${candidates[@]}"; do
  [[ -x "$binary" ]] || continue

  if output="$("$binary" quota --json 2>/dev/null)"; then
    if normalized="$(
      printf '%s\n' "$output" | python3 -c '
import json
import re
import sys

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


try:
    report = json.load(
        sys.stdin,
        object_pairs_hook=unique_object,
        parse_constant=parse_constant,
    )
    validate_keys(report, TOP_ALLOWED, TOP_REQUIRED)
    if type(report["schemaVersion"]) is not int or report["schemaVersion"] != 1:
        reject()
    if not isinstance(report["fetchedAt"], str):
        reject()
    optional_string(report["fetchedAt"])
    accounts = report["accounts"]
    if not isinstance(accounts, list):
        reject()

    aliases = set()
    for account in accounts:
        validate_keys(account, ACCOUNT_ALLOWED, ACCOUNT_REQUIRED)
        alias = account["alias"]
        if not isinstance(alias, str) or alias in aliases:
            reject()
        optional_string(alias)
        aliases.add(alias)

        optional_string(account.get("plan"))
        if account["state"] not in {"active", "available", "paused", "signInRequired"}:
            reject()
        if account["usageStatus"] not in {
            "ok",
            "signInRequired",
            "unauthorized",
            "timeout",
            "network",
            "serviceError",
            "malformedResponse",
        }:
            reject()
        if account["resetCreditStatus"] not in {
            "ok",
            "signInRequired",
            "unauthorized",
            "timeout",
            "network",
            "serviceError",
            "malformedResponse",
        }:
            reject()

        credits = account.get("availableResetCredits")
        if credits is not None and (type(credits) is not int or credits < 0):
            reject()
        optional_string(account.get("earliestResetCreditExpiry"))

        windows = account["windows"]
        if not isinstance(windows, list):
            reject()
        for window in windows:
            validate_keys(window, WINDOW_ALLOWED, WINDOW_REQUIRED)
            if not isinstance(window["label"], str):
                reject()
            optional_string(window["label"])
            for field in ("usedPercent", "remainingPercent"):
                value = window[field]
                if type(value) is not int:
                    reject()
            optional_string(window.get("resetAt"))

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
