#!/usr/bin/env bash

# Ask Maestro to provision its standard Android AVD. On a hosted Linux runner,
# Maestro can successfully create the AVD and then return non-zero because its
# GUI-oriented launch attempt cannot open a display. That is still a successful
# provisioning result: the top-level runner will launch the AVD itself with
# explicit headless flags.
create_maestro_android_avd() {
  local emulator_bin="$1"
  local expected_avd_name="$2"
  local start_log="$3"
  local maestro_status=0

  note "creating and starting Maestro Android virtual device"
  maestro start-device --platform android --device-model pixel_7 --device-os android-35 \
    >"$start_log" 2>&1 || maestro_status=$?

  if [[ "$maestro_status" -eq 0 ]]; then
    return 0
  fi

  # start-device combines provisioning and launching. Accept its non-zero
  # status only when provisioning demonstrably completed.
  if "$emulator_bin" -list-avds | grep -Fxq "$expected_avd_name"; then
    printf '\nMaestro start-device exited with status %s after creating the AVD.\n' \
      "$maestro_status" >>"$start_log"
    note "Maestro created the Android AVD but could not launch it; using the direct headless launcher"
    return 0
  fi

  return "$maestro_status"
}
