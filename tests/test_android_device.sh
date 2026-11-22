#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/android_device.sh
source "$ROOT/scripts/android_device.sh"

# Keep the diagnostics tests off this machine's real ADB server log: no running
# server is found, no exported log path wins, and the default log names (keyed
# by uid) point at files that do not exist. A case that needs a server log sets
# ANDROID_ADB_LOG_PATH or TMPDIR itself.
unset ANDROID_ADB_LOG_PATH
pgrep() { return 1; }
id() {
  if [[ "${1:-}" == "-u" ]]; then
    printf '%s\n' 'mobile-e2e-test'
  else
    command id "$@"
  fi
}

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
AVDMANAGER_CALLS=0
avdmanager() {
  AVDMANAGER_CALLS=$((AVDMANAGER_CALLS + 1))
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

mkdir -p "$ANDROID_AVD_HOME/Maestro_ANDROID_pixel_7_android-35.avd"
touch "$ANDROID_AVD_HOME/Maestro_ANDROID_pixel_7_android-35.ini"
AVDMANAGER_CALLS=0
if create_headless_android_avd fake_emulator "Maestro_ANDROID_pixel_7_android-35" "$TEST_DIR/avdmanager.log"; then
  echo "expected stale AVD registration to fail without being overwritten" >&2
  exit 1
fi
[[ "$AVDMANAGER_CALLS" -eq 0 ]]
grep -Fq "refusing to overwrite" "$TEST_DIR/avdmanager.log"
find "$ANDROID_AVD_HOME" -mindepth 1 -delete

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
# Over TCP a dropped device is removed rather than reported offline, so Maestro
# says it is not found.
sed -i.bak \
  -e "s/: device offline/: device '127.0.0.1:5600' not found/" \
  -e '/DeviceServerDiedException/d' \
  "$TRANSPORT_ARTIFACTS/debug/maestro.log"
android_maestro_transport_failed_at_launch "$TRANSPORT_ARTIFACTS"

ADB_STATE="device"
ADB_BOOTED="1"
# A reboot takes the device offline for ADB_REBOOT_OFFLINE_POLLS get-state calls.
# State lives in files because callers read these answers in command
# substitutions, where variable changes would be lost.
ADB_LOG="$TEST_DIR/adb-calls.log"
ADB_REBOOT_FAILS=0
ADB_REBOOT_OFFLINE_POLLS=2
ADB_REBOOT_NEVER_GOES_DOWN=0
# adbd answers on TCP only after `tcpip` (until the next reboot) or when it
# listens there by default (ADB_TCP_DEFAULT_LISTENER), and only while
# ADB_TCP_ANSWERS is 1. ADB_TCP_BOOT_ID is the boot_id whatever answers on the
# TCP port reports. State lives in files for the same reason as above.
ADB_TCP_ANSWERS=1
ADB_TCP_DEFAULT_LISTENER=0
ADB_TCP_ALWAYS_STALE=0
ADB_TCP_BOOT_ID="boot-a"
adb_tcp_listening() {
  [[ "$ADB_TCP_DEFAULT_LISTENER" -eq 1 || -f "$TEST_DIR/adb-tcpip" ]]
}
sleep() { :; }
adb() {
  local polls
  printf '%s\n' "$*" >>"$ADB_LOG"
  # adb-tcp-online-after: how many more get-states a registered, offline
  # serial answers before adbd's answer arrives and it comes online by itself.
  if [[ "$*" == "-s 127.0.0.1:5600 get-state" && -f "$TEST_DIR/adb-tcp-registered" &&
        -f "$TEST_DIR/adb-tcp-online-after" ]]; then
    polls=$(<"$TEST_DIR/adb-tcp-online-after")
    if [[ "$polls" -gt 0 ]]; then
      printf '%s' $((polls - 1)) >"$TEST_DIR/adb-tcp-online-after"
    else
      rm -f "$TEST_DIR/adb-tcp-registered" "$TEST_DIR/adb-tcp-online-after"
      : >"$TEST_DIR/adb-tcp-connected"
    fi
  fi
  # A serial `adb connect` registered without adbd answering stays offline.
  if [[ "$*" == "-s 127.0.0.1:5600 get-state" && ! -f "$TEST_DIR/adb-tcp-connected" &&
        -f "$TEST_DIR/adb-tcp-registered" ]]; then
    printf '%s\n' 'error: device offline' >&2
    return 1
  elif [[ "$*" == "-s 127.0.0.1:5600 get-state" && ! -f "$TEST_DIR/adb-tcp-connected" ]]; then
    printf '%s\n' "error: device '127.0.0.1:5600' not found" >&2
    return 1
  fi
  # Every command over TCP fails once the connection is gone.
  [[ "$*" != "-s 127.0.0.1:5600 "* || -f "$TEST_DIR/adb-tcp-connected" ]] || return 1
  case "$*" in
    "start-server") return 0 ;;
    "disconnect "*) rm -f "$TEST_DIR/adb-tcp-connected" "$TEST_DIR/adb-tcp-registered" ;;
    *" tcpip 5555") : >"$TEST_DIR/adb-tcpip" ;;
    *" shell getprop service.adb.tcp.port")
      [[ ! -f "$TEST_DIR/adb-tcpip" ]] || printf '%s\n' 5555
      ;;
    *" emu redir add tcp:5600:5555")
      # The console refuses while it starts; the emulator keeps a redirect
      # until it exits.
      polls=$(cat "$TEST_DIR/adb-redir-refusals" 2>/dev/null || printf 0)
      if [[ "$polls" -gt 0 ]]; then
        printf '%s' $((polls - 1)) >"$TEST_DIR/adb-redir-refusals"
        printf '%s\n' 'error: could not connect to TCP port 5554: Connection refused' >&2
        return 1
      elif [[ -f "$TEST_DIR/adb-redir" ]]; then
        printf '%s\n' "KO: host port already active, use 'redir del' to remove first"
      else
        : >"$TEST_DIR/adb-redir"
        printf '%s\n' OK
      fi
      ;;
    *" emu redir list")
      [[ ! -f "$TEST_DIR/adb-redir" ]] || printf '%s\n' 'tcp:5600  => 5555 '
      printf '%s\n' OK
      ;;
    *" shell cat /proc/net/tcp /proc/net/tcp6")
      printf '%s\n' '  sl  local_address rem_address   st tx_queue rx_queue'
      printf '%s\n' '   0: 0100007F:13AD 00000000:0000 0A 00000000:00000000 00:00000000'
      ! adb_tcp_listening ||
        printf '%s\n' '   1: 00000000:15B3 00000000:0000 0A 00000000:00000000 00:00000000'
      ;;
    "connect 127.0.0.1:5600")
      # adb-tcp-stale-connects is how many connects adbd never answers (every
      # one with ADB_TCP_ALWAYS_STALE=1): adb
      # registers the serial anyway, and every later connect to it only says
      # "already connected" until it is disconnected.
      polls=$(cat "$TEST_DIR/adb-tcp-stale-connects" 2>/dev/null || printf 0)
      if [[ -f "$TEST_DIR/adb-tcp-connected" || -f "$TEST_DIR/adb-tcp-registered" ]]; then
        printf '%s\n' 'already connected to 127.0.0.1:5600'
      elif [[ ! -f "$TEST_DIR/adb-redir" ]]; then
        printf '%s\n' 'failed to connect to 127.0.0.1:5600: Connection refused'
        return 1
      elif [[ "$ADB_TCP_ALWAYS_STALE" -eq 1 || "$polls" -gt 0 ]]; then
        [[ "$polls" -eq 0 ]] || printf '%s' $((polls - 1)) >"$TEST_DIR/adb-tcp-stale-connects"
        : >"$TEST_DIR/adb-tcp-registered"
        printf '%s\n' 'failed to connect to 127.0.0.1:5600'
        return 1
      elif [[ "$ADB_TCP_ANSWERS" -eq 1 ]] && adb_tcp_listening; then
        : >"$TEST_DIR/adb-tcp-connected"
        printf '%s\n' 'connected to 127.0.0.1:5600'
      else
        printf '%s\n' 'failed to connect to 127.0.0.1:5600'
        return 1
      fi
      ;;
    "-s 127.0.0.1:5600 get-state")
      [[ -f "$TEST_DIR/adb-tcp-connected" ]] || return 1
      printf '%s\n' device
      ;;
    "-s 127.0.0.1:5600 shell getprop sys.boot_completed")
      [[ -f "$TEST_DIR/adb-tcp-connected" ]] || return 1
      polls=$(cat "$TEST_DIR/adb-tcp-booting" 2>/dev/null || printf 0)
      if [[ "$polls" -gt 0 ]]; then
        printf '%s' $((polls - 1)) >"$TEST_DIR/adb-tcp-booting"
        printf '%s\n' 0
      else
        printf '%s\n' 1
      fi
      ;;
    "-s 127.0.0.1:5600 shell cat /proc/sys/kernel/random/boot_id")
      [[ -f "$TEST_DIR/adb-tcp-connected" ]] || return 1
      printf '%s\r\n' "$ADB_TCP_BOOT_ID"
      ;;
    *" shell cat /proc/sys/kernel/random/boot_id") printf '%s\r\n' boot-a ;;
    *" reboot")
      [[ "$ADB_REBOOT_FAILS" -eq 0 ]] || return 1
      # A reboot ends adbd's TCP listener and the connection to it.
      rm -f "$TEST_DIR/adb-tcpip" "$TEST_DIR/adb-tcp-connected"
      [[ "$ADB_REBOOT_NEVER_GOES_DOWN" -eq 1 ]] ||
        printf '%s' "$ADB_REBOOT_OFFLINE_POLLS" >"$TEST_DIR/adb-offline-polls"
      ;;
    *" get-state")
      if [[ -f "$TEST_DIR/adb-offline-polls" ]]; then
        polls=$(<"$TEST_DIR/adb-offline-polls")
        if [[ "$polls" -gt 0 ]]; then
          printf '%s' $((polls - 1)) >"$TEST_DIR/adb-offline-polls"
          printf '%s\n' offline
          return 0
        fi
      fi
      printf '%s\n' "$ADB_STATE"
      ;;
    *" shell getprop sys.boot_completed")
      if [[ -f "$TEST_DIR/adb-offline-polls" ]] &&
         [[ "$(<"$TEST_DIR/adb-offline-polls")" -gt 0 ]]; then
        printf '%s\n' 0
      else
        printf '%s\n' "$ADB_BOOTED"
      fi
      ;;
    *" shell pm path android") printf '%s\n' 'package:/system/framework/framework-res.apk' ;;
    *" shell cat /proc/uptime") printf '%s\n' '12.34 10.00' ;;
    *" shell input keyevent 82") return 0 ;;
    "devices -l") printf '%s\n' 'emulator-5554 device product:sdk' ;;
    *" logcat -d -b crash -t 80") printf '%s\n' 'crash buffer line' ;;
    *" shell ps -A -o PID,PPID,STIME,ETIME,NAME")
      # A wedged transport: the query never answers until it is killed.
      [[ "${ADB_PS_HANGS:-0}" -eq 0 ]] || exec sleep 30
      printf '%s\n' '  PID  PPID STIME ELAPSED NAME' \
        '  321     1 06:30   05:12 adbd' '  999   321 06:34   01:02 screenrecord' \
        ' 1200     1 06:30   05:12 surfaceflinger'
      ;;
    *" logcat -d -s adbd -t 200") printf '%s\n' 'adbd log line' ;;
    *) return 64 ;;
  esac
}
ANDROID_RETRY_CALLS=0
ANDROID_RETRY_RESULT=0
android_retry_command() {
  ANDROID_RETRY_CALLS=$((ANDROID_RETRY_CALLS + 1))
  # Mirror run.sh's top-level cleanup gate: a nested retry must retain the
  # first-attempt bundle that the recovery wrapper just captured.
  if [[ "${E2E_RECOVERY_ATTEMPT:-0}" != 1 ]]; then
    find "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1" -mindepth 1 -delete
    rmdir "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1"
  fi
  [[ -d "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1" ]] || return 65
  return "$ANDROID_RETRY_RESULT"
}
printf '%s\n' 'first Android live diagnostics' \
  >"$TRANSPORT_ARTIFACTS/device-live.log"
