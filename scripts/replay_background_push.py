#!/usr/bin/env python3
"""Replay captured FCM background payloads through the Android SDK host.

This bypasses APNs/FCM. It proves callback data and Android notification behavior,
not provider transport, OS wake guarantees, or backend receipt ingestion.
Use only the existing E2E sample apps, which write background-push.jsonl.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

METADATA = {"CIO-Background-Version", "CIO-Background-Delivery-ID", "CIO-Background-Delivery-Token"}


def run(args, *, check=True):
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    try:
        result = subprocess.run(args, check=False, capture_output=True, text=True, timeout=20, env=env)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{args[0]} timed out") from None
    if check and result.returncode != 0:
        # A provider payload can contain the test device's receipt token. Keep it out of errors.
        raise RuntimeError(f"{args[0]} failed with status {result.returncode}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("android",), required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()
    if not 1 <= args.repeat <= 3:
        parser.error("--repeat must be between 1 and 3")
    envelope = json.loads(args.payload.read_text())
    if args.platform == "android":
        fields = envelope["message"]["data"]
        adb = ["adb", "-s", args.device]

        def receipts():
            result = run(adb + ["shell", "run-as", args.app_id, "cat", "files/background-push.jsonl"], check=False)
            return result.stdout if result.returncode == 0 else ""

        def notification_count():
            output = run(adb + ["shell", "dumpsys", "notification", "--noredact"]).stdout
            return sum("NotificationRecord(" in line and f"pkg={args.app_id} " in line for line in output.splitlines())

        before_notifications = notification_count()

        def deliver():
            command = ["am", "broadcast", "-a", "io.customer.sample.SIMULATE_PUSH_DELIVERY", "-n", args.app_id + "/.util.SimulatePushDeliveryReceiver", "--es", "fcmJson", json.dumps(envelope, ensure_ascii=False), "-f", "0x20000000"]
            run(adb + ["shell", shlex.join(command)])

    if fields.get("CIO-Background-Version") != "1":
        raise ValueError("Expected a version 1 background payload")
    delivery_id = fields["CIO-Background-Delivery-ID"]
    business = {k: v for k, v in fields.items() if k not in METADATA and k != "aps"}

    def matching_rows():
        return [row for line in receipts().splitlines() if (row := json.loads(line)).get("delivery_id") == delivery_id]

    before = len(matching_rows())
    for _ in range(args.repeat):
        deliver()
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        rows = matching_rows()[before:]
        if len(rows) >= args.repeat:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("No matching native callback receipt before the deadline")
    if len(rows) != args.repeat or any(row["data"] != business for row in rows):
        raise AssertionError("Callback count or business data differs from the captured provider payload")
    if args.platform == "android" and notification_count() != before_notifications:
        raise AssertionError("Background replay changed the app's visible notifications")
    print(json.dumps({"platform": args.platform, "callbacks": len(rows), "business_data_matches": True, "provider_transport_tested": False, "backend_receipt_ingestion_tested": False}))


if __name__ == "__main__":
    main()
