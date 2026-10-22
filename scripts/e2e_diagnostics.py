#!/usr/bin/env python3
"""Short diagnostics that run.sh prints into the CI job log.

Uploaded evidence expires after 14 days; the job log stays. These lines keep
the facts needed to explain a backend-assertion failure after that.

Usage:
    e2e_diagnostics.py assert-records <sink.jsonl>
        One line per activity baseline/assertion the flow recorded: result,
        bounds, and the activities the backend returned (ids, types,
        timestamps; never request credentials or the run email).
    e2e_diagnostics.py android-clock <adb serial>
        The emulator's wall clock minus the runner's, measured over adb. The
        SDK stamps events with the device clock; assertions run on the runner.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path

SEEN_IN_LOG = 5
ACTIVITY_KINDS = ("activity_baseline", "assert_activity")


def load_records(sink_path: Path) -> list[dict]:
    records = []
    try:
        lines = sink_path.read_text().splitlines()
    except OSError:
        return records
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and record.get("kind") in ACTIVITY_KINDS:
            records.append(record)
    return records


def _target(record: dict) -> str:
    parts = [str(record.get("expected_type") or "?")]
    if record.get("expected_name"):
        parts.append(json.dumps(record["expected_name"]))
    for name_key, value_key in (
        ("expected_property", "expected_property_value"),
        ("expected_property_2", "expected_property_value_2"),
    ):
        if record.get(name_key):
            parts.append(f"{record[name_key]}={record.get(value_key, '')}")
    return " ".join(parts)


def _seen(record: dict) -> str:
    seen = record.get("activities_seen")
    if not isinstance(seen, list) or not seen:
        return "none" if isinstance(seen, list) else "n/a"
    rendered = []
    for activity in seen[:SEEN_IN_LOG]:
        if not isinstance(activity, dict):
            continue
        label = str(activity.get("type") or "?")
        if activity.get("name"):
            label += "/" + str(activity["name"])
        entry = f"{activity.get('id')} {label} ts={activity.get('timestamp')}"
        if activity.get("property_value") is not None:
            entry += f" {record.get('expected_property')}={activity['property_value']}"
        rendered.append(entry)
    if len(seen) > SEEN_IN_LOG:
        rendered.append(f"+{len(seen) - SEEN_IN_LOG} more")
    return "; ".join(rendered)


def _bounds(record: dict) -> str:
    bounds = record.get("bounds")
    if not isinstance(bounds, dict):
        return ""
    parts = []
    if "min_timestamp" in bounds:
        parts.append(f"min_ts={bounds['min_timestamp']}")
    if "exclude_activity_ids" in bounds:
        parts.append(f"exclude={json.dumps(bounds['exclude_activity_ids'])}")
    if "max_wait_ms" in bounds:
        parts.append(f"max_wait={bounds['max_wait_ms']}ms")
    return " ".join(parts)


def format_record(record: dict) -> str:
    result = record.get("result") or "?"
    if record.get("kind") == "activity_baseline":
        if result == "recorded":
            ids = record.get("baseline_activity_ids") or []
            outcome = f"{len(ids)} existing id(s) {json.dumps(ids)}"
        else:
            outcome = f"{result} reason={record.get('reason')}"
        return f">> backend baseline {_target(record)}: {outcome}; seen: {_seen(record)}"

    if result == "match":
        outcome = (
            f"match id={record.get('activity_id')} ts={record.get('activity_timestamp')}"
        )
        if isinstance(record.get("activity_fields"), list):
            outcome += " fields=" + ",".join(str(name) for name in record["activity_fields"])
    else:
        outcome = f"{result} reason={record.get('reason')}"
        if record.get("last_error"):
            outcome += f" last_error={record['last_error']}"
    timing = f"{record.get('attempts')} polls, {record.get('elapsed_ms')} ms"
    bounds = _bounds(record)
    if bounds:
        timing += "; " + bounds
    return f">> backend assert {_target(record)}: {outcome} ({timing}); seen: {_seen(record)}"


def assert_records(sink_path: Path) -> list[str]:
    records = load_records(sink_path)
    if not records:
        return [">> backend activity assertions: none recorded"]
    return [format_record(record) for record in records]


_EPOCH = re.compile(r"^(\d{9,})(?:\.(\d+))?$")


def parse_device_epoch(stdout: str) -> tuple[float, bool] | None:
    """Parse `date +%s.%N`; a date without %N support yields whole seconds."""
    text = (stdout or "").strip()
    whole = re.match(r"^(\d{9,})", text)
    if not whole:
        return None
    match = _EPOCH.match(text)
    if match and match.group(2):
        return float(f"{match.group(1)}.{match.group(2)}"), True
    return float(whole.group(1)), False


def measure_android_clock(serial: str, samples: int = 3, run=subprocess.run, clock=time.time):
    """Return (device_minus_runner_s, round_trip_s, sub_second) or an error string.

    Each sample brackets one `adb shell date` with runner timestamps and takes
    the midpoint; the sample with the shortest round trip bounds the error best.
    """
    best = None
    error = "no samples"
    for _ in range(samples):
        started = clock()
        try:
            completed = run(
                ["adb", "-s", serial, "shell", "date +%s.%N"],
                capture_output=True, text=True, timeout=10,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            error = type(exc).__name__
            continue
        finished = clock()
        if completed.returncode != 0:
            error = f"adb exit {completed.returncode}"
            continue
        parsed = parse_device_epoch(completed.stdout)
        if parsed is None:
            error = "unparseable device date"
            continue
        device, sub_second = parsed
        if not sub_second:
            device += 0.5  # centre of the truncated second
        round_trip = finished - started
        offset = device - (started + finished) / 2
        if best is None or round_trip < best[1]:
            best = (offset, round_trip, sub_second)
    return best if best is not None else error


def format_android_clock(serial: str, measured) -> str:
    if isinstance(measured, str):
        return f">> android clock ({serial}): unavailable ({measured})"
    offset, round_trip, sub_second = measured
    if sub_second:
        error = f"±{round_trip / 2:.3f} s"
    else:
        error = f"±{round_trip / 2 + 0.5:.3f} s, device date has whole seconds only"
    return (
        f">> android clock ({serial}): emulator minus runner = {offset:+.3f} s "
        f"({error}; adb round trip {round_trip * 1000:.0f} ms)"
    )


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "assert-records":
        for line in assert_records(Path(argv[1])):
            print(line)
        return 0
    if len(argv) == 2 and argv[0] == "android-clock":
        print(format_android_clock(argv[1], measure_android_clock(argv[1])))
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