# A recovered retry goes green, so the drop must be announced on the run page.
RECOVERY_OUTPUT="$TEST_DIR/recovery-output.log"
GITHUB_STEP_SUMMARY="$TEST_DIR/step-summary.md"
SUITE="message-inbox"
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command \
  >"$RECOVERY_OUTPUT"
grep -Eq '^::warning::Android device went offline .* suite message-inbox;' \
  "$RECOVERY_OUTPUT"
[[ "$(grep -c 'message-inbox' "$GITHUB_STEP_SUMMARY")" -eq 1 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 1 ]]
[[ -f "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/debug/maestro.log" ]]
grep -Fq 'first Android attempt' \
  "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/run.log"
grep -Fq 'first Android live diagnostics' \
  "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/device-live.log"
grep -Fq 'Recovered from an Android device transport failure' \
  "$TRANSPORT_ARTIFACTS/run.log"
[[ -z "${E2E_RECOVERY_ATTEMPT+x}" ]]
# The device is rebooted before the retry, and its state is recorded both at the
# failure and after the restart.
grep -Fxq -- '-s emulator-5554 reboot' "$ADB_LOG"
grep -Fq '== at failure' \
  "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/adb-state.txt"
grep -Fq '== after restart' \
  "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/adb-state.txt"
grep -Fq '12.34 10.00' \
  "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/adb-state.txt"

# A failed retry must keep the retry status and must not claim recovery.
ANDROID_RETRY_CALLS=0
ANDROID_RETRY_RESULT=9
printf '%s\n' \
  '16:39:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" RUNNING' \
  '16:39:01.644 [ERROR] maestro.orchestra.Orchestra.executeCommands: [Command execution] CommandFailed: device offline' \
  '16:39:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" FAILED' \
  >"$TRANSPORT_ARTIFACTS/debug/maestro.log"
