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
  android_maestro_log_has_transport_drop "$artifact_dir" || return 1
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

# Detect the same transport drop (ADB offline or the Maestro driver dying) when it
# lands after the first launch but before the SDK identified this run's customer,
# for example while the login form is being filled in. Nothing customer-facing
# has happened yet, so replaying the flow is as safe as replaying a failed
# launch: setup_run.js mints a fresh customer and the app is still logged out.
# Once the run's email appears in the live SDK log the app is logged in, the
# retry would start from the wrong screen, so that case keeps its original
# failure. Any script other than setup_run.js and wait.js may have mutated the
# backend, so it also blocks the retry.
android_maestro_transport_failed_before_identify() {
  local artifact_dir="$1"
  local maestro_log="$artifact_dir/debug/maestro.log"
  local sink_log="$artifact_dir/sink.jsonl"
  local live_log="$artifact_dir/device-live.log"
  local email
  [[ -f "$maestro_log" && -f "$sink_log" && -f "$live_log" ]] || return 1
  android_maestro_log_has_transport_drop "$artifact_dir" || return 1
  email=$(grep -o '"email": "[^"]*"' "$sink_log" | tail -n 1 | cut -d'"' -f4)
  [[ -n "$email" ]] || return 1
  ! grep -F -q "$email" "$live_log" || return 1
  awk '
    /onCommandStart: Run .*\.js/ && $0 !~ /(setup_run|wait)\.js/ { unsafe = 1 }
    END { exit unsafe }
  ' "$maestro_log"
}

# Run one command, cutting it off once $SECONDS passes the deadline (an
# absolute $SECONDS value). A wedged ADB transport can leave adb waiting on the
# device forever. Every command gets at least 2 seconds, so a call made right at
# the deadline can still answer. Returns the command's status, or 124 when it
# was cut off.
android_run_until() {
  local deadline="$1" pid
  shift
  (( deadline >= SECONDS + 2 )) || deadline=$((SECONDS + 2))
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS > deadline )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    # `command` skips a shell function named sleep, so a stubbed sleep cannot
    # turn this poll into a busy loop.
    command sleep 0.1
  done
  wait "$pid"
}

# The serial evidence commands (log pulls, recording pulls, stopping the
# recorder) should use: the TCP serial while it answers, else the emulator
# serial, whose transport stays up when TCP drops. That keeps the evidence of a
# TCP drop reachable. With no separate emulator serial, the preferred one.
android_evidence_serial() {
  local preferred="$1"
  local emulator_serial="${2:-}"
  if [[ -z "$emulator_serial" || "$preferred" == "$emulator_serial" ]]; then
    printf '%s\n' "$preferred"
  elif [[ "$(android_run_until $((SECONDS + 10)) adb -s "$preferred" get-state 2>/dev/null)" == device ]]; then
    printf '%s\n' "$preferred"
  else
    printf '%s\n' "$emulator_serial"
  fi
}

# Whether adbd in the guest already listens on TCP port 5555 (0x15B3), from
# /proc/net. adbd listens there by default when it has no USB function, which
# would make `adb tcpip` and the adbd restart it causes unnecessary. A failed
# read counts as not listening, which keeps the `adb tcpip` path.
android_adbd_listens_on_tcp() {
  local serial="$1"
  local deadline="$2"
  local tables
  tables=$(android_run_until "$deadline" adb -s "$serial" shell cat /proc/net/tcp /proc/net/tcp6 2>/dev/null) || true
  grep -Eq '^ *[0-9]+: [0-9A-F]+:15B3 [0-9A-F]+:0000 0A ' <<<"$tables"
}

android_boot_id() {
  android_run_until "$2" adb -s "$1" shell cat /proc/sys/kernel/random/boot_id 2>/dev/null |
    tr -d '\r' || true
}

# The state of a guest network interface (eth0 unless named), from one
# `ip -o link` dump through the emulator serial: up when its flags carry UP and
# LOWER_UP and its state is not DOWN, down otherwise, and unknown when the dump
# has no line for it. On CI's API 35 image the per-interface reads (sysfs
# operstate, `ip -o link show eth0`) gave nothing usable while the dump worked
# in the same job, so only the dump is read. An unknown result logs what the
# dump returned, on stderr.
android_guest_link_state() {
  local serial="$1" iface="${2:-eth0}" dump line flags flags_re='<([^>]*)>' down_re=' state DOWN( |$)'
  dump=$(android_run_until $((SECONDS + 5)) adb -s "$serial" shell ip -o link 2>&1 | tr -d '\r' || true)
  line=$(awk -v name="$iface" '$2 == name ":" || index($2, name "@") == 1 { print; exit }' <<<"$dump")
  if ! [[ "$line" =~ $flags_re ]]; then
    printf '%s unreadable from ip -o link: %s\n' "$iface" "$(head -n 3 <<<"$dump" | cut -c 1-200 | paste -sd '|' -)" >&2
    printf '%s\n' unknown
    return 0
  fi
  flags=",${BASH_REMATCH[1]},"
  if [[ "$flags" == *,UP,* && "$flags" == *,LOWER_UP,* && ! "$line" =~ $down_re ]]; then
    printf '%s\n' up
  else
    printf '%s\n' down
  fi
}

# The fallback capture below has one deadline for all its queries, so a slow
# adb cannot stretch it: each query gets the smaller of its own limit and the
# time left (android_run_until's 2 s floor can take the last one a few seconds
# past it). Once the deadline has passed, or after the first query that is cut
# off (adb is then not answering), the queries left are skipped and named in
# one line.
ANDROID_DATA_LINK_CAPTURE_SECONDS=30

# One query of that capture: a name for the log, its own limit in seconds, then
# the command. Leaves the command's output (stdout and stderr) in
# android_capture_output and returns 0, or returns 1 when the query is skipped.
android_capture_query() {
  local name="$1" seconds="$2" left status=0
  shift 2
  android_capture_output=""
  left=$((android_capture_deadline - SECONDS))
  if [[ -z "$android_capture_stop" ]] && (( left <= 0 )); then
    android_capture_stop='capture deadline reached'
  fi
  if [[ -n "$android_capture_stop" ]]; then
    android_capture_skipped="${android_capture_skipped:+$android_capture_skipped, }$name"
    return 1
  fi
  (( seconds <= left )) || seconds=$left
  android_capture_output=$(android_run_until $((SECONDS + seconds)) "$@" 2>&1) ||
    status=$?
  if (( status == 124 )); then
    [[ -z "$android_capture_output" ]] || android_capture_output+=$'\n'
    android_capture_output+="(gave up after ${seconds}s)"
    android_capture_stop="$name timed out after ${seconds}s, capture stopped"
  fi
  return 0
}

