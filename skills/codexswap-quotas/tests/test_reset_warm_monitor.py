#!/usr/bin/env python3
"""Deterministic tests for the reset-aware warm-up monitor."""

from __future__ import annotations

import datetime as dt
import fcntl
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "reset_warm_monitor.py"
SPEC = importlib.util.spec_from_file_location("reset_warm_monitor", SCRIPT)
assert SPEC and SPEC.loader
monitor = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = monitor
SPEC.loader.exec_module(monitor)


REF = "acct-0123456789abcdef"
USED_REF = "acct-fedcba9876543210"


def instant(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def envelope(command: str, data: object, *, ok: bool = True) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "command": command,
        "ok": ok,
        "data": data,
        "warnings": [],
        "error": None,
    }


def quota_report(
    *,
    used: int,
    reset_at: str | None,
    fetched_at: str = "2026-08-30T23:00:00Z",
    usage_status: str = "ok",
    state: str = "available",
    include_window: bool = True,
    extra_accounts: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    windows: list[dict[str, object]] = []
    if include_window:
        windows.append(
            {
                "label": "5h",
                "usedPercent": used,
                "remainingPercent": 100 - used,
                "resetAt": reset_at,
            }
        )
    accounts: list[dict[str, object]] = [
        {
            "alias": "Account 1",
            "ref": REF,
            "state": state,
            "usageStatus": usage_status,
            "resetCreditStatus": "noCredit",
            "windows": windows,
        }
    ]
    if extra_accounts:
        accounts.extend(extra_accounts)
    return envelope(
        "agent quota report",
        {
            "schemaVersion": 1,
            "fetchedAt": fetched_at,
            "accounts": accounts,
        },
    )


def status_report(*, available: bool) -> dict[str, object]:
    return envelope(
        "agent status",
        {
            "proxy": {"available": available, "port": 58432},
            "routing": "enabled",
            "strategy": "priority",
            "activeRef": REF,
            "stickyRef": None,
            "drainingRefs": [],
            "accounts": {"active": 1, "archived": 0, "total": 1},
            "warmupInProgress": False,
        },
    )


def warm_report(*, ref: str = REF) -> dict[str, object]:
    return envelope(
        "agent warmup account",
        {
            "status": "ok",
            "ref": ref,
            "accountStatus": "warmed",
            "counts": {"total": 1, "warmed": 1, "skipped": 0, "failed": 0},
            "startedAt": "2026-08-31T00:20:00Z",
            "finishedAt": "2026-08-31T00:20:01Z",
        },
    )


class ResetWarmMonitorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="codexswap-reset-monitor-test-")
        self.root = Path(self.temp.name)
        self.state_dir = self.root / "state"
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        self.phase_file = self.root / "phase"
        self.call_file = self.root / "calls"
        self.proxy_file = self.root / "proxy"
        self.proxy_file.write_text("available", encoding="utf-8")
        self.fixtures.joinpath("status-available.json").write_text(
            json.dumps(status_report(available=True), separators=(",", ":")),
            encoding="utf-8",
        )
        self.fixtures.joinpath("status-unavailable.json").write_text(
            json.dumps(status_report(available=False), separators=(",", ":")),
            encoding="utf-8",
        )
        self.write_phase("baseline", used=80, reset_at="2026-08-31T00:10:00Z")
        self.binary = self.root / "fake-swapd"
        self.binary.write_text(self.fake_swapd_source(), encoding="utf-8")
        self.binary.chmod(stat.S_IRWXU)
        self.config = monitor.MonitorConfig(
            binary=self.binary,
            state_dir=self.state_dir,
            cooldown_seconds=900,
            command_timeout_seconds=5,
            warmup_timeout_seconds=5,
            script_path=SCRIPT,
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def fake_swapd_source(self) -> str:
        paths = {
            "phase": str(self.phase_file),
            "fixtures": str(self.fixtures),
            "calls": str(self.call_file),
            "proxy": str(self.proxy_file),
        }
        encoded = {key: json.dumps(value) for key, value in paths.items()}
        return f"""#!/usr/bin/env python3
import json
import pathlib
import sys

PHASE = pathlib.Path({encoded['phase']})
FIXTURES = pathlib.Path({encoded['fixtures']})
CALLS = pathlib.Path({encoded['calls']})
PROXY = pathlib.Path({encoded['proxy']})
arguments = sys.argv[1:]
with CALLS.open('a', encoding='utf-8') as handle:
    handle.write(json.dumps(arguments) + '\\n')
if arguments == ['agent', 'quota', 'report', '--json']:
    print((FIXTURES / (PHASE.read_text(encoding='utf-8').strip() + '.quota.json')).read_text(encoding='utf-8'), end='')
elif arguments == ['agent', 'status', '--json']:
    state = PROXY.read_text(encoding='utf-8').strip()
    print((FIXTURES / ('status-' + state + '.json')).read_text(encoding='utf-8'), end='')
elif len(arguments) == 6 and arguments[:3] == ['agent', 'warmup', 'account'] and arguments[4:] == ['--confirm', '--json']:
    if PHASE.read_text(encoding='utf-8').strip() == 'warm-fail':
        raise SystemExit(75)
    payload = json.loads((FIXTURES / 'warm.json').read_text(encoding='utf-8'))
    payload['data']['ref'] = arguments[3]
    print(json.dumps(payload, separators=(',', ':')), end='')
else:
    raise SystemExit(64)
"""

    def write_phase(
        self,
        name: str,
        *,
        used: int,
        reset_at: str | None,
        usage_status: str = "ok",
        state: str = "available",
        include_window: bool = True,
        extra_accounts: list[dict[str, object]] | None = None,
    ) -> None:
        self.phase_file.write_text(name, encoding="utf-8")
        self.fixtures.mkdir(parents=True, exist_ok=True)
        self.fixtures.joinpath(f"{name}.quota.json").write_text(
            json.dumps(
                quota_report(
                    used=used,
                    reset_at=reset_at,
                    usage_status=usage_status,
                    state=state,
                    include_window=include_window,
                    extra_accounts=extra_accounts,
                ),
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        self.fixtures.joinpath("warm.json").write_text(
            json.dumps(warm_report(), separators=(",", ":")),
            encoding="utf-8",
        )

    def calls(self) -> list[list[str]]:
        if not self.call_file.exists():
            return []
        return [json.loads(line) for line in self.call_file.read_text(encoding="utf-8").splitlines()]

    def test_first_poll_establishes_baseline_without_warming(self) -> None:
        code, result = monitor.monitor_once(self.config, now=instant("2026-08-30T23:00:00Z"))

        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "noReset")
        self.assertEqual(self.calls(), [["agent", "quota", "report", "--json"]])
        saved = json.loads((self.state_dir / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["accounts"][REF]["usedPercent"], 80)
        self.assertIsNone(saved["accounts"][REF]["pendingFingerprint"])

    def test_reset_is_warmed_once_and_deduplicated_after_relaunch(self) -> None:
        monitor.monitor_once(self.config, now=instant("2026-08-30T23:00:00Z"))
        self.write_phase("reset", used=0, reset_at="2026-08-31T01:00:00Z")

        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:20:00Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "warmed")
        self.assertEqual(result["warmedCount"], 1)
        self.assertEqual(
            self.calls()[1:],
            [
                ["agent", "quota", "report", "--json"],
                ["agent", "status", "--json"],
                ["agent", "warmup", "account", REF, "--confirm", "--json"],
            ],
        )

        # A new monitor instance represents a reboot or launchd replacement.
        replacement = monitor.MonitorConfig(
            binary=self.binary,
            state_dir=self.state_dir,
            cooldown_seconds=900,
            command_timeout_seconds=5,
            warmup_timeout_seconds=5,
            script_path=SCRIPT,
        )
        code, result = monitor.monitor_once(replacement, now=instant("2026-08-31T00:21:00Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "noReset")
        self.assertEqual(sum(1 for call in self.calls() if call[:3] == ["agent", "warmup", "account"]), 1)

    def test_reset_past_while_quota_is_offline_is_retried_after_reconnect(self) -> None:
        monitor.monitor_once(self.config, now=instant("2026-08-30T23:00:00Z"))
        # The reset elapses while the provider is unreachable. The local
        # report still arrives from swapd, but it carries no usable window.
        self.write_phase(
            "offline",
            used=0,
            reset_at=None,
            usage_status="network",
            include_window=False,
        )
        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:20:00Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "noReset")
        saved_offline = json.loads((self.state_dir / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(saved_offline["accounts"][REF]["resetAt"], "2026-08-31T00:10:00Z")

        # Once connectivity returns, the new zero-usage/future-reset reading
        # proves the missed transition and is warmed exactly once.
        self.write_phase("reconnected", used=0, reset_at="2026-08-31T05:00:00Z")
        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:21:00Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "warmed")
        self.assertEqual(
            sum(1 for call in self.calls() if call[:3] == ["agent", "warmup", "account"]),
            1,
        )

    def test_lower_usage_with_same_reset_does_not_target_used_account(self) -> None:
        self.write_phase("baseline", used=80, reset_at="2026-08-31T02:00:00Z")
        monitor.monitor_once(self.config, now=instant("2026-08-31T00:00:00Z"))
        self.write_phase("lower", used=10, reset_at="2026-08-31T02:00:00Z")

        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:10:00Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "resetObserved")
        self.assertEqual(sum(1 for call in self.calls() if call[:3] == ["agent", "warmup", "account"]), 0)

        # A later lower reading with the same reset fingerprint is not a new
        # cycle and must not issue another whole-account warm-up.
        self.write_phase("lower_again", used=2, reset_at="2026-08-31T02:00:00Z")
        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:11:00Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "noReset")
        self.assertEqual(sum(1 for call in self.calls() if call[:3] == ["agent", "warmup", "account"]), 0)

    def test_future_deadline_move_without_lower_usage_does_not_warm(self) -> None:
        self.write_phase("baseline", used=40, reset_at="2026-08-31T02:00:00Z")
        monitor.monitor_once(self.config, now=instant("2026-08-31T00:00:00Z"))
        self.write_phase("moved", used=40, reset_at="2026-08-31T03:00:00Z")

        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:10:00Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "noReset")
        self.assertEqual(self.calls(), [["agent", "quota", "report", "--json"], ["agent", "quota", "report", "--json"]])

    def test_unavailable_proxy_does_not_warm_and_retries_on_reconnect(self) -> None:
        monitor.monitor_once(self.config, now=instant("2026-08-30T23:00:00Z"))
        self.write_phase("reset", used=0, reset_at="2026-08-31T01:00:00Z")
        self.proxy_file.write_text("unavailable", encoding="utf-8")

        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:20:00Z"))
        self.assertEqual(code, monitor.EXIT_UNAVAILABLE)
        self.assertEqual(result["status"], "proxyUnavailable")
        self.assertFalse(any(call[:2] == ["agent", "warmup"] for call in self.calls()))

        self.proxy_file.write_text("available", encoding="utf-8")
        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:20:30Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "warmed")

    def test_app_open_catches_up_pending_reset_after_monitor_relaunch(self) -> None:
        monitor.monitor_once(self.config, now=instant("2026-08-30T23:00:00Z"))
        self.write_phase("reset", used=0, reset_at="2026-08-31T01:00:00Z")
        self.proxy_file.write_text("unavailable", encoding="utf-8")
        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:20:00Z"))
        self.assertEqual(code, monitor.EXIT_UNAVAILABLE)
        self.assertEqual(result["status"], "proxyUnavailable")

        # App relaunch creates a new monitor instance. The pending reset must
        # survive that boundary and be consumed once when the proxy is ready.
        replacement = monitor.MonitorConfig(
            binary=self.binary,
            state_dir=self.state_dir,
            cooldown_seconds=900,
            command_timeout_seconds=5,
            warmup_timeout_seconds=5,
            script_path=SCRIPT,
        )
        self.proxy_file.write_text("available", encoding="utf-8")
        code, result = monitor.monitor_once(replacement, now=instant("2026-08-31T00:20:30Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "warmed")
        self.assertEqual(sum(1 for call in self.calls() if call[:3] == ["agent", "warmup", "account"]), 1)

    def test_failed_warm_retries_on_timer_after_bounded_backoff(self) -> None:
        monitor.monitor_once(self.config, now=instant("2026-08-30T23:00:00Z"))
        self.write_phase("warm-fail", used=0, reset_at="2026-08-31T01:00:00Z")

        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:20:00Z"))
        self.assertEqual(code, monitor.EXIT_TEMPORARY)
        self.assertEqual(result["status"], "warmFailed")
        self.assertEqual(sum(1 for call in self.calls() if call[:3] == ["agent", "warmup", "account"]), 1)

        self.write_phase("reset", used=0, reset_at="2026-08-31T01:00:00Z")
        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:20:30Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "cooldown")
        self.assertEqual(sum(1 for call in self.calls() if call[:3] == ["agent", "warmup", "account"]), 1)

        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:36:00Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "warmed")
        self.assertEqual(sum(1 for call in self.calls() if call[:3] == ["agent", "warmup", "account"]), 2)

    def test_used_account_is_not_targeted_by_reset_warmup(self) -> None:
        used_account_baseline = {
            "alias": "Account 2",
            "ref": USED_REF,
            "state": "available",
            "usageStatus": "ok",
            "resetCreditStatus": "noCredit",
            "windows": [
                {
                    "label": "5h",
                    "usedPercent": 80,
                    "remainingPercent": 20,
                    "resetAt": "2026-08-31T00:10:00Z",
                }
            ],
        }
        self.write_phase(
            "baseline-two",
            used=80,
            reset_at="2026-08-31T00:10:00Z",
            extra_accounts=[used_account_baseline],
        )
        monitor.monitor_once(self.config, now=instant("2026-08-30T23:00:00Z"))
        used_account_after_reset = {
            **used_account_baseline,
            "windows": [
                {
                    "label": "5h",
                    "usedPercent": 12,
                    "remainingPercent": 88,
                    "resetAt": "2026-08-31T01:00:00Z",
                }
            ],
        }
        self.write_phase(
            "reset-two",
            used=0,
            reset_at="2026-08-31T01:00:00Z",
            extra_accounts=[used_account_after_reset],
        )
        code, result = monitor.monitor_once(self.config, now=instant("2026-08-31T00:20:00Z"))
        self.assertEqual(code, monitor.EXIT_OK)
        self.assertEqual(result["status"], "warmed")
        warm_calls = [call for call in self.calls() if call[:3] == ["agent", "warmup", "account"]]
        self.assertEqual(len(warm_calls), 1)
        self.assertEqual(warm_calls[0][3], REF)

    def test_concurrent_monitor_is_locked(self) -> None:
        self.state_dir.mkdir(parents=True)
        lock_path = self.state_dir / "monitor.lock"
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, stat.S_IRUSR | stat.S_IWUSR)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, result = monitor.monitor_once(self.config, now=instant("2026-08-30T23:00:00Z"))
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
        self.assertEqual(code, monitor.EXIT_TEMPORARY)
        self.assertEqual(result["status"], "locked")

    def test_persisted_state_and_logs_contain_only_safe_fields(self) -> None:
        monitor.monitor_once(self.config, now=instant("2026-08-30T23:00:00Z"))

        saved = json.loads((self.state_dir / "state.json").read_text(encoding="utf-8"))
        self.assertEqual(set(saved), monitor.ALLOWED_STATE_KEYS)
        self.assertEqual(set(saved["accounts"][REF]), monitor.ALLOWED_STATE_ACCOUNT_KEYS)
        log_lines = (self.state_dir / "monitor.log").read_text(encoding="utf-8").splitlines()
        self.assertTrue(log_lines)
        for line in log_lines:
            event = json.loads(line)
            self.assertEqual(set(event), {"schemaVersion", "at", "event", "observed", "pending"})
            self.assertNotRegex(line.lower(), r"email|token|authorization|account.?id|credit.?id")

    def test_window_selection_uses_weekly_when_short_reset_is_missing(self) -> None:
        selected = monitor._choose_window(
            [
                monitor.WindowSnapshot(label="5h", used_percent=0, reset_at=None),
                monitor.WindowSnapshot(
                    label="Weekly",
                    used_percent=0,
                    reset_at=instant("2026-08-31T04:00:00Z"),
                ),
            ]
        )
        self.assertIsNotNone(selected)
        self.assertEqual(selected.label, "Weekly")


if __name__ == "__main__":
    unittest.main()