: >"$TRANSPORT_ARTIFACTS/run.log"
# Local runs have no step summary or SUITE; the warning falls back to the flow
# directory name and nothing else is written.
unset GITHUB_STEP_SUMMARY SUITE
set +e
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command \
  >"$RECOVERY_OUTPUT"
android_recovery_result=$?
set -e
grep -Eq '^::warning::Android device went offline .* suite transport;' \
  "$RECOVERY_OUTPUT"
[[ "$(grep -c 'suite' "$TEST_DIR/step-summary.md")" -eq 1 ]]
GITHUB_STEP_SUMMARY="$TEST_DIR/step-summary.md"
[[ "$android_recovery_result" -eq 9 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 1 ]]
grep -Fq 'retry also failed with exit 9' "$TRANSPORT_ARTIFACTS/run.log"
if grep -Fq 'Recovered from an Android device transport failure' \
  "$TRANSPORT_ARTIFACTS/run.log"; then
  echo "expected a failed retry not to claim recovery" >&2
  exit 1
fi
ANDROID_RETRY_RESULT=0

ANDROID_RETRY_CALLS=0
printf '%s\n' \
  '16:39:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" RUNNING' \
  '16:39:01.644 [ERROR] maestro.orchestra.Orchestra.executeCommands: [Command execution] CommandFailed: device offline' \
  '16:39:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" FAILED' \
  '16:39:01.680 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Tap on id: login_button RUNNING' \
  >"$TRANSPORT_ARTIFACTS/debug/maestro.log"
set +e
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command \
  >"$RECOVERY_OUTPUT"
android_recovery_result=$?
set -e
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]
# Failures outside the recovery path stay unannounced.
if grep -Fq '::warning::' "$RECOVERY_OUTPUT"; then
  echo "expected no recovery warning when the retry path is not taken" >&2
  exit 1
fi
[[ "$(grep -c 'suite' "$GITHUB_STEP_SUMMARY")" -eq 1 ]]

# A side-effect-capable command before launch makes full-flow replay unsafe.
printf '%s\n' \
  '16:39:00.482 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Run ../scripts/send_inbox_message.js RUNNING' \
  '16:39:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" RUNNING' \
  '16:39:01.644 [ERROR] maestro.orchestra.Orchestra.executeCommands: [Command execution] CommandFailed: device offline' \
  '16:39:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" FAILED' \
  >"$TRANSPORT_ARTIFACTS/debug/maestro.log"
set +e
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command \
  >"$RECOVERY_OUTPUT"
android_recovery_result=$?
set -e
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]
# Failures outside the recovery path stay unannounced.
if grep -Fq '::warning::' "$RECOVERY_OUTPUT"; then
  echo "expected no recovery warning when the retry path is not taken" >&2
  exit 1
fi
[[ "$(grep -c 'suite' "$GITHUB_STEP_SUMMARY")" -eq 1 ]]

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
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command \
  >"$RECOVERY_OUTPUT"
android_recovery_result=$?
set -e
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]
# Failures outside the recovery path stay unannounced.
if grep -Fq '::warning::' "$RECOVERY_OUTPUT"; then
  echo "expected no recovery warning when the retry path is not taken" >&2
  exit 1
fi
[[ "$(grep -c 'suite' "$GITHUB_STEP_SUMMARY")" -eq 1 ]]

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
SUITE="geofence"
set +e
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command \
  >"$RECOVERY_OUTPUT"
android_recovery_result=$?
set -e
unset ANDROID_DEVICE_RECONNECT_TIMEOUT_SECONDS
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]
# The drop is still announced when the device never comes back.
grep -Eq '^::warning::Android device went offline .* suite geofence;' \
  "$RECOVERY_OUTPUT"
[[ "$(grep -c 'suite geofence' "$GITHUB_STEP_SUMMARY")" -eq 1 ]]

# A device that reconnects but cannot be rebooted, or never goes down after the
# reboot command, keeps the original result: a retry on a device in an unknown
# state would only add a second failure.
printf '%s\n' \
  '16:39:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" RUNNING' \
  '16:39:01.644 [ERROR] maestro.orchestra.Orchestra.executeCommands: [Command execution] CommandFailed: device offline' \
  '16:39:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" FAILED' \
  >"$TRANSPORT_ARTIFACTS/debug/maestro.log"
ADB_STATE="device"
ADB_BOOTED="1"
ANDROID_DEVICE_DOWN_TIMEOUT_SECONDS=1
for restart_failure in ADB_REBOOT_FAILS ADB_REBOOT_NEVER_GOES_DOWN; do
  rm -f "$TEST_DIR/adb-offline-polls"
  : >"$ADB_LOG"
  ANDROID_RETRY_CALLS=0
  printf -v "$restart_failure" '%s' 1
  set +e
  # The wait for the device to go down runs against $SECONDS, so shorten it.
  run_android_transport_recovery_once \
    7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command \
    >"$RECOVERY_OUTPUT"
  android_recovery_result=$?
  set -e
  printf -v "$restart_failure" '%s' 0
  [[ "$android_recovery_result" -eq 7 ]]
  [[ "$ANDROID_RETRY_CALLS" -eq 0 ]]
  grep -Fq 'after failed restart' \
    "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/adb-state.txt"
done

unset ANDROID_DEVICE_DOWN_TIMEOUT_SECONDS
# A driver or ADB drop after the first launch is retried while the SDK has not
# yet identified this run's customer (the Maestro driver dying mid-login).
rm -f "$TEST_DIR/adb-offline-polls"
ADB_STATE="device"
ADB_BOOTED="1"
SUITE="geofence"
PRE_IDENTIFY_EMAIL="maestro+e2e-abc123@cio.test"
write_pre_identify_fixture() {
  printf '%s\n' \
    '16:39:00.482 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Run ../scripts/setup_run.js RUNNING' \
    '16:39:01.400 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Launch app "app" RUNNING' \
    '16:39:01.679 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandFinished: Launch app "app" COMPLETED' \
    '16:39:05.100 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Run ../scripts/wait.js RUNNING' \
    '16:39:08.200 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Input text Maestro Geofence Tester RUNNING' \
    'maestro.android.DeviceServerDiedException: Device server died during '"'"'viewHierarchy'"'"' on emulator-5554' \
    >"$TRANSPORT_ARTIFACTS/debug/maestro.log"
  printf '{"kind": "setup", "run_id": "abc123", "email": "%s", "path": "/setup"}\n' \
    "$PRE_IDENTIFY_EMAIL" >"$TRANSPORT_ARTIFACTS/sink.jsonl"
  printf '%s\n' 'screen LoginActivity' >"$TRANSPORT_ARTIFACTS/device-live.log"
  : >"$TRANSPORT_ARTIFACTS/run.log"
}
run_pre_identify_recovery() {
  ANDROID_RETRY_CALLS=0
  ANDROID_RETRY_RESULT=0
  set +e
  run_android_transport_recovery_once \
    7 "$TRANSPORT_ARTIFACTS" "${1:-emulator-5554}" android_retry_command \
    >"$RECOVERY_OUTPUT"
  android_recovery_result=$?
  set -e
}

