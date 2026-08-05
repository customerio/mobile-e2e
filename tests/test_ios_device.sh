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

MULTI_BOOTED_JSON='{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
      {"name":"iPhone 16 Pro","udid":"first-booted","state":"Booted"},
      {"name":"iPhone 17 Pro","udid":"selected-booted","state":"Booted"}
    ]
  }
}'
booted=$(printf '%s' "$MULTI_BOOTED_JSON" | select_booted_ios_device)
[[ "$booted" == "first-booted" ]]
printf '%s' "$MULTI_BOOTED_JSON" | ios_device_is_booted "selected-booted"
if printf '%s' "$MULTI_BOOTED_JSON" | ios_device_is_booted "not-booted"; then
  echo "expected an unknown simulator not to be classified as booted" >&2
  exit 1
fi

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

# Maestro can exit before xcodebuild writes its final NSMachErrorDomain failure.
# Sustained status polling without a ready transition is the synchronous signal.
: >"$IOS_TEST_DIR/debug/maestro.log"
for _ in $(seq 1 60); do
  printf '%s\n' \
    'xcTestDriverStatusCheck: [Failed] Perform XCUITest driver status check, exception: java.net.ConnectException: Failed to connect to /127.0.0.1:51504' \
    >>"$IOS_TEST_DIR/debug/maestro.log"
done
printf '%s\n' 'XCUITest launch still running; no terminal error yet' \
  >"$IOS_TEST_DIR/debug/xctest_runner_test.log"
ios_maestro_driver_failed "$IOS_TEST_DIR" || {
  echo "expected sustained XCUITest polling to be recoverable" >&2
  exit 1
}

# A normal startup has a bounded number of failed polls followed by [Done].
: >"$IOS_TEST_DIR/debug/maestro.log"
for _ in $(seq 1 14); do
  printf '%s\n' \
    'xcTestDriverStatusCheck: [Failed] Perform XCUITest driver status check, exception: java.net.ConnectException: Failed to connect to /127.0.0.1:51504' \
    >>"$IOS_TEST_DIR/debug/maestro.log"
done
printf '%s\n' 'xcTestDriverStatusCheck: [Done] Perform XCUITest driver status check' \
  >>"$IOS_TEST_DIR/debug/maestro.log"
printf '%s\n' 'Assertion is false: expected SDK content is visible' \
  >"$IOS_TEST_DIR/debug/xctest_runner_test.log"
if ios_maestro_driver_failed "$IOS_TEST_DIR"; then
  echo "expected normal startup polling not to look like a driver failure" >&2
  exit 1
fi

# Once the driver became ready, later polling can never reclassify the run as a
# safe startup failure; the flow may already have mutated the backend.
for _ in $(seq 1 60); do
  printf '%s\n' \
    'xcTestDriverStatusCheck: [Failed] Perform XCUITest driver status check, exception: java.net.ConnectException: Failed to connect to /127.0.0.1:51504' \
    >>"$IOS_TEST_DIR/debug/maestro.log"
done
if ios_maestro_driver_failed "$IOS_TEST_DIR"; then
  echo "expected a prior driver-ready transition to remain fail-closed" >&2
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
RETRY_RESULT=0
retry_command() {
  RETRY_CALLS=$((RETRY_CALLS + 1))
  # Mirror run.sh's top-level cleanup gate: a nested retry must retain the
  # first-attempt bundle that the recovery wrapper just captured.
  if [[ "${E2E_RECOVERY_ATTEMPT:-0}" != 1 ]]; then
    find "$IOS_TEST_DIR/driver-recovery-attempt-1" -mindepth 1 -delete
    rmdir "$IOS_TEST_DIR/driver-recovery-attempt-1"
  fi
  [[ -d "$IOS_TEST_DIR/driver-recovery-attempt-1" ]] || return 65
  return "$RETRY_RESULT"
}
printf '%s\n' 'IOSDriverTimeoutException: iOS driver not ready in time' \
  >"$IOS_TEST_DIR/debug/maestro.log"
printf '%s\n' 'first attempt output' >"$IOS_TEST_DIR/run.log"
printf '%s\n' 'first live SDK diagnostics' >"$IOS_TEST_DIR/sdk-live.log"
run_ios_driver_recovery_once 7 "$IOS_TEST_DIR" "retry-device" retry_command
[[ "$RETRY_CALLS" -eq 1 ]]
[[ -f "$IOS_TEST_DIR/driver-recovery-attempt-1/debug/maestro.log" ]]
grep -Fq 'first attempt output' "$IOS_TEST_DIR/driver-recovery-attempt-1/run.log"
grep -Fq 'first live SDK diagnostics' \
  "$IOS_TEST_DIR/driver-recovery-attempt-1/sdk-live.log"
