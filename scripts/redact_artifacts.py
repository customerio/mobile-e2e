#!/usr/bin/env python3
"""Remove the Ext API bearer token from generated E2E artifacts.

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

    secret = os.environ.get("MAESTRO_EXT_API_KEY", "")
    if not secret:
        return 0

    root = Path(args.root)
    if not root.exists():
        return 0

    needle = secret.encode()
    matches = list(files_containing(root, needle))
    if args.check:
        if matches:
            print("error: Ext API key remains in generated E2E artifacts")
            return 1
        return 0

    for path, data in matches:
        path.write_bytes(data.replace(needle, b"[REDACTED]"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
