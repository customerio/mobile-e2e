import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "e2e_diagnostics.py"
SPEC = importlib.util.spec_from_file_location("e2e_diagnostics", MODULE_PATH)
e2e_diagnostics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(e2e_diagnostics)


def geofence_record(**fields):
    record = {
        "kind": "assert_activity",
        "expected_type": "geofence",
        "expected_name": "",
        "expected_property": "geofence_id",
        "expected_property_value": "83",
        "expected_property_2": "",
        "expected_property_value_2": "",
        "run_email": "maestro+e2e-secret-run@cio.test",
    }
    record.update(fields)
    return record


class AssertRecordTests(unittest.TestCase):
    def write_sink(self, directory, records):
        sink = Path(directory) / "sink.jsonl"
        sink.write_text(
            "\n".join(json.dumps(record) for record in records) + "\nnot json\n"
        )
        return sink

    def test_prints_baseline_and_miss_with_bounds_and_seen_activities(self):
        seen = [
            {"id": "aaa:5", "type": "geofence", "timestamp": 1791442650, "property_value": 2926},
            {"id": "bbb:5", "type": "geofence", "timestamp": 1791442727, "property_value": 83},
        ]
        with tempfile.TemporaryDirectory() as directory:
            sink = self.write_sink(directory, [
                {"kind": "setup", "email": "maestro+e2e-secret-run@cio.test"},
                geofence_record(
                    kind="activity_baseline", result="recorded", baseline_activity_ids=[],
                    activities_seen=seen[:1], bounds={"mode": "baseline_snapshot"},
                ),
                geofence_record(
                    result="miss", reason="no_matching_activity_after_120", attempts=120,
                    elapsed_ms=90012, activities_seen=seen,
                    bounds={"max_wait_ms": 90000, "poll_interval_ms": 750, "min_timestamp": 1791442729},
                ),
            ])

            lines = e2e_diagnostics.assert_records(sink)

        self.assertEqual(len(lines), 2)
        self.assertIn("backend baseline geofence geofence_id=83: 0 existing id(s) []", lines[0])
        self.assertIn("aaa:5 geofence ts=1791442650 geofence_id=2926", lines[0])
        self.assertIn("miss reason=no_matching_activity_after_120", lines[1])
        self.assertIn("120 polls, 90012 ms; min_ts=1791442729 max_wait=90000ms", lines[1])
        self.assertIn("bbb:5 geofence ts=1791442727 geofence_id=83", lines[1])
        for line in lines:
            self.assertNotIn("secret-run", line)

    def test_match_line_names_the_activity_and_exclusions(self):
        with tempfile.TemporaryDirectory() as directory:
            sink = self.write_sink(directory, [
                geofence_record(
                    result="match", activity_id="bbb:5", activity_timestamp=1791442727,
                    activity_fields=["data", "delivery_type", "id", "timestamp", "type"],
                    activity_delivery_type="android",
                    attempts=3, elapsed_ms=1500, activities_seen=[],
                    bounds={"max_wait_ms": 90000, "exclude_activity_ids": []},
                ),
            ])

            (line,) = e2e_diagnostics.assert_records(sink)

        self.assertIn(
            "match id=bbb:5 ts=1791442727 fields=data,delivery_type,id,timestamp,type delivery_type=android "
            "(3 polls, 1500 ms; exclude=[] max_wait=90000ms)", line)
        self.assertTrue(line.endswith("seen: none"))

    def test_long_seen_lists_are_truncated(self):
        seen = [{"id": f"id-{n}", "type": "event", "name": "CIO Location Update", "timestamp": n}
                for n in range(8)]
        record = {"kind": "assert_activity", "expected_type": "event", "result": "miss",
                  "reason": "x", "activities_seen": seen}

        line = e2e_diagnostics.format_record(record)

        self.assertIn("id-4 event/CIO Location Update ts=4", line)
        self.assertNotIn("id-5 ", line)
        self.assertIn("+3 more", line)

    def test_missing_or_empty_sink_says_so(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(
                e2e_diagnostics.assert_records(Path(directory) / "absent.jsonl"),
                [">> backend activity assertions: none recorded"],
            )


class FakeClock:
    def __init__(self, readings):
        self.readings = list(readings)

    def __call__(self):
        return self.readings.pop(0)


def fake_adb(outputs):
    calls = []

    def run(argv, **kwargs):
        calls.append(argv)
        result = outputs.pop(0)
        if isinstance(result, Exception):
            raise result
        return subprocess.CompletedProcess(argv, 0, stdout=result, stderr="")

    return run, calls


class AndroidClockTests(unittest.TestCase):
    def test_uses_midpoint_of_shortest_round_trip(self):
        # Sample 1: 400 ms round trip; sample 2: 100 ms (chosen); sample 3 fails.
        run, calls = fake_adb([
            "1791442700.000000000\r\n",
            "1791442799.300000000\r\n",
            subprocess.TimeoutExpired(["adb"], 10),
        ])
        clock = FakeClock([1791442699.9, 1791442700.3, 1791442799.95, 1791442800.05, 1791442900.0])

        offset, round_trip, sub_second = e2e_diagnostics.measure_android_clock(
            "emulator-5554", run=run, clock=clock)

        self.assertAlmostEqual(offset, -0.7, places=5)
        self.assertAlmostEqual(round_trip, 0.1, places=5)
        self.assertTrue(sub_second)
        self.assertEqual(calls[0], ["adb", "-s", "emulator-5554", "shell", "date +%s.%N"])
        line = e2e_diagnostics.format_android_clock("emulator-5554", (offset, round_trip, sub_second))
        self.assertEqual(
            line,
            ">> android clock (emulator-5554): emulator minus runner = -0.700 s "
            "(±0.050 s; adb round trip 100 ms)",
        )

    def test_whole_second_device_date_is_centred_and_flagged(self):
        self.assertEqual(e2e_diagnostics.parse_device_epoch("1791442727.N\n"), (1791442727.0, False))
        run, _ = fake_adb(["1791442727.N\n"])
        clock = FakeClock([1791442727.0, 1791442727.2])

        offset, round_trip, sub_second = e2e_diagnostics.measure_android_clock(
            "emulator-5554", samples=1, run=run, clock=clock)

        self.assertAlmostEqual(offset, 0.4, places=5)
        self.assertFalse(sub_second)
        self.assertIn("whole seconds only",
                      e2e_diagnostics.format_android_clock("emulator-5554", (offset, round_trip, sub_second)))

    def test_reports_unavailable_without_raising(self):
        run, _ = fake_adb([FileNotFoundError("adb")])
        measured = e2e_diagnostics.measure_android_clock("emulator-5554", samples=1, run=run,
                                                         clock=FakeClock([1.0, 2.0]))

        self.assertEqual(
            e2e_diagnostics.format_android_clock("emulator-5554", measured),
            ">> android clock (emulator-5554): unavailable (FileNotFoundError)",
        )


if __name__ == "__main__":
    unittest.main()
