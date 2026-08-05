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

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mobile-e2e-android-device.XXXXXX")"
START_LOG="$TEST_DIR/start-device.log"
cleanup_test_dir() {
  find "$TEST_DIR" -mindepth 1 -delete
  rmdir "$TEST_DIR"
}
trap cleanup_test_dir EXIT

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