write_pre_identify_fixture
run_pre_identify_recovery
[[ "$android_recovery_result" -eq 0 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 1 ]]
grep -Eq '^::warning::Android device went offline .* suite geofence;' \
  "$RECOVERY_OUTPUT"

# Once the run's customer shows up in the SDK log the app is logged in, so the
# original failure stands.
write_pre_identify_fixture
printf '%s\n' "identify userId=$PRE_IDENTIFY_EMAIL" \
  >>"$TRANSPORT_ARTIFACTS/device-live.log"
run_pre_identify_recovery
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]

# A script other than setup_run.js and wait.js may have mutated the backend.
write_pre_identify_fixture
printf '%s\n' \
  '16:39:06.000 [ INFO] maestro.cli.runner.CliConsoleListener.onCommandStart: Run ../scripts/send_inbox_message.js RUNNING' \
  >>"$TRANSPORT_ARTIFACTS/debug/maestro.log"
run_pre_identify_recovery
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]

# Without the run's email or the live SDK log there is no proof that nothing was
# identified, so nothing is retried.
write_pre_identify_fixture
rm "$TRANSPORT_ARTIFACTS/sink.jsonl"
run_pre_identify_recovery
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]
write_pre_identify_fixture
rm "$TRANSPORT_ARTIFACTS/device-live.log"
run_pre_identify_recovery
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]

# A failure that is not a transport drop is never retried.
write_pre_identify_fixture
sed -i.bak 's/DeviceServerDiedException/AssertionError/' \
  "$TRANSPORT_ARTIFACTS/debug/maestro.log"
run_pre_identify_recovery
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]

# A drop the retry does not cover (here: after the customer was identified)
# keeps its result but still records the transport state beside the final
# attempt, including Maestro's "device ... not found" wording.
FAKE_ADB_LOG_DIR="$TEST_DIR/adb-tmp"
mkdir -p "$FAKE_ADB_LOG_DIR"
printf '%s\n' 'emulator-5554: connection terminated: read failed' \
  >"$FAKE_ADB_LOG_DIR/adb.$(id -u).log"
write_pre_identify_fixture
printf '%s\n' "identify userId=$PRE_IDENTIFY_EMAIL" \
  >>"$TRANSPORT_ARTIFACTS/device-live.log"
sed -i.bak "s/DeviceServerDiedException.*/Command failed (host:transport:emulator-5554): device 'emulator-5554' not found/" \
  "$TRANSPORT_ARTIFACTS/debug/maestro.log"
rm -rf "$TRANSPORT_ARTIFACTS/device-transport-drop"
TMPDIR="$FAKE_ADB_LOG_DIR" run_pre_identify_recovery
[[ "$android_recovery_result" -eq 7 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 0 ]]
DROP_STATE="$TRANSPORT_ARTIFACTS/device-transport-drop/adb-state.txt"
grep -Fq '== at failure, not retried' "$DROP_STATE"
grep -Fq '12.34 10.00' "$DROP_STATE"
grep -Eq '321 +1 06:30 +05:12 adbd' "$DROP_STATE"
if grep -Eq 'screenrecord|surfaceflinger' "$DROP_STATE"; then
  echo "expected only adbd from the device process list" >&2
  exit 1
fi
grep -Fq 'adbd log line' "$DROP_STATE"
grep -Fq 'crash buffer line' "$DROP_STATE"
grep -Fq 'connection terminated: read failed' \
  "$TRANSPORT_ARTIFACTS/device-transport-drop/adb-server.log"

# "Element not found" is an ordinary Maestro warning, not a transport drop, and
# a failure without a drop records nothing.
write_pre_identify_fixture
sed -i.bak "s/DeviceServerDiedException.*/CommandWarned: Element not found: Text matching regex: Continue/" \
  "$TRANSPORT_ARTIFACTS/debug/maestro.log"
rm -rf "$TRANSPORT_ARTIFACTS/device-transport-drop"
run_pre_identify_recovery
[[ "$android_recovery_result" -eq 7 ]]
[[ ! -e "$TRANSPORT_ARTIFACTS/device-transport-drop" ]]

# A retry that drops again records the state at the retry failure too.
write_pre_identify_fixture
rm -rf "$TRANSPORT_ARTIFACTS/device-transport-drop"
ANDROID_RETRY_CALLS=0
ANDROID_RETRY_RESULT=9
set +e
run_android_transport_recovery_once \
  7 "$TRANSPORT_ARTIFACTS" "emulator-5554" android_retry_command \
  >"$RECOVERY_OUTPUT"
android_recovery_result=$?
set -e
ANDROID_RETRY_RESULT=0
[[ "$android_recovery_result" -eq 9 ]]
grep -Fq '== at retry failure' "$TRANSPORT_ARTIFACTS/device-transport-drop/adb-state.txt"

# A query that hangs on a wedged transport is cut off, the rest of the capture
# still runs, and the capture cannot fail the caller.
rm -rf "$TRANSPORT_ARTIFACTS/device-transport-drop"
ADB_PS_HANGS=1
ANDROID_DIAGNOSTIC_TIMEOUT_SECONDS=2
capture_android_transport_diagnostics "$TRANSPORT_ARTIFACTS" "emulator-5554" "wedged" \
  "$TRANSPORT_ARTIFACTS/device-transport-drop"
unset ADB_PS_HANGS ANDROID_DIAGNOSTIC_TIMEOUT_SECONDS
grep -Fq '(gave up after 2s)' "$DROP_STATE"
grep -Fq 'crash buffer line' "$DROP_STATE"

# The first capture in a run copies the last 2 MiB of the host ADB server log;
# a later one copies only what the log gained since the previous capture.
SERVER_LOG="$TEST_DIR/adb-server-under-test.log"
SERVER_LOG_ARTIFACTS="$TEST_DIR/server-log-artifacts"
mkdir -p "$SERVER_LOG_ARTIFACTS"
server_log_body() {
  sed '/^== /d' "$SERVER_LOG_ARTIFACTS/$1/adb-server.log"
}
# Start this case the way a new run starts, with no earlier capture.
ANDROID_ADB_SERVER_LOG_COPIED_PATH=""
ANDROID_ADB_SERVER_LOG_COPIED_OFFSET=""
printf '%s\n' 'server started' 'emulator-5554: connection terminated: read failed' \
  >"$SERVER_LOG"
ANDROID_ADB_LOG_PATH="$SERVER_LOG" capture_android_transport_diagnostics \
  "$SERVER_LOG_ARTIFACTS" "emulator-5554" "at failure" "$SERVER_LOG_ARTIFACTS/first"
printf '%s\n' 'emulator-5554: device came back' >>"$SERVER_LOG"
ANDROID_ADB_LOG_PATH="$SERVER_LOG" capture_android_transport_diagnostics \
  "$SERVER_LOG_ARTIFACTS" "emulator-5554" "after restart" "$SERVER_LOG_ARTIFACTS/second"
[[ "$(server_log_body first)" == \
   $'server started\nemulator-5554: connection terminated: read failed' ]]
grep -Fq '(last 2 MiB)' "$SERVER_LOG_ARTIFACTS/first/adb-server.log"
[[ "$(server_log_body second)" == 'emulator-5554: device came back' ]]
grep -Fq "(appended since the previous capture, \"at failure\" in first; earlier part in that capture's adb-server.log)" \
  "$SERVER_LOG_ARTIFACTS/second/adb-server.log"
