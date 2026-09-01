#!/usr/bin/env python3
"""Reset-aware CodexSwap warm-up monitor.

This monitor is deliberately outside the app's account store.  It reads only
the sanitized ``swapd agent`` JSON surface, remembers opaque account refs and
reset fingerprints, and asks for a warm-up only after a reset transition has
been observed.  It is safe to invoke once from launchd (the default) or to
run continuously with ``--watch``.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as _datetime
import fcntl
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable, Mapping, Optional


SCHEMA_VERSION = 1
MAX_JSON_BYTES = 1_000_000
DEFAULT_INTERVAL_SECONDS = 60.0
DEFAULT_COOLDOWN_SECONDS = 900.0
DEFAULT_COMMAND_TIMEOUT_SECONDS = 30.0
DEFAULT_WARMUP_TIMEOUT_SECONDS = 180.0

EXIT_OK = 0
EXIT_USAGE = 64
EXIT_DATA = 65
EXIT_UNAVAILABLE = 69
EXIT_TEMPORARY = 75

REF_PATTERN = re.compile(r"^acct-[0-9a-f]{16}$")
WINDOW_PATTERN = re.compile(r"^Window [1-9][0-9]{0,2}$")
EMAIL_PATTERN = re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+")
SENSITIVE_KEY_PATTERN = re.compile(
    r"(?:email|token|account[\s_-]*id|credit[\s_-]*id|authorization|bearer|"
    r"managed[\s_-]*home|telemetry)",
    re.IGNORECASE,
)
SENSITIVE_VALUE_PATTERN = re.compile(
    r"(?:email|refresh[\s_-]*token|access[\s_-]*token|account[\s_-]*id|"
    r"credit[\s_-]*id|authorization|bearer)",
    re.IGNORECASE,
)

ALLOWED_ENVELOPE_KEYS = {"schemaVersion", "command", "ok", "data", "warnings", "error"}
ALLOWED_DATA_KEYS = {"schemaVersion", "fetchedAt", "accounts"}
ALLOWED_ACCOUNT_KEYS = {
    "alias",
    "ref",
    "plan",
    "state",
    "usageStatus",
    "resetCreditStatus",
    "windows",
    "availableResetCredits",
    "earliestResetCreditExpiry",
}
ALLOWED_WINDOW_KEYS = {"label", "usedPercent", "remainingPercent", "resetAt"}
ALLOWED_STATUS_KEYS = {"schemaVersion", "command", "ok", "data", "warnings", "error"}
ALLOWED_STATE_KEYS = {
    "schemaVersion",
    "accounts",
    "lastPollAt",
    "lastWarmAt",
    "lastWarmStatus",
    "nextAttemptAfter",
}
ALLOWED_STATE_ACCOUNT_KEYS = {
    "label",
    "resetAt",
    "usedPercent",
    "observedAt",
    "pendingFingerprint",
    "pendingObservedAt",
    "lastWarmFingerprint",
    "lastWarmAt",
}
SAFE_WARM_STATUSES = {
    "warmed",
    "wouldWarm",
    "skipped",
    "skippedProxyUnavailable",
    "skippedRoutingDisabled",
    "skippedExcluded",
    "skippedNeedsLogin",
    "skippedMissingCredentials",
    "skippedCooldown",
    "skippedAlreadyRunning",
    "failed",
}


class MonitorError(Exception):
    """A safe, non-sensitive monitor failure."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


@dataclasses.dataclass(frozen=True)
class WindowSnapshot:
    label: str
    used_percent: int
    reset_at: Optional[_datetime.datetime]


@dataclasses.dataclass(frozen=True)
class AccountSnapshot:
    ref: str
    state: str
    usage_status: str
    window: Optional[WindowSnapshot]


@dataclasses.dataclass(frozen=True)
class CommandResponse:
    return_code: int
    payload: Optional[Mapping[str, Any]]
    failure: Optional[str] = None


def _reject_sensitive(value: Any, key: Optional[str] = None, depth: int = 0) -> None:
    """Reject untrusted report content that could carry private data."""

    if depth > 10:
        raise MonitorError("report_too_deep")
    if key is not None and SENSITIVE_KEY_PATTERN.search(key):
        raise MonitorError("report_contains_sensitive_field")
    if isinstance(value, str):
        if any(ord(character) < 0x20 and character not in "\t\n\r" for character in value):
            raise MonitorError("report_contains_control_character")
        if EMAIL_PATTERN.search(value) or SENSITIVE_VALUE_PATTERN.search(value):
            raise MonitorError("report_contains_sensitive_value")
        return
    if isinstance(value, Mapping):
        for child_key, child_value in value.items():
            if not isinstance(child_key, str):
                raise MonitorError("report_contains_invalid_key")
            _reject_sensitive(child_value, child_key, depth + 1)
    elif isinstance(value, list):
        for child in value:
            _reject_sensitive(child, depth=depth + 1)


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise MonitorError("duplicate_report_key")
        value[key] = item
    return value


