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
avdmanager() {
  AVDMANAGER_STDIN=$(cat)
  AVDMANAGER_ARGS="$*"
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

echo "Android device fallback tests passed"
