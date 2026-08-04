#!/usr/bin/env python3
"""Remove configured backend values from generated E2E artifacts.

Maestro serializes globally imported flow variables into commands-*.json. The
backend key is needed by runScript, so every local/CI run must scrub the exact
value before reports are rendered or artifacts are uploaded.
"""

import argparse
import os
from pathlib import Path


def files_containing(root: Path, needle: bytes):
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if needle in data:
            yield path, data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    secrets = {
        value.encode()
        for name in (
            "MAESTRO_EXT_API_KEY",
            "MAESTRO_APP_API_KEY",
            "LIVE_ACTIVITY_APP_IDENTIFIER",
            "ANDROID_CDP_API_KEY",
            "IOS_CDP_API_KEY",
            "MAESTRO_SITE_ID",
            "ANDROID_SITE_ID",
            "IOS_SITE_ID",
        )
        if (value := os.environ.get(name, ""))
    }
    if not secrets:
        return 0

    root = Path(args.root)
    if not root.exists():
        return 0

    if args.check:
        for secret in secrets:
            if next(files_containing(root, secret), None):
                print("error: configured secret remains in generated E2E artifacts")
                return 1
        return 0

    for secret in secrets:
        for path, data in files_containing(root, secret):
            path.write_bytes(data.replace(secret, b"[REDACTED]"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
