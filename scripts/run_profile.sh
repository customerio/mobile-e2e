#!/usr/bin/env bash
# Runs a named set of existing one-flow E2E commands. Local profiles run
# sequentially, build once per platform, preserve all evidence, and report every
# failure at the end instead of stopping after the first failed suite.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="standard"
PLATFORM="all"
FOCUSED_SUITE=""
ANDROID_REPO="${ANDROID_SDK_REPO:-}"
IOS_REPO="${IOS_SDK_REPO:-}"
KEEP_DEVICE=0
HEADLESS=0
RESULTS=()
FAILURES=0
ANDROID_PREEXISTING=""
IOS_PREEXISTING=""

usage() {
  printf '%s\n' 'Run Customer.io mobile E2E profiles.'
  printf '\nUsage:\n'
  printf '  ./e2e test [--profile quick|standard|all|remote]\n'
  printf '             [--platform all|android|ios] [--suite NAME]\n'
  printf '             [--android-sdk-repo PATH] [--ios-sdk-repo PATH]\n'
  printf '             [--keep-device] [--headless]\n'
}

die() {
  echo "error: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --suite) FOCUSED_SUITE="${2:-}"; shift 2 ;;
    --android-sdk-repo) ANDROID_REPO="${2:-}"; shift 2 ;;
    --ios-sdk-repo) IOS_REPO="${2:-}"; shift 2 ;;
    --keep-device) KEEP_DEVICE=1; shift ;;
    --headless) HEADLESS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

case "$PROFILE" in
  quick|standard|remote) ;;
  all) PROFILE="standard" ;;
  *) die "--profile must be quick, standard, all, or remote" ;;
esac
case "$PLATFORM" in
  all|android|ios) ;;
  Android|ANDROID) PLATFORM="android" ;;
  iOS|IOS) PLATFORM="ios" ;;
  *) die "--platform must be all, android, or ios" ;;
esac

timestamp="$(date +%Y%m%d-%H%M%S)"
SUMMARY_DIR="$HARNESS_DIR/artifacts/e2e/profile-$timestamp"
SUMMARY_FILE="$SUMMARY_DIR/summary.md"
mkdir -p "$SUMMARY_DIR"

suite_artifact_name() {
  case "$1" in
    smoke) echo "smoke_login_event" ;;
    geofence) echo "geofence_basic" ;;
    message-inbox|inbox) echo "message_inbox" ;;
    live-activities|live-activities-remote) echo "live_activities" ;;
    live-notifications|live-notifications-remote) echo "live_notifications_android" ;;
    campaign) echo "campaign_141" ;;
    inline) echo "inline_messages" ;;
    *) echo "$1" ;;
  esac
}

suites_for() {
  local target_platform="$1"
  if [[ -n "$FOCUSED_SUITE" ]]; then
    echo "$FOCUSED_SUITE"
    return
  fi
  case "$PROFILE:$target_platform" in
    quick:android|quick:ios)
      echo "smoke"
      ;;
    standard:android)
      echo "smoke geofence message-inbox"
      ;;
    standard:ios)
      echo "smoke geofence message-inbox live-activities"
      ;;
    remote:android)
      # Android remote Live Notifications are not yet a deterministic gating lane.
      echo ""
      ;;
    remote:ios)
      echo "live-activities-remote"
      ;;
  esac
}

record_result() {
  local target_platform="$1"
  local suite="$2"
  local status="$3"
  local seconds="$4"
  local evidence_path="$5"
  RESULTS+=("$target_platform|$suite|$status|$seconds|$evidence_path")
}

detect_preexisting_devices() {
  if command -v adb >/dev/null 2>&1; then
    ANDROID_PREEXISTING="$(adb devices 2>/dev/null | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}' || true)"
  fi
  if command -v xcrun >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    local devices_json
    devices_json="$(DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
      xcrun simctl list devices booted -j 2>/dev/null || true)"
    if [[ -n "$devices_json" ]]; then
      IOS_PREEXISTING="$(printf '%s' "$devices_json" | jq -r \
        '[.devices[][] | select(.state == "Booted") | select(.name | startswith("iPhone"))][0].udid // empty' \
        2>/dev/null || true)"
    fi
  fi
}

cleanup_platform_device() {
  local target_platform="$1"
  if [[ "$KEEP_DEVICE" == 1 ]]; then
    return
  fi
  if [[ "$target_platform" == "android" && -z "$ANDROID_PREEXISTING" ]] && command -v adb >/dev/null 2>&1; then
    local serial
    serial="$(adb devices 2>/dev/null | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}' || true)"
    if [[ -n "$serial" ]]; then
      adb -s "$serial" emu kill >/dev/null 2>&1 || true
    fi
  elif [[ "$target_platform" == "ios" && -z "$IOS_PREEXISTING" ]] && command -v xcrun >/dev/null 2>&1; then
    local udid
    local devices_json
    devices_json="$(DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
      xcrun simctl list devices booted -j 2>/dev/null || true)"
    udid=""
    if [[ -n "$devices_json" ]]; then
      udid="$(printf '%s' "$devices_json" | jq -r \
        '[.devices[][] | select(.state == "Booted") | select(.name | startswith("iPhone"))][0].udid // empty' \
        2>/dev/null || true)"
    fi
    if [[ -n "$udid" ]]; then
      DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    fi
  fi
}

