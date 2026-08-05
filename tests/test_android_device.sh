#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/android_device.sh
source "$ROOT/scripts/android_device.sh"

NOTES=""
note() {
  NOTES+="$*"$'\n'
}

MAESTRO_RESULT=0
MAESTRO_OUTPUT=""
maestro() {
  printf '%s' "$MAESTRO_OUTPUT"
  return "$MAESTRO_RESULT"
}

AVD_LIST=""
fake_emulator() {
  [[ "${1:-}" == "-list-avds" ]] || return 64
  printf '%s\n' "$AVD_LIST"
}

AVDMANAGER_RESULT=0
AVDMANAGER_REGISTERS=1
AVDMANAGER_NAME=""
AVDMANAGER_STDIN=""
AVDMANAGER_ARGS=""
AVDMANAGER_AVD_HOME=""
avdmanager() {
  AVDMANAGER_STDIN=$(cat)
  AVDMANAGER_ARGS="$*"
  AVDMANAGER_AVD_HOME="${ANDROID_AVD_HOME:-}"
  local previous=""
  local argument
  for argument in "$@"; do
    if [[ "$previous" == "--name" ]]; then
      AVDMANAGER_NAME="$argument"
    fi
    previous="$argument"
  done
  if [[ "$AVDMANAGER_RESULT" -eq 0 && "$AVDMANAGER_REGISTERS" == 1 ]]; then
    AVD_LIST="$AVDMANAGER_NAME"
  fi
  return "$AVDMANAGER_RESULT"
}

UNAME_MACHINE="x86_64"
uname() {
  [[ "${1:-}" == "-m" ]] || return 64
  printf '%s\n' "$UNAME_MACHINE"
}

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mobile-e2e-android-device.XXXXXX")"
START_LOG="$TEST_DIR/start-device.log"
ANDROID_AVD_HOME="$TEST_DIR/avd"
export ANDROID_AVD_HOME
cleanup_test_dir() {
  find "$TEST_DIR" -mindepth 1 -delete
  rmdir "$TEST_DIR"
}
trap cleanup_test_dir EXIT

AVD_LIST=""
AVDMANAGER_RESULT=0
AVDMANAGER_REGISTERS=1
create_headless_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$TEST_DIR/avdmanager.log"
[[ "$AVDMANAGER_NAME" == "Maestro_ANDROID_pixel_7_android-35" ]]
[[ "$AVDMANAGER_STDIN" == "no" ]]
[[ "$AVDMANAGER_ARGS" == *"--package system-images;android-35;google_apis;x86_64"* ]]
[[ "$AVDMANAGER_ARGS" == *"--abi x86_64"* ]]
[[ "$AVDMANAGER_AVD_HOME" == "$TEST_DIR/avd" ]]
[[ -d "$ANDROID_AVD_HOME" ]]
grep -Fq "ANDROID_AVD_HOME: $TEST_DIR/avd" "$TEST_DIR/avdmanager.log"

AVD_LIST=""
UNAME_MACHINE="arm64"
create_headless_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$TEST_DIR/avdmanager.log"
[[ "$AVDMANAGER_ARGS" == *"--package system-images;android-35;google_apis;arm64-v8a"* ]]
[[ "$AVDMANAGER_ARGS" == *"--abi arm64-v8a"* ]]

AVD_LIST=""
UNAME_MACHINE="x86_64"
AVDMANAGER_RESULT=1
if create_headless_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$TEST_DIR/avdmanager.log"; then
  echo "expected headless AVD creation failure to propagate" >&2
  exit 1
fi

AVD_LIST=""
AVDMANAGER_RESULT=0
AVDMANAGER_REGISTERS=0
if create_headless_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$TEST_DIR/avdmanager.log"; then
  echo "expected headless AVD creation to fail when avdmanager does not register it" >&2
  exit 1
fi
grep -Fq "exited successfully but did not register" "$TEST_DIR/avdmanager.log"
AVDMANAGER_REGISTERS=1

MAESTRO_RESULT=1
AVD_LIST=""
MAESTRO_OUTPUT="Created Android emulator: Maestro_ANDROID_pixel_7_android-35 (system-images;android-35;google_apis;x86_64)"
create_maestro_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$START_LOG"
grep -Fq "using the direct headless launcher" <<<"$NOTES"
grep -Fq "exited with status 1 after creating the AVD" "$START_LOG"

NOTES=""
MAESTRO_RESULT=1
MAESTRO_OUTPUT=""
AVD_LIST="Maestro_ANDROID_pixel_7_android-35"
create_maestro_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$START_LOG"

NOTES=""
MAESTRO_RESULT=1
AVD_LIST=""
if create_maestro_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$START_LOG"; then
  echo "expected provisioning failure when no AVD exists" >&2
  exit 1
fi

NOTES=""
MAESTRO_RESULT=1
AVD_LIST="Maestro_ANDROID_pixel_6_android-33"
MAESTRO_OUTPUT="Created Android emulator: Maestro_ANDROID_pixel_6_android-33 (system-images;android-33;google_apis;x86_64)"
if create_maestro_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$START_LOG"; then
  echo "expected provisioning failure when only a stale, wrong AVD exists" >&2
  exit 1
fi

NOTES=""
MAESTRO_RESULT=0
AVD_LIST=""
MAESTRO_OUTPUT=""
if create_maestro_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$START_LOG"; then
  echo "expected provisioning failure when Maestro exits successfully without creating an AVD" >&2
  exit 1
fi

NOTES=""
MAESTRO_RESULT=0
AVD_LIST="Maestro_ANDROID_pixel_7_android-35"
MAESTRO_OUTPUT=""
create_maestro_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$START_LOG"

TRANSPORT_ARTIFACTS="$TEST_DIR/transport"
mkdir -p "$TRANSPORT_ARTIFACTS/debug"
printf '%s\n' \
  '16:39:00.482 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Define variables RUNNING' \
  '16:39:00.487 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Apply configuration RUNNING' \
  '16:39:01.223 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Run ../scripts/setup_run.js RUNNING' \
  '16:39:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" with clear state RUNNING' \
  '16:39:01.644 [ERROR] maestro.orchestra.Orchestra.executeCommands: [Command execution] CommandFailed: Command failed (host:transport:emulator-5554): device offline' \
  'DeviceServerDiedException: Device server died during deviceInfo' \
  '16:39:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" with clear state FAILED' \
  >"$TRANSPORT_ARTIFACTS/debug/maestro.log"
printf '%s\n' 'first Android attempt' >"$TRANSPORT_ARTIFACTS/run.log"
android_maestro_transport_failed_at_launch "$TRANSPORT_ARTIFACTS"

ADB_STATE="device"
ADB_BOOTED="1"
adb() {
  if [[ "$*" == "start-server" ]]; then
    return 0
  elif [[ "$*" == *" get-state" ]]; then
    printf '%s\n' "$ADB_STATE"
  elif [[ "$*" == *" shell getprop sys.boot_completed" ]]; then
    printf '%s\n' "$ADB_BOOTED"
  else
    return 64
  fi
}
ANDROID_RETRY_CALLS=0
android_retry_command() {
  ANDROID_RETRY_CALLS=$((ANDROID_RETRY_CALLS + 1))
  return 0
}
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command
[[ "$ANDROID_RETRY_CALLS" -eq 1 ]]
[[ -f "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/debug/maestro.log" ]]
grep -Fq 'first Android attempt' \
  "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/run.log"

ANDROID_RETRY_CALLS=0
printf '%s\n' \
  '16:39:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" RUNNING' \
  '16:39:01.644 [ERROR] maestro.orchestra.Orchestra.executeCommands: [Command execution] CommandFailed: device offline' \
  '16:39:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" FAILED' \
  '16:39:01.680 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Tap on id: login_button RUNNING' \
  >"$TRANSPORT_ARTIFACTS/debug/maestro.log"
set +e
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command
android_recovery_result=$?
set -e
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]

# A side-effect-capable command before launch makes full-flow replay unsafe.
printf '%s\n' \
  '16:39:00.482 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Run ../scripts/send_inbox_message.js RUNNING' \
  '16:39:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" RUNNING' \
  '16:39:01.644 [ERROR] maestro.orchestra.Orchestra.executeCommands: [Command execution] CommandFailed: device offline' \
  '16:39:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" FAILED' \
  >"$TRANSPORT_ARTIFACTS/debug/maestro.log"
set +e
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command
android_recovery_result=$?
set -e
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]

# A transport failure on any later launch must not replay a flow whose earlier
# launch may already have produced SDK and backend side effects.
printf '%s\n' \
  '16:39:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" RUNNING' \
  '16:39:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" COMPLETED' \
  '16:40:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" RUNNING' \
  '16:40:01.644 [ERROR] maestro.orchestra.Orchestra.executeCommands: [Command execution] CommandFailed: device offline' \
  '16:40:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" FAILED' \
  >"$TRANSPORT_ARTIFACTS/debug/maestro.log"
set +e
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command
android_recovery_result=$?
set -e
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]

# A device that never reconnects returns the original Maestro result and does
# not invoke the retry command.
printf '%s\n' \
  '16:39:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" RUNNING' \
  '16:39:01.644 [ERROR] maestro.orchestra.Orchestra.executeCommands: [Command execution] CommandFailed: device offline' \
  '16:39:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" FAILED' \
  >"$TRANSPORT_ARTIFACTS/debug/maestro.log"
ADB_STATE="offline"
ADB_BOOTED="0"
ANDROID_DEVICE_RECONNECT_TIMEOUT_SECONDS=1
set +e
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command
android_recovery_result=$?
set -e
unset ANDROID_DEVICE_RECONNECT_TIMEOUT_SECONDS
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]

echo "Android device fallback tests passed"