grep -Fq 'Recovered from an iOS driver startup failure' "$IOS_TEST_DIR/run.log"
[[ -z "${E2E_RECOVERY_ATTEMPT+x}" ]]

# A failed retry must keep the retry status and must not claim recovery.
RETRY_CALLS=0
RETRY_RESULT=9
printf '%s\n' 'IOSDriverTimeoutException: iOS driver not ready in time' \
  >"$IOS_TEST_DIR/debug/maestro.log"
: >"$IOS_TEST_DIR/run.log"
set +e
run_ios_driver_recovery_once 7 "$IOS_TEST_DIR" "retry-device" retry_command
recovery_result=$?
set -e
[[ "$recovery_result" -eq 9 ]]
[[ "$RETRY_CALLS" -eq 1 ]]
grep -Fq 'retry also failed with exit 9' "$IOS_TEST_DIR/run.log"
if grep -Fq 'Recovered from an iOS driver startup failure' "$IOS_TEST_DIR/run.log"; then
  echo "expected a failed retry not to claim recovery" >&2
  exit 1
fi
RETRY_RESULT=0

# A driver-looking error after any command started is not safe to replay.
RETRY_CALLS=0
printf '%s\n' \
  'IOSDriverTimeoutException: driver died' \
  'maestro.cli.runner.TestSuiteInteractor.runFlow:  Running flow Message Inbox' \
  'maestro.cli.runner.TestSuiteInteractor.runFlow$lambda$17$lambda$5: Launch app with clear state RUNNING' \
  >"$IOS_TEST_DIR/debug/maestro.log"
set +e
run_ios_driver_recovery_once 7 "$IOS_TEST_DIR" "retry-device" retry_command
recovery_result=$?
set -e
[[ "$recovery_result" -eq 7 ]]
[[ "$RETRY_CALLS" -eq 0 ]]

# Benign startup polling followed by a product failure must not be classified
# as a driver failure. This is the common non-driver non-zero path.
RETRY_CALLS=0
: >"$IOS_TEST_DIR/debug/maestro.log"
for _ in $(seq 1 14); do
  printf '%s\n' \
    'xcTestDriverStatusCheck: [Failed] Perform XCUITest driver status check, exception: java.net.ConnectException: Failed to connect to /127.0.0.1:51504' \
    >>"$IOS_TEST_DIR/debug/maestro.log"
done
printf '%s\n' \
  'xcTestDriverStatusCheck: [Done] Perform XCUITest driver status check' \
  'maestro.cli.runner.TestSuiteInteractor.runFlow:  Running flow Message Inbox' \
  >>"$IOS_TEST_DIR/debug/maestro.log"
set +e
run_ios_driver_recovery_once 7 "$IOS_TEST_DIR" "retry-device" retry_command
recovery_result=$?
set -e
[[ "$recovery_result" -eq 7 ]]
[[ "$RETRY_CALLS" -eq 0 ]]

# A completed commands artifact is a final flow-start fallback.
RETRY_CALLS=0
printf '%s\n' 'IOSDriverTimeoutException: driver died' \
  >"$IOS_TEST_DIR/debug/maestro.log"
printf '%s\n' '[]' >"$IOS_TEST_DIR/debug/commands-(flow).json"
set +e
run_ios_driver_recovery_once 7 "$IOS_TEST_DIR" "retry-device" retry_command
recovery_result=$?
set -e
rm -f "$IOS_TEST_DIR/debug/commands-(flow).json"
[[ "$recovery_result" -eq 7 ]]
[[ "$RETRY_CALLS" -eq 0 ]]

# Maestro 2.x nests commands.json below a flow-named directory. It carries the
# same fail-closed meaning: flow execution started, so recovery must not replay.
mkdir -p "$IOS_TEST_DIR/debug/Message Inbox"
printf '%s\n' '[]' >"$IOS_TEST_DIR/debug/Message Inbox/commands.json"
set +e
run_ios_driver_recovery_once 7 "$IOS_TEST_DIR" "retry-device" retry_command
recovery_result=$?
set -e
find "$IOS_TEST_DIR/debug/Message Inbox" -mindepth 1 -delete
rmdir "$IOS_TEST_DIR/debug/Message Inbox"
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
