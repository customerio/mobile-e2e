#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash "$ROOT/tests/test_android_device.sh"
bash "$ROOT/tests/test_ios_device.sh"
(cd "$ROOT" && python3 -m unittest discover -s tests -p 'test_*.py')

echo "All mobile E2E harness tests passed"
