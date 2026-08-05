#!/usr/bin/env python3
"""Remove configured backend values from generated E2E artifacts.

Maestro serializes globally imported flow variables into commands-*.json. The
backend key is needed by runScript, so every local/CI run must scrub the exact
value before reports are rendered or artifacts are uploaded.
"""

import argparse
import base64
import os
from pathlib import Path


def artifact_files(root: Path):
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        yield path, data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    configured_secrets = {
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
    secrets = set(configured_secrets)
    for secret in configured_secrets:
        # HTTP clients and verbose device logs can represent credentials as
        # Basic-auth material instead of their literal environment value.
        secrets.update(
            {
                base64.b64encode(secret),
                base64.b64encode(b":" + secret),
                base64.b64encode(secret + b":"),
            }
        )
    for site_name, key_name in (
        ("MAESTRO_SITE_ID", "MAESTRO_APP_API_KEY"),
        ("ANDROID_SITE_ID", "ANDROID_CDP_API_KEY"),
        ("IOS_SITE_ID", "IOS_CDP_API_KEY"),
    ):
        site_id = os.environ.get(site_name, "").encode()
        api_key = os.environ.get(key_name, "").encode()
        if site_id and api_key:
            secrets.add(base64.b64encode(site_id + b":" + api_key))
    if not secrets:
        return 0

    root = Path(args.root)
    if not root.exists():
        return 0

    if args.check:
        for _, data in artifact_files(root):
            if any(secret in data for secret in secrets):
                print("error: configured secret remains in generated E2E artifacts")
                return 1
        return 0

    for path, data in artifact_files(root):
        sanitized = data
        for secret in secrets:
            sanitized = sanitized.replace(secret, b"[REDACTED]")
        if sanitized != data:
            path.write_bytes(sanitized)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