# A capture with nothing new copies nothing and runs no zero-byte head, which
# BSD head rejects (stubbed here the way macOS behaves).
head() {
  if [[ "${1:-}" == -c && "${2:-}" == 0 ]]; then
    echo "head: illegal byte count -- 0" >&2
    return 1
  fi
  command head "$@"
}
ANDROID_ADB_LOG_PATH="$SERVER_LOG" capture_android_transport_diagnostics \
  "$SERVER_LOG_ARTIFACTS" "emulator-5554" "no growth" "$SERVER_LOG_ARTIFACTS/no-growth"
unset -f head
[[ -z "$(server_log_body no-growth)" ]]
grep -Fq '; nothing new)' "$SERVER_LOG_ARTIFACTS/no-growth/adb-server.log"
# The offset lives only in the shell, never in the evidence.
[[ -z "$(find "$SERVER_LOG_ARTIFACTS" -name '.*' -print)" ]]

# The next run starts in a fresh shell and copies the full tail again, even
# into the artifact directory an older run left behind.
mkdir -p "$SERVER_LOG_ARTIFACTS/next-run"
bash -c 'source "$1"; pgrep() { return 1; }
  ANDROID_ADB_LOG_PATH="$2" copy_android_adb_server_log "$3" "next run"' _ \
  "$ROOT/scripts/android_device.sh" "$SERVER_LOG" "$SERVER_LOG_ARTIFACTS/next-run"
[[ "$(server_log_body next-run)" == "$(cat "$SERVER_LOG")" ]]
grep -Fq '(last 2 MiB)' "$SERVER_LOG_ARTIFACTS/next-run/adb-server.log"

# adb appends to its log, so it only shrinks when the file is deleted and
# recreated (a tmp cleanup or a reboot); a log that shrank is copied whole
# again, as is a log at a different path.
rm -f "$SERVER_LOG"
printf '%s\n' 'new server' >"$SERVER_LOG"
ANDROID_ADB_LOG_PATH="$SERVER_LOG" capture_android_transport_diagnostics \
  "$SERVER_LOG_ARTIFACTS" "emulator-5554" "recreated" "$SERVER_LOG_ARTIFACTS/recreated"
[[ "$(server_log_body recreated)" == 'new server' ]]
printf '%s\n' 'other server line one' 'other server line two' >"$SERVER_LOG.moved"
ANDROID_ADB_LOG_PATH="$SERVER_LOG.moved" capture_android_transport_diagnostics \
  "$SERVER_LOG_ARTIFACTS" "emulator-5554" "moved" "$SERVER_LOG_ARTIFACTS/moved"
[[ "$(server_log_body moved)" == $'other server line one\nother server line two' ]]

# No copy is longer than 2 MiB, however much the log gained.
head -c 3145728 /dev/zero | tr '\0' 'x' >>"$SERVER_LOG.moved"
ANDROID_ADB_LOG_PATH="$SERVER_LOG.moved" capture_android_transport_diagnostics \
  "$SERVER_LOG_ARTIFACTS" "emulator-5554" "flood" "$SERVER_LOG_ARTIFACTS/flood"
FLOOD_LOG="$SERVER_LOG_ARTIFACTS/flood/adb-server.log"
[[ "$(tail -n +2 "$FLOOD_LOG" | tr -cd x | wc -c | tr -d ' ')" -eq 2097152 ]]
[[ "$(tail -n +2 "$FLOOD_LOG" | wc -c | tr -d ' ')" -eq 2097152 ]]
grep -Fq "bytes $((3145728 - 2097152 + 44))-$((3145728 + 44)) (last 2 MiB)" \
  "$FLOOD_LOG"

# ADB moves onto adbd's TCP listener through the emulator's port redirect.
reset_adb_tcp() {
  rm -f "$TEST_DIR/adb-tcpip" "$TEST_DIR/adb-tcp-connected" "$TEST_DIR/adb-offline-polls" \
    "$TEST_DIR/adb-tcp-registered" "$TEST_DIR/adb-tcp-stale-connects" "$TEST_DIR/adb-redir" \
    "$TEST_DIR/adb-redir-refusals" "$TEST_DIR/adb-tcp-booting" "$TEST_DIR/adb-transport.log" \
    "$TEST_DIR/adb-tcp-online-after"
  : >"$ADB_LOG"
  NOTES=""
  ADB_TCP_ANSWERS=1
  ADB_TCP_DEFAULT_LISTENER=0
  ADB_TCP_ALWAYS_STALE=0
  ADB_TCP_BOOT_ID="boot-a"
  ADB_STATE="device"
  ADB_BOOTED="1"
  unset ANDROID_ADB_SERIAL ANDROID_EMULATOR_SERIAL ANDROID_ADB_TCP_SWITCH E2E_DEVICE_ID
}
# TCP is on by default in CI and headless runs; these tests run as headless.
HEADLESS=1
reset_adb_tcp
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
[[ "$ANDROID_EMULATOR_SERIAL" == "emulator-5554" ]]
grep -Fxq -- '-s emulator-5554 tcpip 5555' "$ADB_LOG"
grep -Fxq -- '-s emulator-5554 emu redir add tcp:5600:5555' "$ADB_LOG"
grep -Fxq -- 'connect 127.0.0.1:5600' "$ADB_LOG"
grep -Fq 'adb transport: tcp (127.0.0.1:5600' <<<"$NOTES"
grep -Fq 'connected to 127.0.0.1:5600' "$TEST_DIR/adb-transport.log"
grep -Fxq 'boot_id boot-a on both serials' "$TEST_DIR/adb-transport.log"
grep -Eq '^pass 1 \+[0-9]+s: device$' "$TEST_DIR/adb-transport.log"
# Once adbd listens on TCP, a second switch does not restart it again, and the
# emulator's existing redirect is used as it is.
: >"$ADB_LOG"
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
if grep -Fq 'tcpip' "$ADB_LOG"; then
  echo "expected no adbd restart when it already listens on TCP" >&2
  exit 1
fi
[[ "$(grep -Fxc -- '-s emulator-5554 emu redir add tcp:5600:5555' "$ADB_LOG")" -eq 1 ]]
grep -Fq 'host port already active' "$TEST_DIR/adb-transport.log"

