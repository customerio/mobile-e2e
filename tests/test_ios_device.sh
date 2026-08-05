#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/ios_device.sh
source "$ROOT/scripts/ios_device.sh"

DEVICES_JSON='{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
      {"name":"iPhone 16 Pro","udid":"iphone-16-ios-18-5","isAvailable":true}
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
      {"name":"iPhone 17 Pro","udid":"iphone-17-ios-26-0","isAvailable":true},
      {"name":"Maestro iPhone 17 Pro","udid":"maestro-ios-26-0","isAvailable":true}
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
      {"name":"iPhone 17 Pro","udid":"iphone-17-ios-26-2","isAvailable":true},
      {"name":"Maestro iPhone 17 Pro","udid":"maestro-ios-26-2","isAvailable":true},
      {"name":"iPhone 17 Pro","udid":"unavailable-newest","isAvailable":false}
    ]
  }
}'

selected=$(printf '%s' "$DEVICES_JSON" | select_ios_device "iPhone 17 Pro")
[[ "$selected" == "iphone-17-ios-26-2" ]] || {
  echo "expected preferred model on newest runtime, got '$selected'" >&2
  exit 1
}

selected=$(printf '%s' "$DEVICES_JSON" | select_ios_device "")
[[ "$selected" == "maestro-ios-26-2" ]] || {
  echo "expected newest Maestro model, got '$selected'" >&2
  exit 1
}

selected=$(printf '%s' "$DEVICES_JSON" | select_ios_device "Missing iPhone")
[[ -z "$selected" ]] || {
  echo "expected no selection for a missing preferred model, got '$selected'" >&2
  exit 1
}

STALE_MAESTRO_JSON='{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
      {"name":"Maestro iPhone 17 Pro","udid":"stale-maestro","isAvailable":true}
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
      {"name":"iPhone 17 Pro","udid":"newest-regular","isAvailable":true}
    ]
  }
}'
selected=$(printf '%s' "$STALE_MAESTRO_JSON" | select_ios_device "")
[[ "$selected" == "newest-regular" ]] || {
  echo "expected newest runtime to outrank a stale Maestro-named device, got '$selected'" >&2
  exit 1
}

NUMERIC_RUNTIME_JSON='{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
      {"name":"iPhone 17 Pro","udid":"ios-26-2","isAvailable":true}
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-10": [
      {"name":"iPhone 17 Pro","udid":"ios-26-10","isAvailable":true}
    ]
  }
}'
selected=$(printf '%s' "$NUMERIC_RUNTIME_JSON" | select_ios_device "iPhone 17 Pro")
[[ "$selected" == "ios-26-10" ]] || {
  echo "expected numeric runtime ordering, got '$selected'" >&2
  exit 1
}

GENERIC_FALLBACK_JSON='{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
      {"name":"iPhone 16 Pro","udid":"generic-first","isAvailable":true},
      {"name":"iPhone Air","udid":"generic-second","isAvailable":true}
    ]
  }
}'
selected=$(printf '%s' "$GENERIC_FALLBACK_JSON" | select_ios_device "")
[[ "$selected" == "generic-first" ]] || {
  echo "expected stable generic fallback on newest runtime, got '$selected'" >&2
  exit 1
}

echo "iOS device selection tests passed"