def _reject_json_constant(_value: str) -> None:
    raise MonitorError("invalid_report_number")


def decode_json(data: str) -> Any:
    if len(data.encode("utf-8", errors="replace")) > MAX_JSON_BYTES:
        raise MonitorError("report_too_large")
    try:
        value = json.loads(
            data,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
    except MonitorError:
        raise
    except (TypeError, ValueError, json.JSONDecodeError) as error:
        del error
        raise MonitorError("malformed_json") from None
    _reject_sensitive(value)
    return value


def _require_keys(value: Mapping[str, Any], allowed: set[str], required: set[str]) -> None:
    if set(value) - allowed or not required.issubset(value):
        raise MonitorError("unexpected_report_shape")


def parse_timestamp(value: Any, *, required: bool = True) -> Optional[_datetime.datetime]:
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value or len(value) > 80:
        raise MonitorError("invalid_timestamp")
    normalized = value[:-1] + "+00:00" if value.endswith(("Z", "z")) else value
    try:
        parsed = _datetime.datetime.fromisoformat(normalized)
    except ValueError:
        raise MonitorError("invalid_timestamp") from None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise MonitorError("timestamp_timezone_required")
    return parsed.astimezone(_datetime.timezone.utc)


def timestamp_string(value: _datetime.datetime) -> str:
    return value.astimezone(_datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def utc_now() -> _datetime.datetime:
    return _datetime.datetime.now(_datetime.timezone.utc)


def _parse_envelope(value: Any, command: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise MonitorError("unexpected_report_shape")
    _require_keys(value, ALLOWED_ENVELOPE_KEYS, ALLOWED_ENVELOPE_KEYS)
    if value["schemaVersion"] != SCHEMA_VERSION or value["command"] != command:
        raise MonitorError("incompatible_command")
    if not isinstance(value["ok"], bool):
        raise MonitorError("unexpected_report_shape")
    if not isinstance(value["warnings"], list) or any(not isinstance(item, str) for item in value["warnings"]):
        raise MonitorError("unexpected_report_shape")
    if value["error"] is not None and not isinstance(value["error"], Mapping):
        raise MonitorError("unexpected_report_shape")
    return value


def _safe_window_label(value: Any) -> str:
    if not isinstance(value, str):
        raise MonitorError("invalid_window_label")
    if value in {"5h", "Weekly", "30d"} or WINDOW_PATTERN.fullmatch(value):
        return value
    raise MonitorError("invalid_window_label")


def _choose_window(windows: list[WindowSnapshot]) -> Optional[WindowSnapshot]:
    if not windows:
        return None
    priority = {"5h": 0, "Weekly": 1, "30d": 2}
    # Prefer a short window with an actual reset timestamp. A transiently
    # missing 5h reset must not hide a usable weekly reset signal.
    with_reset = [window for window in windows if window.reset_at is not None]
    candidates = with_reset or windows
    return min(candidates, key=lambda window: priority.get(window.label, 3))


def parse_quota_report(value: Any) -> list[AccountSnapshot]:
    envelope = _parse_envelope(value, "agent quota report")
    if not envelope["ok"]:
        raise MonitorError("quota_report_failed")
    data = envelope["data"]
    if not isinstance(data, Mapping):
        raise MonitorError("unexpected_report_shape")
    _require_keys(data, ALLOWED_DATA_KEYS, ALLOWED_DATA_KEYS)
    if data["schemaVersion"] != SCHEMA_VERSION:
        raise MonitorError("incompatible_command")
    parse_timestamp(data["fetchedAt"])
    accounts = data["accounts"]
    if not isinstance(accounts, list) or len(accounts) > 1000:
        raise MonitorError("unexpected_report_shape")

    result: list[AccountSnapshot] = []
    refs: set[str] = set()
    for raw_account in accounts:
        if not isinstance(raw_account, Mapping):
            raise MonitorError("unexpected_report_shape")
        _require_keys(
            raw_account,
            ALLOWED_ACCOUNT_KEYS,
            {"ref", "state", "usageStatus", "windows"},
        )
        ref = raw_account["ref"]
        if not isinstance(ref, str) or not REF_PATTERN.fullmatch(ref) or ref in refs:
            raise MonitorError("invalid_account_reference")
        refs.add(ref)
        state = raw_account["state"]
        usage_status = raw_account["usageStatus"]
        if state not in {"active", "available", "paused", "signInRequired"}:
            raise MonitorError("invalid_account_state")
        if usage_status not in {
            "ok",
            "signInRequired",
            "unauthorized",
            "timeout",
            "network",
            "serviceError",
            "malformedResponse",
        }:
            raise MonitorError("invalid_usage_status")

        windows_value = raw_account["windows"]
        if not isinstance(windows_value, list) or len(windows_value) > 16:
            raise MonitorError("unexpected_report_shape")
        windows: list[WindowSnapshot] = []
        labels: set[str] = set()
        for raw_window in windows_value:
            if not isinstance(raw_window, Mapping):
                raise MonitorError("unexpected_report_shape")
            _require_keys(raw_window, ALLOWED_WINDOW_KEYS, {"label", "usedPercent", "remainingPercent"})
            label = _safe_window_label(raw_window["label"])
            if label in labels:
                raise MonitorError("duplicate_window_label")
            labels.add(label)
            used = raw_window["usedPercent"]
            remaining = raw_window["remainingPercent"]
            if type(used) is not int or not 0 <= used <= 100:
                raise MonitorError("invalid_usage_percent")
            if type(remaining) is not int or remaining != max(0, 100 - used):
                raise MonitorError("invalid_remaining_percent")
            reset_at = parse_timestamp(raw_window.get("resetAt"), required=False)
            windows.append(WindowSnapshot(label=label, used_percent=used, reset_at=reset_at))
        result.append(
            AccountSnapshot(
                ref=ref,
                state=state,
                usage_status=usage_status,
                window=_choose_window(windows),
            )
        )
    return result


def parse_status_health(value: Any) -> bool:
    envelope = _parse_envelope(value, "agent status")
    if not envelope["ok"]:
        return False
    data = envelope["data"]
    if not isinstance(data, Mapping) or set(data) - {
        "proxy",
        "routing",
        "strategy",
        "activeRef",
        "stickyRef",
        "drainingRefs",
        "accounts",
        "warmupInProgress",
        "warmup",
    }:
        raise MonitorError("unexpected_status_shape")
    proxy = data.get("proxy")
    if not isinstance(proxy, Mapping) or set(proxy) - {"available", "port"} or not {"available", "port"}.issubset(proxy):
        raise MonitorError("unexpected_status_shape")
    if not isinstance(proxy["available"], bool) or type(proxy["port"]) is not int or not 0 <= proxy["port"] <= 65535:
        raise MonitorError("unexpected_status_shape")
    return proxy["available"]


def parse_warmup_success(value: Any) -> tuple[bool, set[str]]:
    envelope = _parse_envelope(value, "agent warmup all")
    data = envelope["data"]
    warmed_refs: set[str] = set()
    if data is not None:
        if not isinstance(data, Mapping):
            raise MonitorError("unexpected_warmup_shape")
        allowed_data = {"status", "accounts", "counts", "startedAt", "finishedAt"}
        if set(data) - allowed_data or "accounts" not in data:
            raise MonitorError("unexpected_warmup_shape")
        if "status" in data and data["status"] not in {"ok", "proxyUnavailable", "failed", "dryRun"}:
            raise MonitorError("unexpected_warmup_shape")
        if "startedAt" in data:
            parse_timestamp(data["startedAt"])
        if "finishedAt" in data:
            parse_timestamp(data["finishedAt"])
        accounts = data["accounts"]
        if not isinstance(accounts, list) or len(accounts) > 1000:
            raise MonitorError("unexpected_warmup_shape")
        for item in accounts:
            if not isinstance(item, Mapping) or set(item) - {"ref", "status"} or {"ref", "status"} - set(item):
                raise MonitorError("unexpected_warmup_shape")
            ref = item["ref"]
            status = item["status"]
            if not isinstance(ref, str) or not REF_PATTERN.fullmatch(ref) or status not in SAFE_WARM_STATUSES:
                raise MonitorError("unexpected_warmup_shape")
            if status == "warmed":
                warmed_refs.add(ref)
    return envelope["ok"], warmed_refs


def parse_targeted_warmup_success(value: Any, expected_ref: str) -> tuple[bool, bool]:
    """Validate one-account warm-up output without accepting roster-wide data."""

    envelope = _parse_envelope(value, "agent warmup account")
    data = envelope["data"]
    if not isinstance(data, Mapping):
        raise MonitorError("unexpected_warmup_shape")
    allowed_data = {"status", "ref", "accountStatus", "counts", "startedAt", "finishedAt"}
    if set(data) - allowed_data or not {"status", "ref", "accountStatus"}.issubset(data):
        raise MonitorError("unexpected_warmup_shape")
    if data["status"] not in {"ok", "proxyUnavailable", "failed", "dryRun"}:
        raise MonitorError("unexpected_warmup_shape")
    ref = data["ref"]
    account_status = data["accountStatus"]
    if not isinstance(ref, str) or not REF_PATTERN.fullmatch(ref) or ref != expected_ref:
        raise MonitorError("unexpected_warmup_shape")
    if account_status not in SAFE_WARM_STATUSES:
        raise MonitorError("unexpected_warmup_shape")
    counts = data.get("counts")
    if not isinstance(counts, Mapping):
        raise MonitorError("unexpected_warmup_shape")
    if set(counts) - {"total", "eligible", "warmed", "skipped", "failed"}:
        raise MonitorError("unexpected_warmup_shape")
    for key in counts:
        if type(counts[key]) is not int or counts[key] < 0:
            raise MonitorError("unexpected_warmup_shape")
    for key in ("startedAt", "finishedAt"):
        if key in data:
            parse_timestamp(data[key])
    return envelope["ok"], account_status == "warmed"


def reset_fingerprint(snapshot: AccountSnapshot) -> Optional[str]:
    if snapshot.window is None or snapshot.window.reset_at is None:
        return None
    digest_input = f"{snapshot.window.label}|{timestamp_string(snapshot.window.reset_at)}".encode()
    return hashlib.sha256(digest_input).hexdigest()[:32]


def _state_timestamp(value: Any) -> Optional[_datetime.datetime]:
    return parse_timestamp(value, required=False)


def observe_reset(
    previous: Optional[Mapping[str, Any]],
    current: AccountSnapshot,
    now: _datetime.datetime,
) -> bool:
    """Return true only for a reset discontinuity, not ordinary polling."""

    if previous is None or current.window is None or current.window.reset_at is None:
        return False
    if current.state not in {"active", "available"} or current.usage_status != "ok":
        return False
    previous_reset = _state_timestamp(previous.get("resetAt"))
    if previous_reset is None:
        return False
    current_reset = current.window.reset_at
    previous_used = previous.get("usedPercent")
    if type(previous_used) is not int or not 0 <= previous_used <= 100:
        return False

    # A reset can be observed while the monitor was asleep: the prior deadline
    # is now in the past and the service reports a new future deadline.
    if previous_reset <= now < current_reset:
        return True
    # A lower usage percentage is strong evidence of a new quota cycle even if
    # the upstream rounds or briefly retains the same reset timestamp.
    if current.window.used_percent < previous_used and current_reset >= now:
        return True
    # A changed future deadline alone is not enough: active traffic can move a
    # deadline forward.  Require a lower usage value or an elapsed old deadline.
    return current_reset != previous_reset and previous_reset <= now


def _default_state() -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "accounts": {},
        "lastPollAt": None,
        "lastWarmAt": None,
        "lastWarmStatus": None,
        "nextAttemptAfter": None,
    }


def validate_state(value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise MonitorError("state_invalid")
    _require_keys(value, ALLOWED_STATE_KEYS, ALLOWED_STATE_KEYS)
    if value["schemaVersion"] != SCHEMA_VERSION or not isinstance(value["accounts"], Mapping):
        raise MonitorError("state_invalid")
    for key in ("lastPollAt", "lastWarmAt", "nextAttemptAfter"):
        parse_timestamp(value[key], required=False)
    if value["lastWarmStatus"] is not None and value["lastWarmStatus"] not in {
        "succeeded",
        "failed",
        "proxyUnavailable",
    }:
        raise MonitorError("state_invalid")

    accounts: dict[str, Any] = {}
    for ref, raw in value["accounts"].items():
        if not isinstance(ref, str) or not REF_PATTERN.fullmatch(ref) or not isinstance(raw, Mapping):
            raise MonitorError("state_invalid")
        _require_keys(raw, ALLOWED_STATE_ACCOUNT_KEYS, ALLOWED_STATE_ACCOUNT_KEYS)
        if raw["label"] is not None and (not isinstance(raw["label"], str) or not (_safe_window_label(raw["label"]))):
            raise MonitorError("state_invalid")
        if raw["usedPercent"] is not None and (type(raw["usedPercent"]) is not int or not 0 <= raw["usedPercent"] <= 100):
            raise MonitorError("state_invalid")
        for key in ("resetAt", "observedAt", "pendingObservedAt", "lastWarmAt"):
            parse_timestamp(raw[key], required=False)
        for key in ("pendingFingerprint", "lastWarmFingerprint"):
            if raw[key] is not None and (not isinstance(raw[key], str) or not re.fullmatch(r"[0-9a-f]{32}", raw[key])):
                raise MonitorError("state_invalid")
        accounts[ref] = dict(raw)
    result = dict(value)
    result["accounts"] = accounts
    return result


def state_path(state_dir: Path) -> Path:
    return state_dir / "state.json"


def log_path(state_dir: Path) -> Path:
    return state_dir / "monitor.log"


def ensure_private_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        os.chmod(path, stat.S_IRWXU)
    except OSError as error:
        del error
        raise MonitorError("state_directory_unavailable") from None
    if not path.is_dir():
        raise MonitorError("state_directory_unavailable")


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return _default_state()
    try:
        data = path.read_text(encoding="utf-8")
    except OSError as error:
        del error
        raise MonitorError("state_unavailable") from None
    if not data:
        raise MonitorError("state_invalid")
    return validate_state(decode_json(data))


def save_state(path: Path, value: Mapping[str, Any]) -> None:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    ensure_private_directory(path.parent)
    temporary_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=".state.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            os.fchmod(temporary.fileno(), stat.S_IRUSR | stat.S_IWUSR)
            temporary.write(encoded)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
        temporary_path = None
    except OSError as error:
        del error
        raise MonitorError("state_write_failed") from None
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except OSError:
                pass


def append_log(path: Path, event: str, **fields: Any) -> None:
    """Append a bounded, sanitized event without command output."""

    safe_fields: dict[str, Any] = {"schemaVersion": SCHEMA_VERSION, "at": timestamp_string(utc_now()), "event": event}
    for key, value in fields.items():
        if key in {"error", "stderr", "stdout", "message", "alias", "email", "token"}:
            continue
        if isinstance(value, (str, int, float, bool)) or value is None:
            safe_fields[key] = value
    line = json.dumps(safe_fields, sort_keys=True, separators=(",", ":")) + "\n"
    try:
        ensure_private_directory(path.parent)
        if path.exists() and path.stat().st_size > 1_000_000:
            rotated = path.with_suffix(path.suffix + ".1")
            try:
                os.replace(path, rotated)
            except OSError:
                pass
        flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
        descriptor = os.open(path, flags, stat.S_IRUSR | stat.S_IWUSR)
        try:
            os.write(descriptor, line.encode("utf-8"))
        finally:
            os.close(descriptor)
    except OSError:
        # Logging must never make quota decisions unsafe or noisy.
        return


def find_binary(explicit: Optional[str], script_path: Path) -> Optional[Path]:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    env_binary = os.environ.get("CODEXSWAP_SWAPD")
    if env_binary:
        candidates.append(Path(env_binary).expanduser())
    candidates.extend(
        [
            Path("/Applications/CodexSwap.app/Contents/MacOS/swapd"),
            Path.home() / "Applications/CodexSwap.app/Contents/MacOS/swapd",
            script_path.resolve().parents[3] / ".build/release/swapd",
            script_path.resolve().parents[3] / ".build/debug/swapd",
        ]
    )
    seen: set[str] = set()
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if str(resolved) in seen:
            continue
        seen.add(str(resolved))
        try:
            mode = resolved.stat().st_mode
        except OSError:
            continue
        if stat.S_ISREG(mode) and os.access(resolved, os.X_OK):
            return resolved
    return None


def run_command(binary: Path, arguments: list[str], timeout_seconds: float) -> CommandResponse:
    environment = {
        "HOME": str(Path.home()),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        "LANG": "C",
        "NO_COLOR": "1",
    }
    if os.environ.get("CODEX_HOME"):
        environment["CODEX_HOME"] = os.environ["CODEX_HOME"]
    try:
        completed = subprocess.run(
            [str(binary), *arguments],
            cwd="/",
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=max(1.0, timeout_seconds),
            check=False,
        )
    except subprocess.TimeoutExpired:
        return CommandResponse(return_code=124, payload=None, failure="timeout")
    except (OSError, ValueError):
        return CommandResponse(return_code=127, payload=None, failure="command_unavailable")
    if completed.returncode != 0:
        return CommandResponse(return_code=completed.returncode, payload=None, failure="command_failed")
    try:
        payload = decode_json(completed.stdout)
    except MonitorError as error:
        return CommandResponse(return_code=completed.returncode, payload=None, failure=error.code)
    if not isinstance(payload, Mapping):
        return CommandResponse(return_code=completed.returncode, payload=None, failure="unexpected_report_shape")
    return CommandResponse(return_code=completed.returncode, payload=payload)


def _account_record(snapshot: AccountSnapshot, now: _datetime.datetime) -> dict[str, Any]:
    return {
        "label": snapshot.window.label if snapshot.window else None,
        "resetAt": timestamp_string(snapshot.window.reset_at) if snapshot.window and snapshot.window.reset_at else None,
        "usedPercent": snapshot.window.used_percent if snapshot.window else None,
        "observedAt": timestamp_string(now),
        "pendingFingerprint": None,
        "pendingObservedAt": None,
        "lastWarmFingerprint": None,
        "lastWarmAt": None,
    }


def _pending_refs(state: Mapping[str, Any], snapshots: Iterable[AccountSnapshot]) -> list[str]:
    current_by_ref = {item.ref: item for item in snapshots}
    refs: list[str] = []
    for ref, record in state["accounts"].items():
        if not record.get("pendingFingerprint"):
            continue
        current = current_by_ref.get(ref)
        if current is None or current.window is None or current.window.reset_at is None:
            continue
        if current.state in {"active", "available"} and current.usage_status == "ok":
            # The warm-up command is quota-consuming. A reset transition can
            # be visible while an account is already serving traffic; keep the
            # marker for a later zero-usage reading, but never target a used
            # account (or fall back to a roster-wide warm-up).
            if current.window.used_percent != 0:
                continue
            refs.append(ref)
    return sorted(refs)


def _usable_snapshot(snapshot: AccountSnapshot) -> bool:
    return (
        snapshot.state in {"active", "available"}
        and snapshot.usage_status == "ok"
        and snapshot.window is not None
        and snapshot.window.reset_at is not None
    )


def _apply_observations(
    state: dict[str, Any],
    snapshots: list[AccountSnapshot],
    now: _datetime.datetime,
) -> int:
    existing = state["accounts"]
    observed_count = 0
    current_refs = {item.ref for item in snapshots}
    for snapshot in snapshots:
        previous = existing.get(snapshot.ref)
        record = _account_record(snapshot, now)
        if previous is not None:
            record["pendingFingerprint"] = previous.get("pendingFingerprint")
            record["pendingObservedAt"] = previous.get("pendingObservedAt")
            record["lastWarmFingerprint"] = previous.get("lastWarmFingerprint")
            record["lastWarmAt"] = previous.get("lastWarmAt")
            # A transient report can omit resetAt (or the complete window)
            # while still reporting an otherwise healthy account. Preserve
            # the last baseline so the next complete report can still prove a
            # reset instead of silently re-arming from an empty baseline.
            # A network/timeout/error report is still a local observation, not
            # a new baseline. Preserve the last usable reset and percentage so
            # a reset that elapsed during the outage can be detected when the
            # next healthy report returns. The same preservation applies to a
            # healthy report whose reset timestamp is transiently missing.
            if not _usable_snapshot(snapshot):
                record["label"] = previous.get("label")
                record["resetAt"] = previous.get("resetAt")
                record["usedPercent"] = previous.get("usedPercent")
        if observe_reset(previous, snapshot, now):
            fingerprint = reset_fingerprint(snapshot)
            if fingerprint is not None and fingerprint not in {
                (previous or {}).get("lastWarmFingerprint"),
                (previous or {}).get("pendingFingerprint"),
            }:
                record["pendingFingerprint"] = fingerprint
                record["pendingObservedAt"] = timestamp_string(now)
                observed_count += 1
        elif (
            previous is not None
            and _usable_snapshot(snapshot)
            and record["pendingFingerprint"]
            and record["pendingFingerprint"] != reset_fingerprint(snapshot)
        ):
            # A later, non-reset observation supersedes stale pending work. A
            # genuine new reset will set a fresh pending fingerprint above.
            record["pendingFingerprint"] = None
            record["pendingObservedAt"] = None
        existing[snapshot.ref] = record
    # Roster removal is safe to reconcile because refs are opaque and the
    # quota report is a complete sanitized roster. Do not retain stale targets.
    for ref in list(existing):
        if ref not in current_refs:
            del existing[ref]
    return observed_count


def _mark_warmed(state: dict[str, Any], refs: Iterable[str], now: _datetime.datetime) -> None:
    for ref in refs:
        record = state["accounts"].get(ref)
        if record is None:
            continue
        pending = record.get("pendingFingerprint")
        if pending:
            record["lastWarmFingerprint"] = pending
            record["lastWarmAt"] = timestamp_string(now)
            record["pendingFingerprint"] = None
            record["pendingObservedAt"] = None


@dataclasses.dataclass(frozen=True)
class MonitorConfig:
    binary: Optional[Path]
    state_dir: Path
    cooldown_seconds: float = DEFAULT_COOLDOWN_SECONDS
    command_timeout_seconds: float = DEFAULT_COMMAND_TIMEOUT_SECONDS
    warmup_timeout_seconds: float = DEFAULT_WARMUP_TIMEOUT_SECONDS
    script_path: Path = Path(__file__)


def monitor_once(config: MonitorConfig, *, now: Optional[_datetime.datetime] = None) -> tuple[int, dict[str, Any]]:
    now = (now or utc_now()).astimezone(_datetime.timezone.utc)
    ensure_private_directory(config.state_dir)
    lock_path = config.state_dir / "monitor.lock"
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, stat.S_IRUSR | stat.S_IWUSR)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            append_log(log_path(config.state_dir), "lock_busy")
            return EXIT_TEMPORARY, {"status": "locked"}

        binary = find_binary(str(config.binary) if config.binary else None, config.script_path)
        if binary is None:
            append_log(log_path(config.state_dir), "binary_unavailable")
            return EXIT_UNAVAILABLE, {"status": "binaryUnavailable"}
        state_file = state_path(config.state_dir)
        try:
            state = load_state(state_file)
        except MonitorError as error:
            append_log(log_path(config.state_dir), "state_invalid", code=error.code)
            return EXIT_DATA, {"status": "stateInvalid"}

        quota_response = run_command(
            binary,
            ["agent", "quota", "report", "--json"],
            config.command_timeout_seconds,
        )
        if quota_response.payload is None:
            append_log(log_path(config.state_dir), "quota_unavailable", code=quota_response.failure or "unknown")
            return EXIT_UNAVAILABLE, {"status": "quotaUnavailable"}
        try:
            snapshots = parse_quota_report(quota_response.payload)
        except MonitorError as error:
            append_log(log_path(config.state_dir), "quota_invalid", code=error.code)
            return EXIT_DATA, {"status": "quotaInvalid"}

        observed = _apply_observations(state, snapshots, now)
        state["lastPollAt"] = timestamp_string(now)
        try:
            save_state(state_file, state)
        except MonitorError as error:
            append_log(log_path(config.state_dir), "state_write_failed", code=error.code)
            return EXIT_DATA, {"status": "stateWriteFailed"}

        pending = _pending_refs(state, snapshots)
        if not pending:
            status = "resetObserved" if observed else "noReset"
            append_log(log_path(config.state_dir), status, observed=observed, pending=0)
            return EXIT_OK, {"status": status, "observedResetCount": observed, "pendingCount": 0}

        next_attempt = _state_timestamp(state.get("nextAttemptAfter"))
        if next_attempt is not None and next_attempt > now:
            append_log(log_path(config.state_dir), "cooldown", pending=len(pending))
            return EXIT_OK, {
                "status": "cooldown",
                "observedResetCount": observed,
                "pendingCount": len(pending),
            }

        status_response = run_command(binary, ["agent", "status", "--json"], config.command_timeout_seconds)
        if status_response.payload is None:
            append_log(log_path(config.state_dir), "proxy_unavailable", code=status_response.failure or "unknown")
            state["lastWarmStatus"] = "proxyUnavailable"
            save_state(state_file, state)
            return EXIT_UNAVAILABLE, {
                "status": "proxyUnavailable",
                "observedResetCount": observed,
                "pendingCount": len(pending),
            }
        try:
            proxy_available = parse_status_health(status_response.payload)
        except MonitorError as error:
            append_log(log_path(config.state_dir), "status_invalid", code=error.code)
            state["lastWarmStatus"] = "proxyUnavailable"
            save_state(state_file, state)
            return EXIT_UNAVAILABLE, {
                "status": "proxyUnavailable",
                "observedResetCount": observed,
                "pendingCount": len(pending),
            }
        if not proxy_available:
            append_log(log_path(config.state_dir), "proxy_unavailable", pending=len(pending))
            state["lastWarmStatus"] = "proxyUnavailable"
            save_state(state_file, state)
            return EXIT_UNAVAILABLE, {
                "status": "proxyUnavailable",
                "observedResetCount": observed,
                "pendingCount": len(pending),
            }

        # Persist the cooldown only once the loopback service is confirmed
        # available and immediately before the first targeted request. An
        # unavailable app/proxy is not a warm-up attempt; retaining a cooldown
        # in that case would make an app-open or reconnect poll wait needlessly.
        state["nextAttemptAfter"] = timestamp_string(
            now + _datetime.timedelta(seconds=config.cooldown_seconds)
        )
        try:
            save_state(state_file, state)
        except MonitorError as error:
            append_log(log_path(config.state_dir), "state_write_failed", code=error.code)
            return EXIT_DATA, {"status": "stateWriteFailed", "pendingCount": len(pending)}

        append_log(log_path(config.state_dir), "warm_requested", pending=len(pending))
        # A reset marker identifies one account.  Keep each request targeted so
        # a reset in one account cannot spend quota or acquire a lease for the
        # rest of the roster.  Continue through the pending set so independent
        # resets are handled in the same poll; failed refs remain pending for
        # the cooldown retry.
        successful_refs: set[str] = set()
        warmed_refs: set[str] = set()
        failed_refs: set[str] = set()
        for ref in pending:
            warm_response = run_command(
                binary,
                ["agent", "warmup", "account", ref, "--confirm", "--json"],
                config.warmup_timeout_seconds,
            )
            if warm_response.payload is None:
                failed_refs.add(ref)
                append_log(log_path(config.state_dir), "warm_failed", code=warm_response.failure or "unknown")
                continue
            try:
                warm_ok, warmed = parse_targeted_warmup_success(warm_response.payload, ref)
            except MonitorError as error:
                failed_refs.add(ref)
                append_log(log_path(config.state_dir), "warm_invalid", code=error.code)
                continue
            if warm_ok:
                successful_refs.add(ref)
                if warmed:
                    warmed_refs.add(ref)
            else:
                failed_refs.add(ref)

        # A valid targeted response is the deduplication boundary for that ref.
        # Even a safe skip (for example a race into cooldown) must not be
        # replayed for the same reset fingerprint on every monitor tick.
        _mark_warmed(state, successful_refs, now)
        if successful_refs:
            state["lastWarmAt"] = timestamp_string(now)
        state["lastWarmStatus"] = "failed" if failed_refs else "succeeded"
        state["nextAttemptAfter"] = (
            timestamp_string(now + _datetime.timedelta(seconds=config.cooldown_seconds))
            if failed_refs
            else None
        )
        save_state(state_file, state)
        if failed_refs:
            append_log(log_path(config.state_dir), "warm_failed", failed=len(failed_refs), warmed=len(warmed_refs))
            return EXIT_TEMPORARY, {
                "status": "warmFailed",
                "observedResetCount": observed,
                "pendingCount": len(_pending_refs(state, snapshots)),
                "warmedCount": len(warmed_refs),
            }

        append_log(log_path(config.state_dir), "warm_succeeded", warmed=len(warmed_refs), pending=len(pending))
        return EXIT_OK, {
            "status": "warmed" if warmed_refs else "warmSkipped",
            "observedResetCount": observed,
            "pendingCount": len(_pending_refs(state, snapshots)),
            "warmedCount": len(warmed_refs),
        }
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _positive_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be a number") from None
    if parsed <= 0 or parsed != parsed or parsed == float("inf"):
        raise argparse.ArgumentTypeError("must be finite and positive")
    return parsed


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Warm CodexSwap accounts after an observed quota reset.")
    parser.add_argument("--once", action="store_true", help="poll once (the default; launchd mode)")
    parser.add_argument("--watch", action="store_true", help="poll continuously")
    parser.add_argument("--json", action="store_true", help="emit one sanitized JSON result per poll")
    parser.add_argument("--binary", help="explicit swapd path (normally discovered automatically)")
    parser.add_argument(
        "--state-dir",
        default=os.environ.get(
            "CODEXSWAP_MONITOR_STATE_DIR",
            str(Path.home() / "Library/Application Support/CodexSwap/reset-warm-monitor"),
        ),
        help="private state/log directory",
    )
    parser.add_argument("--interval-seconds", type=_positive_float, default=DEFAULT_INTERVAL_SECONDS)
    parser.add_argument("--cooldown-seconds", type=_positive_float, default=DEFAULT_COOLDOWN_SECONDS)
    parser.add_argument("--command-timeout-seconds", type=_positive_float, default=DEFAULT_COMMAND_TIMEOUT_SECONDS)
    parser.add_argument("--warmup-timeout-seconds", type=_positive_float, default=DEFAULT_WARMUP_TIMEOUT_SECONDS)
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.once and args.watch:
        parser.error("--once and --watch are mutually exclusive")
    config = MonitorConfig(
        binary=Path(args.binary).expanduser() if args.binary else None,
        state_dir=Path(args.state_dir).expanduser(),
        cooldown_seconds=args.cooldown_seconds,
        command_timeout_seconds=args.command_timeout_seconds,
        warmup_timeout_seconds=args.warmup_timeout_seconds,
        script_path=Path(__file__),
    )
    watching = args.watch
    stopping = False

    def stop(_signum: int, _frame: Any) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    last_exit = EXIT_OK
    while True:
        last_exit, result = monitor_once(config)
        output = {"schemaVersion": SCHEMA_VERSION, **result}
        print(json.dumps(output, sort_keys=True, separators=(",", ":")), flush=True)
        if not watching or stopping:
            return last_exit
        deadline = time.monotonic() + args.interval_seconds
        while not stopping:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(remaining, 1.0))


if __name__ == "__main__":
    raise SystemExit(main())