# The first connect can leave the TCP serial registered but offline, after
# which `adb connect` only says "already connected". The switch logs the
# state on every pass, then disconnects the stale serial and dials again; the
# redirect, added once, is still there.
reset_adb_tcp
ADB_TCP_DEFAULT_LISTENER=1
printf 1 >"$TEST_DIR/adb-tcp-stale-connects"
ANDROID_ADB_TCP_RECONNECT_SECONDS=0
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
unset ANDROID_ADB_TCP_RECONNECT_SECONDS
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
[[ "$(grep -Fxc 'connect 127.0.0.1:5600' "$ADB_LOG")" -eq 2 ]]
[[ "$(grep -Fxc 'disconnect 127.0.0.1:5600' "$ADB_LOG")" -eq 2 ]]
[[ "$(grep -Fxc -- '-s emulator-5554 emu redir add tcp:5600:5555' "$ADB_LOG")" -eq 1 ]]
grep -Eq '^pass 1 \+[0-9]+s: error: device offline$' "$TEST_DIR/adb-transport.log"
grep -Fq 'reconnecting: 127.0.0.1:5600 still not a device' "$TEST_DIR/adb-transport.log"
grep -Fq 'tcp:5600  => 5555' "$TEST_DIR/adb-transport.log"
grep -Eq '^pass 2 \+[0-9]+s: device$' "$TEST_DIR/adb-transport.log"
if grep -Fq 'already connected' "$TEST_DIR/adb-transport.log"; then
  echo "expected a redial, not another connect to the registered serial" >&2
  exit 1
