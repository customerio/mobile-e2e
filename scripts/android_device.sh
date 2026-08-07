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

  avd_home="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
  mkdir -p "$avd_home"
  export ANDROID_AVD_HOME="$avd_home"
  if [[ -e "$avd_home/$expected_avd_name.ini" ||
        -e "$avd_home/$expected_avd_name.avd" ]]; then
    printf 'Stale AVD registration found at %s but the emulator did not list it; refusing to overwrite it. Remove or rename the stale path, or set ANDROID_AVD_NAME.\n' \
      "$avd_home/$expected_avd_name" >"$create_log"
    return 1
  fi

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

# Detect the narrow hosted-runner race where ADB goes offline while Maestro's
# first launchApp command is starting. Only Maestro's configuration/setup
# commands may precede it, and no later flow command may begin, because replaying
# either side of the launch could duplicate SDK or backend mutations.
android_maestro_transport_failed_at_launch() {
  local artifact_dir="$1"
  local maestro_log="$artifact_dir/debug/maestro.log"
  [[ -f "$maestro_log" ]] || return 1
  grep -E -q 'device offline|DeviceServerDiedException' "$maestro_log" || return 1
  awk '
    !launch_started && /onCommandStart:/ {
      if (/onCommandStart: Launch app/) launch_started = 1
      else if ($0 !~ /onCommandStart: (Define variables|Apply configuration|Run .*setup_run\.js|Run flow when Platform is )/) unsafe_before_launch = 1
      next
    }
    launch_started && /onCommandFinished: Launch app.*FAILED/ { launch_failed = 1; next }
    launch_started && /onCommandStart:/ { later_command_started = 1 }
    END { exit !(launch_started && launch_failed && !unsafe_before_launch && !later_command_started) }
  ' "$maestro_log"
}

wait_for_android_device_reconnect() {
  local device_id="$1"
  local timeout_seconds="${ANDROID_DEVICE_RECONNECT_TIMEOUT_SECONDS:-60}"
  local deadline state booted
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 2
  adb start-server >/dev/null 2>&1 || true
  deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    state=$(adb -s "$device_id" get-state 2>/dev/null || true)
    booted=$(adb -s "$device_id" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
    if [[ "$state" == "device" && "$booted" == "1" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

preserve_android_transport_failure() {
  local artifact_dir="$1"
  local retry_dir="$artifact_dir/device-recovery-attempt-1"
  local diagnostic
  mkdir -p "$retry_dir"
  find "$retry_dir" -mindepth 1 -delete
  cp -R "$artifact_dir/debug" "$retry_dir/debug"
  for diagnostic in \
    run.log report.xml report.html sink.stderr sink.jsonl \
    sdk-live.log device-live.log; do
    if [[ -f "$artifact_dir/$diagnostic" ]]; then
      cp "$artifact_dir/$diagnostic" "$retry_dir/$diagnostic"
    fi
  done
}

run_android_transport_recovery_once() {
  local initial_result="$1"
  local artifact_dir="$2"
  local device_id="$3"
  local recovery_attempt_was_set="${E2E_RECOVERY_ATTEMPT+x}"
  local recovery_attempt_value="${E2E_RECOVERY_ATTEMPT:-}"
  shift 3

  [[ "$initial_result" -ne 0 ]] || return 0
  android_maestro_transport_failed_at_launch "$artifact_dir" || return "$initial_result"
  note "Android device went offline during the first app launch; waiting for ADB and retrying once"
  preserve_android_transport_failure "$artifact_dir"
  if ! wait_for_android_device_reconnect "$device_id"; then
    note "Android device did not reconnect; preserving the original Maestro failure"
    return "$initial_result"
  fi
  local retry_result
  export E2E_RECOVERY_ATTEMPT=1
  "$@"
  retry_result=$?
  if [[ "$recovery_attempt_was_set" == x ]]; then
    export E2E_RECOVERY_ATTEMPT="$recovery_attempt_value"
  else
    unset E2E_RECOVERY_ATTEMPT
  fi
  if [[ "$retry_result" -eq 0 ]]; then
    printf '\nRecovered from an Android device transport failure after reconnecting and retrying once. The first attempt is in device-recovery-attempt-1/.\n' \
      >>"$artifact_dir/run.log"
  else
    printf '\nRetried after an Android device transport failure, but the retry also failed with exit %s. The first attempt is in device-recovery-attempt-1/.\n' \
      "$retry_result" >>"$artifact_dir/run.log"
  fi
  return "$retry_result"
}
