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

select_booted_ios_device() {
  jq -r '[.devices[][] | select(.state == "Booted") |
    select((.name | startswith("iPhone")) or (.name | startswith("Maestro iPhone")))][0].udid // empty'
}

ios_device_is_booted() {
  local device_id="$1"
  jq -e --arg device_id "$device_id" \
    'any(.devices[][]; .state == "Booted" and .udid == $device_id)' \
    >/dev/null
}

# Maestro 2.x can intermittently fail before the first flow command when its
# XCUITest runner dies during launch. Keep recovery scoped to the exact driver
# startup signatures so product assertions are never retried or hidden.
ios_maestro_driver_failed() {
  local artifact_dir="$1"
  local maestro_log="$artifact_dir/debug/maestro.log"
  local driver_log
  local failed_poll_count
  [[ -d "$artifact_dir/debug" ]] || return 1
  for driver_log in \
    "$maestro_log" \
    "$artifact_dir/debug"/xctest_runner_*.log; do
    [[ -f "$driver_log" ]] || continue
    if grep -E -q \
      'IOSDriverTimeoutException|iOS driver not ready in time|NSMachErrorDomain Code=-308|Failed to launch app with identifier: dev\.mobile\.maestro-driver-iosUITests\.xctrunner' \
      "$driver_log"; then
      return 0
    fi
  done

  # xcodebuild can write its terminal NSMachError several seconds after
  # Maestro gives up. Normal boots also produce a handful of failed status
  # polls, so only treat sustained polling with no ready transition as the
  # synchronous form of the startup timeout. Hosted failures have ~190 polls;
  # passing archived runs have 10-16 before [Done].
  if [[ -f "$maestro_log" ]]; then
    failed_poll_count=$(grep -E -c \
      'xcTestDriverStatusCheck: \[Failed\].*ConnectException: Failed to connect to /127\.0\.0\.1:[0-9]+' \
      "$maestro_log" || true)
    if [[ "$failed_poll_count" -ge 60 ]] &&
       ! grep -E -q 'xcTestDriverStatusCheck: \[Done\]' "$maestro_log"; then
      return 0
    fi
  fi
  return 1
}

# The CliConsoleListener marker used by older Maestro releases is absent from
# current 2.x logs. TestSuiteInteractor's stable flow-entry line is emitted
# before any real command; lifecycle lines are a secondary signal. A completed
# commands artifact is a final fallback. Any signal makes replay unsafe.
ios_maestro_flow_started() {
  local artifact_dir="$1"
  local debug_dir="$artifact_dir/debug"
  local maestro_log="$debug_dir/maestro.log"
  local commands_file

  if [[ -f "$maestro_log" ]] &&
     grep -E -q \
       'maestro\.cli\.runner\.TestSuiteInteractor\.runFlow: +Running flow |maestro\.cli\.runner\.TestSuiteInteractor\.runFlow.* (RUNNING|COMPLETED|FAILED|SKIPPED)$' \
       "$maestro_log"; then
    return 0
  fi
  [[ -d "$debug_dir" ]] || return 1
  for commands_file in "$debug_dir"/commands-*.json; do
    [[ -f "$commands_file" ]] && return 0
  done
  # Maestro 2.x ignores --flatten-debug-output for the per-flow command file
  # and nests it below a flow-named directory.
  commands_file=$(find "$debug_dir" -type f -name commands.json \
    -print -quit 2>/dev/null || true)
  if [[ -n "$commands_file" ]]; then
    return 0
  fi
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
  for diagnostic in \
    run.log report.xml report.html sink.stderr sink.jsonl \
    sdk-live.log device-live.log; do
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
  local recovery_attempt_was_set="${E2E_RECOVERY_ATTEMPT+x}"
  local recovery_attempt_value="${E2E_RECOVERY_ATTEMPT:-}"
  shift 3

  [[ "$initial_result" -ne 0 ]] || return 0
  ios_maestro_driver_failed "$artifact_dir" || return "$initial_result"
  if ios_maestro_flow_started "$artifact_dir"; then
    return "$initial_result"
  fi

  note "Maestro's iOS driver died before the flow started; restarting the simulator and retrying once"
  preserve_ios_driver_failure "$artifact_dir"
  if ! restart_ios_device "$device_id"; then
    note "iOS Simulator restart failed; preserving the original Maestro failure"
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
    printf '\nRecovered from an iOS driver startup failure by restarting the simulator and retrying once. The first attempt is in driver-recovery-attempt-1/.\n' \
      >>"$artifact_dir/run.log"
  else
    printf '\nRetried after an iOS driver startup failure, but the retry also failed with exit %s. The first attempt is in driver-recovery-attempt-1/.\n' \
      "$retry_result" >>"$artifact_dir/run.log"
  fi
  return "$retry_result"
}