# What the guest's network and telephony say when the switch ends on the
# emulator pipe, all within ANDROID_DATA_LINK_CAPTURE_SECONDS: the links and
# addresses (is eth0 up, has it 10.0.2.15); the mobile data, always-on,
# multi-SIM data and airplane mode settings; the modem's registration;
# telephony's data and service state; the slot-to-subscription mapping and the
# default data subscription (isub, ICCIDs redacted); and from the radio log:
# the network requests telephony was asked for, each with whether it was passed
# on to data setup (shouldApply, applied), PhoneSwitcher's choice of the data
# phone (radio and main logs), and data setup: requests added, evaluations and
# the reasons data is not allowed, setup and teardown calls to the modem and
# their results, and retries. None of it can fail the switch.
capture_android_data_link_evidence() {
  local serial="$1" setting radio="" main=""
  android_capture_deadline=$((SECONDS + ANDROID_DATA_LINK_CAPTURE_SECONDS))
  android_capture_stop=""
  android_capture_skipped=""
  if android_capture_query 'ip -o link' 10 adb -s "$serial" shell ip -o link; then
    printf -- '-- ip -o link\n%s\n' "$android_capture_output"
  fi
  if android_capture_query 'ip -4 -o addr' 10 adb -s "$serial" shell ip -4 -o addr; then
    printf -- '-- ip -4 -o addr\n%s\n' "$android_capture_output"
  fi
  for setting in mobile_data mobile_data_always_on multi_sim_data_call airplane_mode_on; do
    android_capture_query "settings $setting" 5 \
      adb -s "$serial" shell settings get global "$setting" || continue
    [[ "$setting" != mobile_data ]] ||
      printf -- '-- settings mobile_data / mobile_data_always_on / multi_sim_data_call / airplane_mode_on\n'
    printf '%s\n' "$android_capture_output"
  done
  if android_capture_query 'emu gsm status' 10 adb -s "$serial" emu gsm status; then
    printf -- '-- emu gsm status\n%s\n' "$android_capture_output"
  fi
  if android_capture_query 'dumpsys telephony.registry' 15 \
       adb -s "$serial" shell dumpsys telephony.registry; then
    printf -- '-- dumpsys telephony.registry (data and service state)\n'
    awk '/mDataConnectionState|mServiceState/ && n < 8 { print substr($0, 1, 600); n++ }' \
      <<<"$android_capture_output"
  fi
  if android_capture_query 'dumpsys isub' 15 adb -s "$serial" shell dumpsys isub; then
    printf -- '-- dumpsys isub (slot-to-subscription mapping and default data subscription, ICCIDs redacted)\n'
    awk 'NR <= 40 && /[Mm]odem count|[Ss]ubId=|Loaded=|mSimState|[Ee]rror|[Ee]xception|not found|[Cc]an.t find|gave up/ {
      gsub(/[Ii][Cc][Cc][Ii][Dd]=[^] ,}]*/, "iccId=<redacted>")
      gsub(/[Cc]ard[Ss]tring=[^] ,}]*/, "cardString=<redacted>")
      print substr($0, 1, 300)
    }' <<<"$android_capture_output"
  fi
  if android_capture_query 'logcat radio' 15 adb -s "$serial" logcat -d -b radio; then
    radio=$android_capture_output
  fi
  if android_capture_query 'logcat main' 15 adb -s "$serial" logcat -d -b main; then
    main=$android_capture_output
  fi
  if [[ -n "$radio$main" ]]; then
    # Whole lines: the shouldApply or applied verdict ends each one.
    printf -- '-- logcat radio (network requests, last 15)\n'
    awk '/TelephonyNetworkFactory/' <<<"$radio" | tail -n 15
    printf -- '-- logcat radio and main (PhoneSwitcher, last 30 each)\n'
    awk '/PhoneSwitcher/ { print substr($0, 1, 600) }' <<<"$radio" | tail -n 30
    awk '/PhoneSwitcher/ { print substr($0, 1, 600) }' <<<"$main" | tail -n 30
    printf -- '-- logcat radio (data setup, last 60)\n'
    awk '!/TelephonyNetworkFactory|PhoneSwitcher/ && (/SETUP_DATA_CALL|DEACTIVATE_DATA_CALL|DATA_CALL_LIST|[Dd]ata evaluation|[Dd]isallowed|[Nn]ot allowed|[Rr]eject|[Rr]etry|[Tt]ear ?[Dd]own|onSetupDataNetwork|SetupDataFailed|Re-evaluating|[Uu]nwanted|setupDataCall|deactivate|DataNetwork|DRM-|NetworkRequest:|Creating data network/) { print substr($0, 1, 400) }' <<<"$radio" |
      tail -n 60
  fi
  if [[ -n "$android_capture_stop" ]]; then
    printf -- '-- %s; skipped: %s\n' "$android_capture_stop" \
      "${android_capture_skipped:-nothing}"
  fi
  return 0
}

# Move ADB off the emulator's adb pipe and onto adbd's own TCP listener, which
# the emulator redirects from a host port. On hosted runners the pipe's bridge
# closes the host and guest ends together during load bursts (the host server
# logs "connection terminated: read failed" while adbd and the emulator keep
# running), which takes Maestro's driver down mid-flow. Sets ANDROID_ADB_SERIAL
# to the serial every later command should use, and ANDROID_EMULATOR_SERIAL to
# the one that console (emu) commands, reboots and guest diagnostics need. On by
# default only in CI and headless runs (CI or HEADLESS=1); ANDROID_ADB_TCP_PORT
# picks the host port, or turns it on or off anywhere. Any failure keeps the
# emulator serial: the run must never fail because of the switch.
# ANDROID_ADB_TCP_SWITCH says how it ended: off (not tried), tcp, other-device
# or timeout.
use_android_adb_over_tcp() {
  local emulator_serial="$1"
  local log="${2:-/dev/null}"
  local host_port="${ANDROID_ADB_TCP_PORT:-}"
  local timeout_seconds="${ANDROID_ADB_TCP_TIMEOUT_SECONDS:-60}"
  # connected_at is set before a connect that can block up to 10 s, so with the
  # default 12 s a failed connect is redialled on the next pass.
  local reconnect_seconds="${ANDROID_ADB_TCP_RECONNECT_SECONDS:-12}"
  local tcp_serial deadline started booted tcp_port emulator_boot tcp_boot redir
  local pass=0 state="" connected_at="" adbd_on_tcp=0 redirected=0
  ANDROID_EMULATOR_SERIAL="$emulator_serial"
  ANDROID_ADB_SERIAL="$emulator_serial"
  ANDROID_ADB_TCP_SWITCH=off
  if [[ -z "$host_port" ]]; then
    if [[ -z "${CI:-}" && "${HEADLESS:-0}" != 1 ]]; then
      note "adb transport: emulator pipe ($emulator_serial); TCP is the default only in CI or --headless (set ANDROID_ADB_TCP_PORT to use it)"
      return 0
    fi
    host_port=5600
  fi
  if [[ "$host_port" == off ]]; then
    note "adb transport: emulator pipe ($emulator_serial); ANDROID_ADB_TCP_PORT=off"
    return 0
  fi
  # 5554-5585 are the emulators' own console/adb ports: a redirect there fails, and
  # connecting to it reaches adbd through the pipe while reporting "tcp".
  if ! [[ "$host_port" =~ ^[1-9][0-9]*$ && "$timeout_seconds" =~ ^[1-9][0-9]*$ &&
          "$reconnect_seconds" =~ ^[0-9]+$ ]] ||
     (( host_port > 65535 || (host_port >= 5554 && host_port <= 5585) )); then
    printf '::warning::adb transport: emulator pipe (%s); invalid ANDROID_ADB_TCP_PORT, ANDROID_ADB_TCP_TIMEOUT_SECONDS or ANDROID_ADB_TCP_RECONNECT_SECONDS\n' \
      "$emulator_serial"
    return 0
  fi
  tcp_serial="127.0.0.1:$host_port"
  {
    printf '== switching %s to %s (%s)\n' "$emulator_serial" "$tcp_serial" "$(date -u +%H:%M:%S)"
    # A reboot ends adbd's TCP listener, so a connection kept from before it
    # would only sit offline.
    android_run_until $((SECONDS + 10)) adb disconnect "$tcp_serial" 2>&1 || true
    # Outside the budget, which is for the dials. The emulator's port redirect
    # delivers into guest eth0 (Wi-Fi, wlan0, is a network it does not reach),
    # and the goldfish radio brings eth0 up only while a cellular data call is
    # active. On some boots none comes up, and `adb connect` then sits offline
    # while the pipe works. eth0 is read once and logged, and nothing waits for
    # it: a healthy boot's data call is often only late. The capture at the
    # pipe fallback is what explains a bad boot.
    printf 'eth0 %s\n' "$(android_guest_link_state "$emulator_serial")"
  } >>"$log" 2>&1
  # Every adb call is cut off at the deadline, but each still gets a 2 s floor,
  # so one pass that starts just before it can end about 30 s past the budget
  # at worst.
  started=$SECONDS
  deadline=$((SECONDS + timeout_seconds))
  while true; do
    pass=$((pass + 1))
    {
      # adbd sets the property, then restarts to listen on TCP, so the
      # emulator transport drops for a moment. Ask only while adbd answers
      # without it: asking mid-restart would restart adbd again. Skip it when
      # adbd already listens on TCP.
      if (( ! adbd_on_tcp )) &&
         tcp_port=$(android_run_until "$deadline" adb -s "$emulator_serial" shell getprop service.adb.tcp.port 2>/dev/null) &&
         [[ "${tcp_port//$'\r'/}" != 5555 ]]; then
        if android_adbd_listens_on_tcp "$emulator_serial" "$deadline"; then
          printf 'adbd already listens on tcp:5555; no adb tcpip\n'
          adbd_on_tcp=1
        else
          android_run_until "$deadline" adb -s "$emulator_serial" tcpip 5555 2>&1 || true
        fi
      fi
      # Refused while the emulator console starts. The redirect lives in the
      # emulator, so it outlasts adb connections and guest reboots, and a
      # second add only answers "host port already active".
      if (( ! redirected )); then
        redir=$(android_run_until "$deadline" adb -s "$emulator_serial" emu redir add "tcp:$host_port:5555" 2>&1) || true
        printf '%s\n' "$redir"
        if [[ "$redir" == OK* || "$redir" == *'already active'* ]]; then
          redirected=1
        fi
      fi
      # With no transport under the serial (the first pass, or a connect
      # refused before the redirect existed) a connect dials.
      if [[ -z "$connected_at" || "$state" == *'not found'* ]]; then
        connected_at=$SECONDS
        android_run_until "$deadline" adb connect "$tcp_serial" 2>&1 || true
      elif [[ "$state" != device ]] && (( SECONDS - connected_at >= reconnect_seconds )); then
        # `adb connect` registers the serial before adbd answers and keeps it
        # registered, offline, after its own 10 s wait gives up. Each later
        # connect opens a fresh socket through the redirect, then drops it when
        # registering the serial fails with EALREADY ("already connected"), so
        # the stale transport is kept until it is disconnected. The state above
        # is from before the sleep, and the serial can come online by itself in
        # between, so ask again: only a serial that still is not a device is
        # dropped and redialled.
        state=$(android_run_until "$deadline" adb -s "$tcp_serial" get-state 2>&1 | head -n 1 | tr -d '\r' || true)
        if [[ "$state" != device ]]; then
          printf 'reconnecting: %s still not a device %ss after connect (%s)\n' \
            "$tcp_serial" $((SECONDS - connected_at)) "${state:-no answer}"
          android_run_until "$deadline" adb disconnect "$tcp_serial" 2>&1 || true
          android_run_until "$deadline" adb -s "$emulator_serial" emu redir list 2>&1 || true
          connected_at=$SECONDS
          android_run_until "$deadline" adb connect "$tcp_serial" 2>&1 || true
        fi
      fi
    } >>"$log" 2>&1
    state=$(android_run_until "$deadline" adb -s "$tcp_serial" get-state 2>&1 | head -n 1 | tr -d '\r' || true)
    printf 'pass %s +%ss: %s\n' "$pass" $((SECONDS - started)) "${state:-no answer}" >>"$log" 2>/dev/null || true
    if [[ "$state" == device ]]; then
      booted=$(android_run_until "$deadline" adb -s "$tcp_serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
      if [[ "$booted" == 1 ]]; then
        # Another emulator or a stale redirect could answer on the port; use
        # it only if it is this boot of this emulator.
        emulator_boot=$(android_boot_id "$emulator_serial" "$deadline")
        tcp_boot=$(android_boot_id "$tcp_serial" "$deadline")
        if [[ -n "$emulator_boot" && "$emulator_boot" == "$tcp_boot" ]]; then
          ANDROID_ADB_SERIAL="$tcp_serial"
          ANDROID_ADB_TCP_SWITCH=tcp
          printf 'boot_id %s on both serials\n' "$tcp_boot" >>"$log"
          note "adb transport: tcp ($tcp_serial, redirected by $emulator_serial)"
          return 0
        elif [[ -n "$emulator_boot" && -n "$tcp_boot" ]]; then
          android_run_until "$deadline" adb disconnect "$tcp_serial" >>"$log" 2>&1 || true
          ANDROID_ADB_TCP_SWITCH=other-device
          printf '::warning::adb transport: emulator pipe (%s); %s is another device (boot_id %s, not %s)\n' \
            "$emulator_serial" "$tcp_serial" "$tcp_boot" "$emulator_boot"
          return 0
        fi
      fi
    fi
    if (( SECONDS >= deadline )); then
      {
        android_run_until $((SECONDS + 5)) adb disconnect "$tcp_serial" 2>&1 || true
        printf -- '-- guest data link at fallback (%s)\n' "$(date -u +%H:%M:%S)"
        capture_android_data_link_evidence "$emulator_serial"
      } >>"$log" 2>&1
      ANDROID_ADB_TCP_SWITCH=timeout
      printf '::warning::adb transport: emulator pipe (%s); adbd did not answer on %s within %ss\n' \
        "$emulator_serial" "$tcp_serial" "$timeout_seconds"
      return 0
    fi
    sleep 2
  done
}

# The switch runs right after boot, and on some boots no connect through the
# redirect is answered for its whole budget while the emulator pipe works. A
# switch that timed out is tried once more after the build and install, in the
# same log; on success ANDROID_ADB_TCP_SWITCH says so. Minutes after boot a
# working redirect answers the first dial, so the retry gets a shorter budget
# (ANDROID_ADB_TCP_RETRY_TIMEOUT_SECONDS) and a boot where TCP never answers
# costs less before the flow starts. Like the switch, it never fails the run.
retry_android_adb_over_tcp_after_timeout() {
  local log="${1:-/dev/null}" budget="${ANDROID_ADB_TCP_RETRY_TIMEOUT_SECONDS:-30}"
  [[ "${ANDROID_ADB_TCP_SWITCH:-}" == timeout ]] || return 0
  if ! [[ "$budget" =~ ^[1-9][0-9]*$ ]]; then
    printf '::warning::adb transport: emulator pipe (%s); invalid ANDROID_ADB_TCP_RETRY_TIMEOUT_SECONDS, switch not retried\n' \
      "$ANDROID_EMULATOR_SERIAL"
    return 0
  fi
  printf '== retrying the switch, which timed out above (%s)\n' "$(date -u +%H:%M:%S)" >>"$log" 2>/dev/null || true
  ANDROID_ADB_TCP_TIMEOUT_SECONDS="$budget" use_android_adb_over_tcp "$ANDROID_EMULATOR_SERIAL" "$log"
  [[ "$ANDROID_ADB_TCP_SWITCH" != tcp ]] || ANDROID_ADB_TCP_SWITCH=tcp-after-retry
}

# Names the transport an attempt ran on for the run summary: a host:port serial
# is TCP, anything else the emulator pipe.
android_adb_transport_label() {
  local device="$1" switch="${2:-}"
  if [[ "$device" != *:* ]]; then
    printf 'emulator pipe\n'
  elif [[ "$switch" == tcp-after-retry ]]; then
    printf 'tcp after retry\n'
  else
    printf 'tcp\n'
  fi
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

# Maestro's own words for the ADB transport going away under it: the device
# reported offline, then missing, and the driver dying with it.
android_maestro_log_has_transport_drop() {
  local maestro_log="$1/debug/maestro.log"
  [[ -f "$maestro_log" ]] || return 1
  grep -E -q "device offline|DeviceServerDiedException|device '[^']*' not found" "$maestro_log"
}

# One diagnostic query, cut off after N seconds (ANDROID_DIAGNOSTIC_TIMEOUT_SECONDS
# overrides N) with the cut-off noted in its output. It never fails: a
# diagnostic must not hold the job up or change its result.
android_diagnostic() {
  local seconds="${ANDROID_DIAGNOSTIC_TIMEOUT_SECONDS:-$1}"
  shift
  android_run_until $((SECONDS + seconds)) "$@" && return 0
  (( $? != 124 )) || printf '(gave up after %ss)\n' "$seconds"
  return 0
}

# adb writes the host server log to $TMPDIR/adb.<uid>.log by default on every
# OS. The server's stderr is that file, so on Linux /proc names the one it
# really uses; without /proc (macOS) we fall back to the default path.
android_adb_server_log_path() {
  local pid path
  for pid in $(pgrep -f 'adb.*fork-server' 2>/dev/null || true); do
    path=$(readlink "/proc/$pid/fd/2" 2>/dev/null || true)
    if [[ -f "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  for path in "${ANDROID_ADB_LOG_PATH:-}" "${TMPDIR:-/tmp}/adb.$(id -u).log" "/tmp/adb.$(id -u).log"; do
    if [[ -n "$path" && -f "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

# Record what ADB and the device report after the failed run, once Maestro has
# exited (not at the instant of the drop), and before any recovery action
# changes it. The failed runs carry almost no device log (logcat dies with the
# transport), so uptime is the one reading that tells a system restart apart
# from a transport-only drop, adbd's elapsed time tells a guest adbd restart
# apart, and the host ADB server log names the side that closed the connection.
# The guest is asked through the emulator serial, whose transport stays up when
# TCP drops, and the state of the serial the run used is recorded beside it.
# Every query is time-boxed (a wedged transport can leave adb waiting on the
# device), and none of them can fail the recovery or change the job's result.
capture_android_transport_diagnostics() {
  local artifact_dir="$1"
  local device_id="$2"
  local label="${3:-at failure}"
  local guest="${ANDROID_EMULATOR_SERIAL:-$device_id}"
  local out_dir="${4:-$artifact_dir/device-recovery-attempt-1}"
  local out="$out_dir/adb-state.txt"
  mkdir -p "$out_dir"
  {
    printf '== %s (%s)\n' "$label" "$(date -u +%H:%M:%S)"
    printf -- '-- adb devices -l\n'
    android_diagnostic 10 adb devices -l 2>&1
    printf -- '-- get-state %s\n' "$device_id"
    android_diagnostic 10 adb -s "$device_id" get-state 2>&1
    if [[ "$guest" != "$device_id" ]]; then
      printf -- '-- get-state %s\n' "$guest"
      android_diagnostic 10 adb -s "$guest" get-state 2>&1
    fi
    printf -- '-- sys.boot_completed (%s)\n' "$guest"
    android_diagnostic 10 adb -s "$guest" shell getprop sys.boot_completed 2>&1
    printf -- '-- /proc/uptime\n'
    android_diagnostic 10 adb -s "$guest" shell cat /proc/uptime 2>&1
    printf -- '-- adbd processes\n'
    android_diagnostic 10 adb -s "$guest" shell ps -A -o PID,PPID,STIME,ETIME,NAME 2>&1 |
      awk '!/^ *[0-9]/ || /adbd/'
    printf -- '-- logcat adbd\n'
    # logcat's -t counts entries before -s filters them, so tail after it.
    android_diagnostic 15 adb -s "$guest" logcat -d -s adbd 2>&1 | tail -n 200
    printf -- '-- logcat crash buffer\n'
    android_diagnostic 15 adb -s "$guest" logcat -d -b crash -t 80 2>&1
  } >>"$out" 2>&1
  copy_android_adb_server_log "$out_dir" "$label"
  return 0
}

# Append the host ADB server log to the capture. The first capture in a run
# takes the last 2 MiB, which covers the whole run (a line count could cut off
# the drop if the server logged heavily after it). A later capture in the same
# run takes only what the log gained since the previous one, so a recovery that
# captures two or three times does not carry the same log each time, and its
# header names the capture that holds the earlier part.
# What was copied is tracked per process, not per output folder: the log's
# path, inode and byte offset live in shell variables, on purpose. They end
# with the run and nothing extra lands in the evidence; a capture that cannot
# see them (a new run, or a subshell) takes the full tail again.
# adb opens the log for append, so a new server adds to it; the file is only
# replaced when it is deleted and recreated (a tmp cleanup or a reboot). A log
# at a different path or inode, or one that shrank, gets the full tail. Where
# `ls -diL` gives no inode, or a recreated file reuses the old inode number,
# only the shrink check catches a recreated log. No copy exceeds 2 MiB. Like
# the rest of the capture, it never fails.
ANDROID_ADB_SERVER_LOG_COPIED_PATH=""
ANDROID_ADB_SERVER_LOG_COPIED_INODE=""
ANDROID_ADB_SERVER_LOG_COPIED_OFFSET=""
ANDROID_ADB_SERVER_LOG_COPIED_BY=""
copy_android_adb_server_log() {
  local out_dir="$1"
  local label="$2"
  local limit=2097152
  local adb_log size inode start=0 copied="last 2 MiB"
  local previous_offset="${ANDROID_ADB_SERVER_LOG_COPIED_OFFSET:-}"
  local previous_inode="${ANDROID_ADB_SERVER_LOG_COPIED_INODE:-}"
  if ! adb_log=$(android_adb_server_log_path); then
    printf '== %s: host ADB server log not found\n' "$label" >>"$out_dir/adb-server.log"
    return 0
  fi
  size=$(wc -c 2>/dev/null <"$adb_log" | tr -d ' ' || true)
  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    printf '== %s: host ADB server log %s could not be read\n' "$label" "$adb_log" \
      >>"$out_dir/adb-server.log"
    return 0
  fi
  # `ls -di` prints the inode first on both BSD and GNU; stat's flags differ.
  # -L reads a symlinked log's target, the file wc measures.
  inode=$(ls -diL "$adb_log" 2>/dev/null | awk '{ print $1; exit }' || true)
  [[ "$inode" =~ ^[0-9]+$ ]] || inode=""
  if [[ "$previous_offset" =~ ^[0-9]+$ &&
        "${ANDROID_ADB_SERVER_LOG_COPIED_PATH:-}" == "$adb_log" ]] &&
     [[ -z "$inode" || -z "$previous_inode" || "$inode" == "$previous_inode" ]] &&
     (( previous_offset <= size )); then
    start="$previous_offset"
    copied="appended since the previous capture, ${ANDROID_ADB_SERVER_LOG_COPIED_BY:-}; earlier part in that capture's adb-server.log"
  fi
  if (( size - start > limit )); then
    start=$((size - limit))
    copied="last 2 MiB"
  fi
  (( size > start )) || copied="$copied; nothing new"
  {
    printf '== %s (%s) from %s, bytes %s-%s (%s)\n' \
      "$label" "$(date -u +%H:%M:%S)" "$adb_log" "$start" "$size" "$copied"
    # BSD head rejects a count of 0, so an empty range copies nothing.
    if (( size > start )); then
      tail -c +"$((start + 1))" "$adb_log" 2>/dev/null | head -c "$((size - start))" || true
    fi
  } >>"$out_dir/adb-server.log" 2>&1
  ANDROID_ADB_SERVER_LOG_COPIED_PATH="$adb_log"
  ANDROID_ADB_SERVER_LOG_COPIED_INODE="$inode"
  ANDROID_ADB_SERVER_LOG_COPIED_OFFSET="$size"
  ANDROID_ADB_SERVER_LOG_COPIED_BY="\"$label\" in ${out_dir##*/}"
  return 0
}

# The first attempt's Maestro driver died on an emulator that was still running,
# and the retry on that same device failed identically (the driver connection
# died about 3.7 s after connecting, both times, in a rehearsal). Reboot the
# device so the retry starts from a fresh system server and adbd. The app's data
# and permission grants live in the AVD's userdata and survive the reboot.
restart_android_device_for_retry() {
  local device_id="$1"
  local timeout_seconds="${ANDROID_DEVICE_RESTART_TIMEOUT_SECONDS:-180}"
  local down_deadline state booted
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 2
  adb -s "$device_id" reboot >/dev/null 2>&1 || return 1
  # Until the device has been seen going down, "device" and boot_completed=1
  # still describe the old boot, so they cannot count as the new one.
  down_deadline=$((SECONDS + ${ANDROID_DEVICE_DOWN_TIMEOUT_SECONDS:-30}))
  while true; do
    state=$(adb -s "$device_id" get-state 2>/dev/null || true)
    booted=$(adb -s "$device_id" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
    [[ "$state" != "device" || "$booted" != "1" ]] && break
    (( SECONDS < down_deadline )) || return 1
    sleep 1
  done
  ANDROID_DEVICE_RECONNECT_TIMEOUT_SECONDS="$timeout_seconds" \
    wait_for_android_device_reconnect "$device_id" || return 1
  # boot_completed precedes the package manager on a fresh boot, and Maestro's
  # first command installs and starts its driver through it.
  local package_deadline=$((SECONDS + 60))
  until adb -s "$device_id" shell pm path android 2>/dev/null | grep -q '^package:'; do
    (( SECONDS < package_deadline )) || return 1
    sleep 1
  done
  adb -s "$device_id" shell input keyevent 82 >/dev/null 2>&1 || true
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
    sdk-live.log device-live.log host-vmstat.log; do
    if [[ -f "$artifact_dir/$diagnostic" ]]; then
      cp "$artifact_dir/$diagnostic" "$retry_dir/$diagnostic"
    fi
  done
}

# A recovered retry turns the job green, so surface the device drop on the run
# page as well as in the evidence bundle. The step summary only exists on GitHub
# Actions; local runs just print the warning line.
report_android_transport_recovery() {
  local suite="$1"
  printf '::warning::Android device went offline before the SDK identified a user in suite %s; rebooting it and retrying once. The first attempt is kept in device-recovery-attempt-1/.\n' \
    "$suite"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf -- '- Android suite %s: device went offline before the SDK identified a user, triggering the one-time reboot and retry. The first attempt is kept in device-recovery-attempt-1/.\n' \
      "$suite" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# A drop the retry does not cover (mid-flow, after identify, or in the retry
# itself) still gets the transport state recorded, beside the final attempt.
capture_final_android_transport_drop() {
  local artifact_dir="$1"
  local device_id="$2"
  local label="$3"
  android_maestro_log_has_transport_drop "$artifact_dir" || return 0
  capture_android_transport_diagnostics "$artifact_dir" "$device_id" "$label" \
    "$artifact_dir/device-transport-drop"
}

run_android_transport_recovery_once() {
  local initial_result="$1"
  local artifact_dir="$2"
  local device_id="$3"
  local recovery_attempt_was_set="${E2E_RECOVERY_ATTEMPT+x}"
  local recovery_attempt_value="${E2E_RECOVERY_ATTEMPT:-}"
  # A reboot goes through the emulator, whose transport survives it, and ends
  # adbd's TCP listener, so the switch to TCP runs again afterwards.
  local emulator_serial="${ANDROID_EMULATOR_SERIAL:-$device_id}"
  shift 3

  [[ "$initial_result" -ne 0 ]] || return 0
  if ! android_maestro_transport_failed_at_launch "$artifact_dir" &&
     ! android_maestro_transport_failed_before_identify "$artifact_dir"; then
    capture_final_android_transport_drop "$artifact_dir" "$device_id" "at failure, not retried"
    return "$initial_result"
  fi
  note "Android device went offline before the SDK identified a user; rebooting it and retrying once"
  report_android_transport_recovery "${SUITE:-$(basename "$artifact_dir")}"
  preserve_android_transport_failure "$artifact_dir"
  capture_android_transport_diagnostics "$artifact_dir" "$device_id" "at failure"
  if ! wait_for_android_device_reconnect "$emulator_serial"; then
    note "Android device did not reconnect; preserving the original Maestro failure"
    return "$initial_result"
  fi
  if ! restart_android_device_for_retry "$emulator_serial"; then
    note "Android device did not come back from a restart; preserving the original Maestro failure"
    capture_android_transport_diagnostics "$artifact_dir" "$emulator_serial" "after failed restart"
    return "$initial_result"
  fi
  if [[ "$emulator_serial" != "$device_id" ]]; then
    use_android_adb_over_tcp "$emulator_serial" "$artifact_dir/adb-transport.log"
    device_id="$ANDROID_ADB_SERIAL"
    export E2E_DEVICE_ID="$device_id"
  fi
  capture_android_transport_diagnostics "$artifact_dir" "$device_id" "after restart"
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
    capture_final_android_transport_drop "$artifact_dir" "$device_id" "at retry failure"
  fi
  return "$retry_result"
}