run_platform() {
  local target_platform="$1"
  local repo="$2"
  local suites
  suites="$(suites_for "$target_platform")"
  if [[ -z "$suites" ]]; then
    echo ">> no $PROFILE suites are currently defined for $target_platform; skipping"
    return
  fi
  [[ -n "$repo" ]] || die "$target_platform SDK repo is not configured"

  echo ">> preflighting $target_platform"
  local doctor_suite
  doctor_suite="${suites%% *}"
  case " $suites " in
    *" live-activities-remote "*) doctor_suite="live-activities-remote" ;;
    *" live-notifications-remote "*) doctor_suite="live-notifications-remote" ;;
    *" message-inbox "*) doctor_suite="message-inbox" ;;
  esac
  local doctor_dir="$SUMMARY_DIR/$target_platform/doctor"
  local doctor_log="$doctor_dir/doctor.log"
  mkdir -p "$doctor_dir"
  set +e
  "$HARNESS_DIR/e2e" doctor --platform "$target_platform" --suite "$doctor_suite" --sdk-repo "$repo" \
    >"$doctor_log" 2>&1
  local doctor_result=$?
  set -e
  if [[ "$doctor_result" -ne 0 ]]; then
    cat "$doctor_log" >&2
    echo "error: $target_platform preflight failed" >&2
    record_result "$target_platform" "doctor" "FAILED" "0" "$doctor_dir"
    FAILURES=$((FAILURES + 1))
    return
  fi

  local first=1
  local suite
  for suite in $suites; do
    local artifact_name
    artifact_name="$(suite_artifact_name "$suite")"
    local source_artifacts="$repo/artifacts/e2e/$target_platform/$artifact_name"
    local evidence_artifacts="$SUMMARY_DIR/$target_platform/$artifact_name"
    mkdir -p "$source_artifacts" "$evidence_artifacts"
    # Per-flow SDK artifact paths are stable for focused debugging. Clear them
    # before a profile suite so a pre-build/device failure cannot inherit a
    # previous run's build log, video, or backend evidence.
    find "$source_artifacts" -mindepth 1 -delete

    local args=(run --platform "$target_platform" --suite "$suite" --sdk-repo "$repo" --skip-doctor)
    # Android is expensive to cold-boot and is stable across Maestro sessions.
    # iOS defaults to a clean Simulator session between suites because stale
    # XCUITest input services can silently drop text entry.
    if [[ "$target_platform" == "android" || "$KEEP_DEVICE" == 1 ]]; then
      args+=(--keep-device)
    fi
    if [[ "$first" == 0 ]]; then
      args+=(--skip-build)
    fi
    if [[ "$HEADLESS" == 1 ]]; then
      args+=(--headless)
    fi

    echo
    echo ">> [$target_platform] running $suite"
    local started
    started="$(date +%s)"
    set +e
    "$HARNESS_DIR/e2e" "${args[@]}"
    local result=$?
    set -e
    local elapsed=$(( $(date +%s) - started ))

    local build_log="$source_artifacts/build.log"
    local build_succeeded=0
    if [[ "$result" == 0 ]] ||
       { [[ -f "$build_log" ]] && grep -Eq 'BUILD SUCCESSFUL|\*\* BUILD SUCCEEDED \*\*' "$build_log"; }; then
      build_succeeded=1
    fi

    set +e
    cp -R "$source_artifacts/." "$evidence_artifacts/"
    local copy_result=$?
    set -e
    if [[ "$copy_result" -ne 0 ]]; then
      echo "error: could not archive $target_platform $suite evidence" >&2
      result=1
    fi

    if [[ "$result" == 0 ]]; then
      record_result "$target_platform" "$suite" "PASSED" "$elapsed" "$evidence_artifacts"
    else
      record_result "$target_platform" "$suite" "FAILED" "$elapsed" "$evidence_artifacts"
      FAILURES=$((FAILURES + 1))
    fi

    # A flow can fail after a successful build; keep reusing that artifact. If
    # the failure happened during the build itself, let the next suite retry it
    # instead of cascading misleading install errors from --skip-build.
    if [[ "$build_succeeded" == 1 ]]; then
      first=0
    else
      echo "warn: no successful $target_platform build found; the next suite will rebuild" >&2
    fi
  done
}

write_summary() {
  {
    echo "# Mobile SDK E2E profile"
    echo
    echo "- Profile: \`$PROFILE\`"
    echo "- Platform: \`$PLATFORM\`"
    echo "- Started: \`$timestamp\`"
    echo
    echo "| Platform | Suite | Result | Duration | Evidence |"
    echo "|---|---|---:|---:|---|"
    local row
    for row in "${RESULTS[@]}"; do
      IFS='|' read -r row_platform row_suite row_status row_seconds row_artifacts <<<"$row"
      echo "| $row_platform | $row_suite | $row_status | ${row_seconds}s | \`$row_artifacts\` |"
    done
    echo
    if [[ "$FAILURES" == 0 ]]; then
      echo "**Overall: PASSED**"
    else
      echo "**Overall: FAILED ($FAILURES failed checks)**"
    fi
  } >"$SUMMARY_FILE"
}

detect_preexisting_devices
trap 'cleanup_platform_device android; cleanup_platform_device ios' EXIT

if [[ "$PLATFORM" == "all" || "$PLATFORM" == "android" ]]; then
  run_platform "android" "$ANDROID_REPO"
  cleanup_platform_device "android"
fi
if [[ "$PLATFORM" == "all" || "$PLATFORM" == "ios" ]]; then
  run_platform "ios" "$IOS_REPO"
  cleanup_platform_device "ios"
fi

write_summary
echo
cat "$SUMMARY_FILE"
echo
echo ">> combined summary: $SUMMARY_FILE"

if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi
