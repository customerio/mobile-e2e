#!/usr/bin/env bash

# Select the newest available runtime for the requested iPhone model. GitHub's
# macOS images contain the same model under several runtimes, and simctl's JSON
# order is oldest-first. Pairing Xcode 26.3 with the first iOS 26.0 simulator
# caused Maestro's XCUITest runner to die during launch; the newest runtime is
# the closest match for the active Xcode SDK.
select_ios_device() {
  local preferred_name="${1:-}"

  jq -r --arg preferred "$preferred_name" '
    [.devices | to_entries[] | .key as $runtime | .value[] |
      select(.isAvailable == true) |
      select((.name | startswith("iPhone")) or (.name | startswith("Maestro iPhone"))) |
      . + {runtime: $runtime}
    ] as $phones |
    def runtime_version:
      [.runtime | scan("[0-9]+") | tonumber];
    def newest:
      sort_by(runtime_version) | last;
    def on_newest_runtime:
      (map(. + {runtimeVersion: runtime_version})) as $versioned |
      ($versioned | map(.runtimeVersion) | max) as $latest |
      $versioned | map(select(.runtimeVersion == $latest));
    if $preferred != "" then
      (($phones | map(select(.name == $preferred)) | newest).udid // empty)
    else
      ($phones | on_newest_runtime) as $newest_phones |
      ((($newest_phones | map(select(.name == "Maestro iPhone 17 Pro")))[0] //
        ($newest_phones | map(select(.name == "iPhone 17 Pro")))[0] //
        $newest_phones[0]).udid // empty)
    end'
}

# Maestro 2.x can intermittently fail before the first flow command when its
# XCUITest runner dies during launch. Keep recovery scoped to the exact driver
# startup signatures so product assertions are never retried or hidden.
ios_maestro_driver_failed() {
  local artifact_dir="$1"
  local driver_log
  [[ -d "$artifact_dir/debug" ]] || return 1
  for driver_log in \
    "$artifact_dir/debug/maestro.log" \
    "$artifact_dir/debug"/xctest_runner_*.log; do
    [[ -f "$driver_log" ]] || continue
    if grep -E -q \
      'IOSDriverTimeoutException|iOS driver not ready in time|NSMachErrorDomain Code=-308|Failed to launch app with identifier: dev\.mobile\.maestro-driver-iosUITests\.xctrunner' \
      "$driver_log"; then
      return 0
    fi
  done
  return 1
}

restart_ios_device() {
  local device_id="$1"
  local timeout_seconds="${IOS_SIMULATOR_BOOT_TIMEOUT_SECONDS:-180}"
  local bootstatus_pid deadline
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 2

  xcrun simctl shutdown "$device_id" >/dev/null 2>&1 || true
  xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$device_id" -b &
  bootstatus_pid=$!
  deadline=$((SECONDS + timeout_seconds))
  while kill -0 "$bootstatus_pid" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      kill "$bootstatus_pid" >/dev/null 2>&1 || true
      wait "$bootstatus_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done
  wait "$bootstatus_pid"
}

preserve_ios_driver_failure() {
  local artifact_dir="$1"
  local retry_dir="$artifact_dir/driver-recovery-attempt-1"
  local diagnostic
  mkdir -p "$retry_dir"
  find "$retry_dir" -mindepth 1 -delete
  cp -R "$artifact_dir/debug" "$retry_dir/debug"
  for diagnostic in run.log report.xml report.html sink.stderr; do
    if [[ -f "$artifact_dir/$diagnostic" ]]; then
      cp "$artifact_dir/$diagnostic" "$retry_dir/$diagnostic"
    fi
  done
}

# Run the supplied command at most once, and only when the initial non-zero
# result came from an iOS driver launch failure before the first flow command.
run_ios_driver_recovery_once() {
  local initial_result="$1"
  local artifact_dir="$2"
  local device_id="$3"
  shift 3

  [[ "$initial_result" -ne 0 ]] || return 0
  ios_maestro_driver_failed "$artifact_dir" || return "$initial_result"
  if [[ -f "$artifact_dir/debug/maestro.log" ]] &&
     grep -Fq 'maestro.cli.runner.CliConsoleListener.onCommandStart' \
       "$artifact_dir/debug/maestro.log"; then
    return "$initial_result"
  fi

  note "Maestro's iOS driver died before the flow started; restarting the simulator and retrying once"
  preserve_ios_driver_failure "$artifact_dir"
  if ! restart_ios_device "$device_id"; then
    note "iOS Simulator restart failed; preserving the original Maestro failure"
    return "$initial_result"
  fi
  "$@"
}