fi
# Before the reconnect interval has passed, a pass leaves the connection alone.
reset_adb_tcp
ADB_TCP_DEFAULT_LISTENER=1
printf 1 >"$TEST_DIR/adb-tcp-stale-connects"
ANDROID_ADB_TCP_TIMEOUT_SECONDS=1
ANDROID_ADB_TCP_RECONNECT_SECONDS=60
TCP_OUTPUT=$(use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"; printf 'serial=%s\n' "$ANDROID_ADB_SERIAL")
unset ANDROID_ADB_TCP_TIMEOUT_SECONDS ANDROID_ADB_TCP_RECONNECT_SECONDS
grep -Fxq 'serial=emulator-5554' <<<"$TCP_OUTPUT"
[[ "$(grep -Fxc 'connect 127.0.0.1:5600' "$ADB_LOG")" -eq 1 ]]

# A serial that is a device but still booting is waited for, not redialled.
reset_adb_tcp
ADB_TCP_DEFAULT_LISTENER=1
printf 2 >"$TEST_DIR/adb-tcp-booting"
ANDROID_ADB_TCP_RECONNECT_SECONDS=0
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
unset ANDROID_ADB_TCP_RECONNECT_SECONDS
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
[[ "$(grep -Fxc 'connect 127.0.0.1:5600' "$ADB_LOG")" -eq 1 ]]

# A redirect the console refuses at first is asked for again until it is
# added, then never again. A connect refused for want of it registers nothing,
# so the next pass dials straight away rather than waiting to redial.
reset_adb_tcp
ADB_TCP_DEFAULT_LISTENER=1
printf 2 >"$TEST_DIR/adb-redir-refusals"
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
[[ "$(grep -Fxc -- '-s emulator-5554 emu redir add tcp:5600:5555' "$ADB_LOG")" -eq 3 ]]
[[ "$(grep -Fxc 'connect 127.0.0.1:5600' "$ADB_LOG")" -eq 3 ]]
[[ "$(grep -Fxc 'disconnect 127.0.0.1:5600' "$ADB_LOG")" -eq 1 ]]
# Several stale connects in a row are each dropped and redialled.
reset_adb_tcp
ADB_TCP_DEFAULT_LISTENER=1
printf 3 >"$TEST_DIR/adb-tcp-stale-connects"
ANDROID_ADB_TCP_RECONNECT_SECONDS=0
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
unset ANDROID_ADB_TCP_RECONNECT_SECONDS
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
[[ "$(grep -Fxc 'connect 127.0.0.1:5600' "$ADB_LOG")" -eq 4 ]]
[[ "$(grep -Fc 'reconnecting: 127.0.0.1:5600' "$TEST_DIR/adb-transport.log")" -eq 3 ]]

# Each 2 s sleep between passes moves the clock on 6 s, so the default 12 s
# reconnect interval is due on the third pass.
sleep() { SECONDS=$((SECONDS + 6)); }
# A serial left offline by its first connect that comes online by itself,
# answering get-state at the third pass's check, is not redialled: the state is
# asked again right before deciding.
reset_adb_tcp
ADB_TCP_DEFAULT_LISTENER=1
printf 1 >"$TEST_DIR/adb-tcp-stale-connects"
printf 2 >"$TEST_DIR/adb-tcp-online-after"
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
[[ "$(grep -Fxc 'connect 127.0.0.1:5600' "$ADB_LOG")" -eq 1 ]]
[[ "$(grep -Fxc 'disconnect 127.0.0.1:5600' "$ADB_LOG")" -eq 1 ]]
grep -Eq '^pass 2 \+[0-9]+s: error: device offline$' "$TEST_DIR/adb-transport.log"
grep -Eq '^pass 3 \+[0-9]+s: device$' "$TEST_DIR/adb-transport.log"
if grep -Fq 'reconnecting:' "$TEST_DIR/adb-transport.log"; then
  echo "expected no redial of a serial that came online before the check" >&2
  exit 1
fi
sleep() { :; }

# A serial that never comes online, redialled on every pass, is still bounded
# by the budget and falls back to the emulator pipe without failing the run.
reset_adb_tcp
ADB_TCP_DEFAULT_LISTENER=1
ADB_TCP_ALWAYS_STALE=1
ANDROID_ADB_TCP_TIMEOUT_SECONDS=5
ANDROID_ADB_TCP_RECONNECT_SECONDS=0
STARTED_AT=$SECONDS
TCP_OUTPUT=$(use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"; printf 'status=%s serial=%s\n' "$?" "$ANDROID_ADB_SERIAL")
unset ANDROID_ADB_TCP_TIMEOUT_SECONDS ANDROID_ADB_TCP_RECONNECT_SECONDS
(( SECONDS - STARTED_AT <= 20 ))
grep -Fxq 'status=0 serial=emulator-5554' <<<"$TCP_OUTPUT"
grep -Eq '^::warning::adb transport: emulator pipe \(emulator-5554\); adbd did not answer on 127.0.0.1:5600 within 5s' <<<"$TCP_OUTPUT"
[[ "$(grep -Fxc 'connect 127.0.0.1:5600' "$ADB_LOG")" -gt 1 ]]
[[ "$(tail -n 1 "$ADB_LOG")" == "disconnect 127.0.0.1:5600" ]]

# A switch that timed out right after boot is tried once more after the build,
# in the same log, and ends on TCP when adbd answers by then.
reset_adb_tcp
ADB_TCP_DEFAULT_LISTENER=1
ADB_TCP_ALWAYS_STALE=1
ANDROID_ADB_TCP_TIMEOUT_SECONDS=1
ANDROID_ADB_TCP_RECONNECT_SECONDS=0
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log" >/dev/null
[[ "$ANDROID_ADB_SERIAL" == "emulator-5554" && "$ANDROID_ADB_TCP_SWITCH" == timeout ]]
ADB_TCP_ALWAYS_STALE=0
ANDROID_ADB_TCP_RETRY_TIMEOUT_SECONDS=2
retry_android_adb_over_tcp_after_timeout "$TEST_DIR/adb-transport.log"
unset ANDROID_ADB_TCP_RETRY_TIMEOUT_SECONDS
# The retry's budget is scoped to its own switch.
[[ "$ANDROID_ADB_TCP_TIMEOUT_SECONDS" == 1 ]]
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
[[ "$ANDROID_EMULATOR_SERIAL" == "emulator-5554" ]]
[[ "$ANDROID_ADB_TCP_SWITCH" == tcp-after-retry ]]
grep -Fq 'adb transport: tcp (127.0.0.1:5600' <<<"$NOTES"
grep -E '^== (switching|retrying)|^boot_id' "$TEST_DIR/adb-transport.log" >"$TEST_DIR/switch-order"
[[ "$(sed -E 's/ \([0-9:]+\)$//' "$TEST_DIR/switch-order" | paste -sd '|' -)" == \
   '== switching emulator-5554 to 127.0.0.1:5600|== retrying the switch, which timed out above|== switching emulator-5554 to 127.0.0.1:5600|boot_id boot-a on both serials' ]]
# Both attempts timing out keeps the emulator pipe, warns twice and never fails
# the run.
reset_adb_tcp
ADB_TCP_DEFAULT_LISTENER=1
ADB_TCP_ALWAYS_STALE=1
ANDROID_ADB_TCP_RETRY_TIMEOUT_SECONDS=2
TCP_OUTPUT=$(use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
  retry_android_adb_over_tcp_after_timeout "$TEST_DIR/adb-transport.log"
  printf 'status=%s serial=%s switch=%s\n' "$?" "$ANDROID_ADB_SERIAL" "$ANDROID_ADB_TCP_SWITCH")
unset ANDROID_ADB_TCP_RETRY_TIMEOUT_SECONDS
grep -Fxq 'status=0 serial=emulator-5554 switch=timeout' <<<"$TCP_OUTPUT"
[[ "$(grep -c '^::warning::adb transport: emulator pipe (emulator-5554); adbd did not answer' <<<"$TCP_OUTPUT")" -eq 2 ]]
# The retry runs on its own budget, not the first switch's.
grep -Fq 'adbd did not answer on 127.0.0.1:5600 within 1s' <<<"$TCP_OUTPUT"
grep -Fq 'adbd did not answer on 127.0.0.1:5600 within 2s' <<<"$TCP_OUTPUT"
[[ "$(grep -c '^== switching ' "$TEST_DIR/adb-transport.log")" -eq 2 ]]
grep -q '^== retrying the switch' "$TEST_DIR/adb-transport.log"
unset ANDROID_ADB_TCP_TIMEOUT_SECONDS ANDROID_ADB_TCP_RECONNECT_SECONDS
# An invalid retry budget is named in the warning, and the switch is not
# retried and still reads as timed out.
for bad_budget in soon 0; do
  reset_adb_tcp
  ADB_TCP_DEFAULT_LISTENER=1
  ADB_TCP_ALWAYS_STALE=1
  ANDROID_ADB_TCP_TIMEOUT_SECONDS=1
  ANDROID_ADB_TCP_RECONNECT_SECONDS=0
  use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log" >/dev/null
  : >"$ADB_LOG"
  ANDROID_ADB_TCP_RETRY_TIMEOUT_SECONDS=$bad_budget
  TCP_OUTPUT=$(retry_android_adb_over_tcp_after_timeout "$TEST_DIR/adb-transport.log"
    printf 'serial=%s switch=%s\n' "$ANDROID_ADB_SERIAL" "$ANDROID_ADB_TCP_SWITCH")
  unset ANDROID_ADB_TCP_RETRY_TIMEOUT_SECONDS ANDROID_ADB_TCP_TIMEOUT_SECONDS ANDROID_ADB_TCP_RECONNECT_SECONDS
  grep -Fxq 'serial=emulator-5554 switch=timeout' <<<"$TCP_OUTPUT"
  grep -Fq 'invalid ANDROID_ADB_TCP_RETRY_TIMEOUT_SECONDS, switch not retried' <<<"$TCP_OUTPUT"
  ! grep -Fq 'invalid ANDROID_ADB_TCP_PORT' <<<"$TCP_OUTPUT" || exit 1
  ! grep -q '^== retrying the switch' "$TEST_DIR/adb-transport.log" || exit 1
  [[ ! -s "$ADB_LOG" ]]
done
# The run summary names the transport each attempt ran on.
[[ "$(android_adb_transport_label emulator-5554 timeout)" == "emulator pipe" ]]
[[ "$(android_adb_transport_label 127.0.0.1:5600 tcp)" == "tcp" ]]
[[ "$(android_adb_transport_label 127.0.0.1:5600 tcp-after-retry)" == "tcp after retry" ]]
[[ "$(android_adb_transport_label 127.0.0.1:5600)" == "tcp" ]]
# A switch that reached TCP, or was never tried, is not tried again.
reset_adb_tcp
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
: >"$ADB_LOG"
retry_android_adb_over_tcp_after_timeout "$TEST_DIR/adb-transport.log"
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" && "$ANDROID_ADB_TCP_SWITCH" == tcp ]]
[[ ! -s "$ADB_LOG" ]]
reset_adb_tcp
ANDROID_ADB_TCP_PORT=off
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
retry_android_adb_over_tcp_after_timeout "$TEST_DIR/adb-transport.log"
unset ANDROID_ADB_TCP_PORT
[[ "$ANDROID_ADB_SERIAL" == "emulator-5554" && "$ANDROID_ADB_TCP_SWITCH" == off ]]
[[ ! -s "$ADB_LOG" && ! -e "$TEST_DIR/adb-transport.log" ]]
# An invalid reconnect interval keeps the emulator pipe.
reset_adb_tcp
ANDROID_ADB_TCP_RECONNECT_SECONDS=soon
TCP_OUTPUT=$(use_android_adb_over_tcp emulator-5554; printf 'serial=%s\n' "$ANDROID_ADB_SERIAL")
unset ANDROID_ADB_TCP_RECONNECT_SECONDS
grep -Fxq 'serial=emulator-5554' <<<"$TCP_OUTPUT"
grep -Fq 'invalid ANDROID_ADB_TCP_PORT' <<<"$TCP_OUTPUT"
# A port in the emulators' own range, or past 65535, keeps the emulator pipe
# and never dials it.
for bad_port in 5554 5555 5585 70000; do
  reset_adb_tcp
  ANDROID_ADB_TCP_PORT=$bad_port
  TCP_OUTPUT=$(use_android_adb_over_tcp emulator-5554; printf 'serial=%s\n' "$ANDROID_ADB_SERIAL")
  unset ANDROID_ADB_TCP_PORT
  grep -Fxq 'serial=emulator-5554' <<<"$TCP_OUTPUT"
  grep -Fq 'invalid ANDROID_ADB_TCP_PORT' <<<"$TCP_OUTPUT"
  [[ "$(grep -Fc "connect 127.0.0.1:$bad_port" "$ADB_LOG" 2>/dev/null || true)" == 0 ]]
done

# adbd never answering on TCP keeps the emulator pipe, with a warning, and
# never fails the run.
reset_adb_tcp
ADB_TCP_ANSWERS=0
ANDROID_ADB_TCP_TIMEOUT_SECONDS=1
TCP_OUTPUT=$(use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"; printf 'serial=%s\n' "$ANDROID_ADB_SERIAL")
unset ANDROID_ADB_TCP_TIMEOUT_SECONDS
grep -Fxq 'serial=emulator-5554' <<<"$TCP_OUTPUT"
grep -Eq '^::warning::adb transport: emulator pipe \(emulator-5554\); adbd did not answer on 127.0.0.1:5600' <<<"$TCP_OUTPUT"
[[ "$(tail -n 1 "$ADB_LOG")" == "disconnect 127.0.0.1:5600" ]]

# The switch can be turned off.
reset_adb_tcp
ANDROID_ADB_TCP_PORT=off
use_android_adb_over_tcp emulator-5554
unset ANDROID_ADB_TCP_PORT
[[ "$ANDROID_ADB_SERIAL" == "emulator-5554" ]]
[[ ! -s "$ADB_LOG" ]]

# Outside CI and headless runs the switch is off unless ANDROID_ADB_TCP_PORT
# asks for it.
reset_adb_tcp
CI="" HEADLESS=0 use_android_adb_over_tcp emulator-5554
[[ "$ANDROID_ADB_SERIAL" == "emulator-5554" ]]
[[ ! -s "$ADB_LOG" ]]
grep -Fq 'TCP is the default only in CI or --headless' <<<"$NOTES"
reset_adb_tcp
CI=true HEADLESS=0 use_android_adb_over_tcp emulator-5554
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
reset_adb_tcp
CI="" HEADLESS=0 ANDROID_ADB_TCP_PORT=5600 use_android_adb_over_tcp emulator-5554
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]

# When adbd already listens on TCP by default, no `adb tcpip` restarts it.
reset_adb_tcp
ADB_TCP_DEFAULT_LISTENER=1
use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"
[[ "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
if grep -Fq 'tcpip' "$ADB_LOG"; then
  echo "expected no adb tcpip when adbd already listens on tcp:5555" >&2
  exit 1
fi
grep -Fq 'adbd already listens on tcp:5555' "$TEST_DIR/adb-transport.log"

# Something else answering on the port (another emulator's redirect, a stale
# one) is never used: its boot_id differs from the emulator's.
reset_adb_tcp
ADB_TCP_BOOT_ID="boot-b"
TCP_OUTPUT=$(use_android_adb_over_tcp emulator-5554 "$TEST_DIR/adb-transport.log"; printf 'serial=%s\n' "$ANDROID_ADB_SERIAL")
grep -Fxq 'serial=emulator-5554' <<<"$TCP_OUTPUT"
grep -Fq '::warning::adb transport: emulator pipe (emulator-5554); 127.0.0.1:5600 is another device (boot_id boot-b, not boot-a)' <<<"$TCP_OUTPUT"
[[ "$(tail -n 1 "$ADB_LOG")" == "disconnect 127.0.0.1:5600" ]]

# Evidence goes over TCP while it answers, and through the emulator serial once
# TCP has dropped.
reset_adb_tcp
use_android_adb_over_tcp emulator-5554
[[ "$(android_evidence_serial 127.0.0.1:5600 emulator-5554)" == "127.0.0.1:5600" ]]
rm -f "$TEST_DIR/adb-tcp-connected"
[[ "$(android_evidence_serial 127.0.0.1:5600 emulator-5554)" == "emulator-5554" ]]
[[ "$(android_evidence_serial emulator-5554 emulator-5554)" == "emulator-5554" ]]
[[ "$(android_evidence_serial emulator-5554 "")" == "emulator-5554" ]]

# A command that hangs is cut off at its deadline (at least 2 seconds).
STARTED_AT=$SECONDS
set +e
android_run_until $((SECONDS + 1)) /bin/sleep 30
RUN_UNTIL_RESULT=$?
set -e
[[ "$RUN_UNTIL_RESULT" -eq 124 ]]
(( SECONDS - STARTED_AT <= 5 ))
android_run_until $((SECONDS + 5)) true
[[ "$(android_run_until $((SECONDS + 5)) printf ok)" == ok ]]
set +e
android_run_until $((SECONDS + 5)) false
RUN_UNTIL_RESULT=$?
set -e
[[ "$RUN_UNTIL_RESULT" -eq 1 ]]

# A drop on TCP reboots through the emulator, whose transport survives the
# reboot, then moves the retry back onto TCP, since the reboot ended adbd's
# TCP listener.
reset_adb_tcp
use_android_adb_over_tcp emulator-5554
: >"$ADB_LOG"
write_pre_identify_fixture
run_pre_identify_recovery 127.0.0.1:5600
[[ "$android_recovery_result" -eq 0 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 1 ]]
grep -Fxq -- '-s emulator-5554 reboot' "$ADB_LOG"
[[ "$(grep -Fxc -- '-s emulator-5554 tcpip 5555' "$ADB_LOG")" -eq 1 ]]
[[ "$E2E_DEVICE_ID" == "127.0.0.1:5600" && "$ANDROID_ADB_SERIAL" == "127.0.0.1:5600" ]]
grep -Fq '== after restart' \
  "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/adb-state.txt"
grep -Fq 'switching emulator-5554 to 127.0.0.1:5600' "$TRANSPORT_ARTIFACTS/adb-transport.log"
# The guest is asked through the emulator serial, and the TCP serial's own
# state is recorded beside it.
grep -Fxq -- '-- get-state 127.0.0.1:5600' \
  "$TRANSPORT_ARTIFACTS/device-recovery-attempt-1/adb-state.txt"
grep -Fxq -- '-s emulator-5554 shell cat /proc/uptime' "$ADB_LOG"
if grep -Fq -- '-s 127.0.0.1:5600 shell cat /proc/uptime' "$ADB_LOG"; then
  echo "expected guest diagnostics through the emulator serial" >&2
  exit 1
fi

# A drop that leaves the TCP serial missing ("not found") is retried too.
reset_adb_tcp
use_android_adb_over_tcp emulator-5554
write_pre_identify_fixture
sed -i.bak \
  "s/maestro.android.DeviceServerDiedException: .*/CommandFailed: device '127.0.0.1:5600' not found/" \
  "$TRANSPORT_ARTIFACTS/debug/maestro.log"
run_pre_identify_recovery 127.0.0.1:5600
[[ "$android_recovery_result" -eq 0 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 1 ]]

# If TCP does not come back after the reboot, the retry runs on the emulator
# pipe rather than on a serial that no longer answers.
reset_adb_tcp
use_android_adb_over_tcp emulator-5554
ADB_TCP_ANSWERS=0
ANDROID_ADB_TCP_TIMEOUT_SECONDS=1
write_pre_identify_fixture
run_pre_identify_recovery 127.0.0.1:5600
unset ANDROID_ADB_TCP_TIMEOUT_SECONDS
[[ "$android_recovery_result" -eq 0 ]]
[[ "$ANDROID_RETRY_CALLS" -eq 1 ]]
[[ "$E2E_DEVICE_ID" == "emulator-5554" && "$ANDROID_ADB_SERIAL" == "emulator-5554" ]]
grep -Eq '^::warning::adb transport: emulator pipe' "$RECOVERY_OUTPUT"
unset ANDROID_ADB_SERIAL ANDROID_EMULATOR_SERIAL E2E_DEVICE_ID

echo "Android device fallback tests passed"
