#!/usr/bin/env bash
# Runs ./e2e doctor against stub tools and fixture sample repos to check how a
# missing ffmpeg is handled: Android warns and continues, iOS stops.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cio-e2e-doctor-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A PATH with every host command except ffmpeg, then stubs for the tools
# doctor only checks for or calls with fixed answers.
TOOLS="$WORK/tools"
STUBS="$WORK/stubs"
mkdir -p "$TOOLS" "$STUBS"
IFS=: read -r -a path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
  for tool in "$dir"/*; do
    name="$(basename "$tool")"
    [[ "$name" == ffmpeg || -e "$TOOLS/$name" || ! -x "$tool" || -d "$tool" ]] && continue
    ln -s "$tool" "$TOOLS/$name"
  done
done
printf '#!/usr/bin/env bash\necho "2.6.0"\n' >"$STUBS/maestro"
printf '#!/usr/bin/env bash\nprintf 200\n' >"$STUBS/curl"
for tool in adb xcrun xcodebuild; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$tool"
done
mkdir -p "$WORK/android-sdk/emulator"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/android-sdk/emulator/emulator"
chmod +x "$STUBS"/* "$WORK/android-sdk/emulator/emulator"

ANDROID_REPO="$WORK/android-repo"
mkdir -p "$ANDROID_REPO/samples"
printf '#!/usr/bin/env bash\n' >"$ANDROID_REPO/gradlew"
chmod +x "$ANDROID_REPO/gradlew"
printf 'cdpApiKey=test-key\nsiteId=test-site\n' >"$ANDROID_REPO/samples/local.properties"

IOS_REPO="$WORK/ios-repo"
IOS_SAMPLE="$IOS_REPO/Apps/APN-UIKit"
mkdir -p "$IOS_SAMPLE/APN UIKit.xcodeproj" "$WORK/developer"
: >"$IOS_SAMPLE/APN UIKit.xcodeproj/project.pbxproj"
printf 'static let cdpApiKey: String = "test-key"\nstatic let siteId: String = "test-site"\n' \
  >"$IOS_SAMPLE/BuildEnvironment.swift"

run_doctor() {
  local platform="$1" repo="$2"
  env -i HOME="$WORK" PATH="$STUBS:$TOOLS" \
    E2E_ENV_FILE="$WORK/no-env" \
    MAESTRO_APP_API_KEY=test-api-key \
    ANDROID_SDK_ROOT="$WORK/android-sdk" \
    DEVELOPER_DIR="$WORK/developer" \
    bash "$ROOT/e2e" doctor --platform "$platform" --sdk-repo "$repo" >"$WORK/out" 2>&1
}

if ! run_doctor android "$ANDROID_REPO"; then
  echo "expected Android doctor to pass without ffmpeg" >&2
  cat "$WORK/out" >&2
  exit 1
fi
grep -q 'warn: ffmpeg is not installed' "$WORK/out" \
  || { echo "expected Android doctor to warn about ffmpeg" >&2; cat "$WORK/out" >&2; exit 1; }
grep -q 'doctor passed for android' "$WORK/out" \
  || { echo "expected Android doctor to finish" >&2; cat "$WORK/out" >&2; exit 1; }

status=0
run_doctor ios "$IOS_REPO" || status=$?
if [[ "$status" -ne 2 ]]; then
  echo "expected iOS doctor to stop with exit 2 without ffmpeg (got $status)" >&2
  cat "$WORK/out" >&2
  exit 1
fi
grep -q "required command 'ffmpeg' is not installed" "$WORK/out" \
  || { echo "expected iOS doctor to name ffmpeg" >&2; cat "$WORK/out" >&2; exit 1; }

# With ffmpeg back on PATH both platforms pass and Android stays quiet about it.
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/ffmpeg"
chmod +x "$STUBS/ffmpeg"
run_doctor ios "$IOS_REPO" \
  || { echo "expected iOS doctor to pass with ffmpeg" >&2; cat "$WORK/out" >&2; exit 1; }
run_doctor android "$ANDROID_REPO" \
  || { echo "expected Android doctor to pass with ffmpeg" >&2; cat "$WORK/out" >&2; exit 1; }
if grep -q 'ffmpeg' "$WORK/out"; then
  echo "expected no ffmpeg warning when ffmpeg is installed" >&2
  cat "$WORK/out" >&2
  exit 1
fi

echo "Doctor ffmpeg checks passed"
