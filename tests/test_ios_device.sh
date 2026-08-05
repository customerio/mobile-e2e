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

IOS_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mobile-e2e-ios-device.XXXXXX")"
cleanup_test_dir() {
  find "$IOS_TEST_DIR" -mindepth 1 -delete
  rmdir "$IOS_TEST_DIR"
}
trap cleanup_test_dir EXIT
mkdir -p "$IOS_TEST_DIR/debug"

printf '%s\n' 'NSMachErrorDomain Code=-308 "(ipc/mig) server died"' \
  >"$IOS_TEST_DIR/debug/xctest_runner_test.log"
ios_maestro_driver_failed "$IOS_TEST_DIR" || {
  echo "expected the XCUITest launch failure to be recoverable" >&2
  exit 1
}

printf '%s\n' 'Assertion is false: expected SDK content is visible' \
  >"$IOS_TEST_DIR/debug/xctest_runner_test.log"
if ios_maestro_driver_failed "$IOS_TEST_DIR"; then
  echo "expected product assertion failures not to trigger driver recovery" >&2
  exit 1
fi

mkdir -p "$IOS_TEST_DIR/debug/product-failure/logs"
printf '%s\n' 'NSMachErrorDomain Code=-308 from an unrelated simulator process' \
  >"$IOS_TEST_DIR/debug/product-failure/logs/device-simulator.log"
if ios_maestro_driver_failed "$IOS_TEST_DIR"; then
  echo "expected nested product diagnostics not to trigger driver recovery" >&2
  exit 1
fi

XCRUN_LOG="$IOS_TEST_DIR/xcrun.log"
: >"$XCRUN_LOG"
XCRUN_BOOTSTATUS_RESULT=0
xcrun() {
  printf '%s\n' "$*" >>"$XCRUN_LOG"
  if [[ "$*" == "simctl shutdown retry-device" ]]; then
    return 1
  fi
  if [[ "$*" == "simctl bootstatus retry-device -b" ]]; then
    return "$XCRUN_BOOTSTATUS_RESULT"
  fi
}
restart_ios_device "retry-device"
grep -Fq "simctl shutdown retry-device" "$XCRUN_LOG"
grep -Fq "simctl boot retry-device" "$XCRUN_LOG"
grep -Fq "simctl bootstatus retry-device -b" "$XCRUN_LOG"

NOTES=""
note() {
  NOTES+="$*"$'\n'
}
RETRY_CALLS=0
retry_command() {
  RETRY_CALLS=$((RETRY_CALLS + 1))
  return 0
}
printf '%s\n' 'IOSDriverTimeoutException: iOS driver not ready in time' \
  >"$IOS_TEST_DIR/debug/maestro.log"
printf '%s\n' 'first attempt output' >"$IOS_TEST_DIR/run.log"
run_ios_driver_recovery_once 7 "$IOS_TEST_DIR" "retry-device" retry_command
[[ "$RETRY_CALLS" -eq 1 ]]
[[ -f "$IOS_TEST_DIR/driver-recovery-attempt-1/debug/maestro.log" ]]
grep -Fq 'first attempt output' "$IOS_TEST_DIR/driver-recovery-attempt-1/run.log"

# A driver-looking error after any command started is not safe to replay.
RETRY_CALLS=0
printf '%s\n' \
  'IOSDriverTimeoutException: driver died' \
  'maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app RUNNING' \
  >"$IOS_TEST_DIR/debug/maestro.log"
set +e
run_ios_driver_recovery_once 7 "$IOS_TEST_DIR" "retry-device" retry_command
recovery_result=$?
set -e
[[ "$recovery_result" -eq 7 ]]
[[ "$RETRY_CALLS" -eq 0 ]]

# A failed simulator restart returns the original result and never replays.
RETRY_CALLS=0
XCRUN_BOOTSTATUS_RESULT=1
printf '%s\n' 'IOSDriverTimeoutException: driver failed during launch' \
  >"$IOS_TEST_DIR/debug/maestro.log"
set +e
run_ios_driver_recovery_once 7 "$IOS_TEST_DIR" "retry-device" retry_command
recovery_result=$?
set -e
[[ "$recovery_result" -eq 7 ]]
[[ "$RETRY_CALLS" -eq 0 ]]
grep -Fq 'iOS Simulator restart failed' <<<"$NOTES"

echo "iOS device selection tests passed"
