#!/usr/bin/env bash
# One-time/actionable preflight for the deterministic local profile.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="all"
ANDROID_REPO="${ANDROID_SDK_REPO:-/Users/shahrozali/AndroidStudioProjects/customerio-android}"
IOS_REPO="${IOS_SDK_REPO:-/Users/shahrozali/iOSProjects/customerio-ios}"
FAILURES=0

usage() {
  printf '%s\n' 'Validate local Customer.io mobile E2E setup.'
  printf '\nUsage:\n'
  printf '  ./e2e setup [--platform all|android|ios]\n'
  printf '              [--android-sdk-repo PATH] [--ios-sdk-repo PATH]\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) PLATFORM="${2:-}"; shift 2 ;;
    --android-sdk-repo) ANDROID_REPO="${2:-}"; shift 2 ;;
    --ios-sdk-repo) IOS_REPO="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

case "$PLATFORM" in
  all|android|ios) ;;
  Android|ANDROID) PLATFORM="android" ;;
  iOS|IOS) PLATFORM="ios" ;;
  *) echo "error: --platform must be all, android, or ios" >&2; exit 2 ;;
esac

if [[ ! -f "$HARNESS_DIR/.env.e2e.local" ]]; then
  echo ">> optional shared config is not present: $HARNESS_DIR/.env.e2e.local"
  echo ">> copy .env.e2e.example to .env.e2e.local to keep all local E2E values in one place"
fi

check_platform() {
  local target_platform="$1"
  local repo="$2"
  echo
  echo ">> checking $target_platform"
  set +e
  "$HARNESS_DIR/e2e" doctor \
    --platform "$target_platform" \
    --suite message-inbox \
    --sdk-repo "$repo"
  local result=$?
  set -e
  if [[ "$result" -ne 0 ]]; then
    FAILURES=$((FAILURES + 1))
  fi
}

if [[ "$PLATFORM" == "all" || "$PLATFORM" == "android" ]]; then
  check_platform "android" "$ANDROID_REPO"
fi
if [[ "$PLATFORM" == "all" || "$PLATFORM" == "ios" ]]; then
  check_platform "ios" "$IOS_REPO"
fi

echo
if [[ "$FAILURES" == 0 ]]; then
  echo ">> setup passed; run ./e2e test"
else
  echo "error: setup found $FAILURES platform issue(s); fix the diagnostics above and rerun" >&2
  exit 1
fi
