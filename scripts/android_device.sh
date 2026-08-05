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

resolve_android_avdmanager() {
  local resolved candidate sdk_root

  resolved=$(command -v avdmanager 2>/dev/null || true)
  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return
  fi

  for sdk_root in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}"; do
    [[ -n "$sdk_root" ]] || continue
    for candidate in \
      "$sdk_root/cmdline-tools/latest/bin/avdmanager" \
      "$sdk_root"/cmdline-tools/*/bin/avdmanager \
      "$sdk_root/tools/bin/avdmanager"; do
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return
      fi
    done
  done
  return 1
}

resolve_android_avd_abi() {
  if [[ -n "${ANDROID_AVD_ABI:-}" ]]; then
    printf '%s\n' "$ANDROID_AVD_ABI"
    return
  fi

  case "$(uname -m)" in
    arm64|aarch64) printf '%s\n' 'arm64-v8a' ;;
    x86_64|amd64) printf '%s\n' 'x86_64' ;;
    *) return 1 ;;
  esac
}

# Provision a CI AVD without relying on avdmanager's interactive hardware-
# profile prompt. New command-line tools can exit successfully on EOF while
# leaving no <name>.ini registration, which is what Maestro start-device hit on
# GitHub's Ubuntu image. Supplying "no" makes the operation deterministic.
create_headless_android_avd() {
  local emulator_bin="$1"
  local expected_avd_name="$2"
  local create_log="$3"
  local avdmanager_bin abi system_image avd_home

  avdmanager_bin=$(resolve_android_avdmanager || true)
  [[ -n "$avdmanager_bin" ]] || {
    echo "Android avdmanager was not found on PATH or under the configured SDK" >"$create_log"
    return 1
  }
  abi=$(resolve_android_avd_abi || true)
  [[ -n "$abi" ]] || {
    echo "unsupported Android emulator host architecture: $(uname -m)" >"$create_log"
    return 1
  }
  system_image="system-images;android-35;google_apis;$abi"
  avd_home="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
  mkdir -p "$avd_home"
  export ANDROID_AVD_HOME="$avd_home"

  note "creating Android virtual device for headless execution"
  printf 'avdmanager: %s\nANDROID_AVD_HOME: %s\nsystem image: %s\n' \
    "$avdmanager_bin" "$ANDROID_AVD_HOME" "$system_image" >"$create_log"
  if ! "$avdmanager_bin" create avd \
    --force \
    --name "$expected_avd_name" \
    --package "$system_image" \
    --tag google_apis \
    --abi "$abi" \
    --device pixel_7 \
    >>"$create_log" 2>&1 <<<"no"; then
    return 1
  fi

  if ! android_avd_is_listed "$emulator_bin" "$expected_avd_name"; then
    echo "avdmanager exited successfully but did not register $expected_avd_name" >>"$create_log"
    return 1
  fi
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
