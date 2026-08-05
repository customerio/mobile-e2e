#!/usr/bin/env bash

# Check the emulator's AVD listing without exposing callers to a pipeline whose
# producer can be turned into a failure by grep exiting early under pipefail.
android_avd_is_listed() {
  local emulator_bin="$1"
  local expected_avd_name="$2"
  local avd_list

  avd_list=$("$emulator_bin" -list-avds 2>/dev/null || true)
  grep -Fxq "$expected_avd_name" <<<"$avd_list"
}

# Ask Maestro to provision its standard Android AVD. On a hosted Linux runner,
# Maestro can successfully create the AVD and then return non-zero because its
# GUI-oriented launch attempt cannot open a display. The runner's subsequent
# `emulator -list-avds` can also return an empty list there, so accept Maestro's
# exact post-avdmanager success message as equivalent provisioning evidence.
create_maestro_android_avd() {
  local emulator_bin="$1"
  local expected_avd_name="$2"
  local start_log="$3"
  local maestro_status=0

  note "creating and starting Maestro Android virtual device"
  maestro start-device --platform android --device-model pixel_7 --device-os android-35 \
    >"$start_log" 2>&1 || maestro_status=$?

  # start-device combines provisioning and launching. Accept its non-zero
  # status only when provisioning demonstrably completed.
  if android_avd_is_listed "$emulator_bin" "$expected_avd_name" ||
     grep -Fq "Created Android emulator: $expected_avd_name (" "$start_log"; then
    if [[ "$maestro_status" -ne 0 ]]; then
      printf '\nMaestro start-device exited with status %s after creating the AVD.\n' \
        "$maestro_status" >>"$start_log"
      note "Maestro created the Android AVD but could not launch it; using the direct headless launcher"
    fi
    return 0
  fi

  if [[ "$maestro_status" -eq 0 ]]; then
    return 1
  fi
  return "$maestro_status"
}
