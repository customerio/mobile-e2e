#!/usr/bin/env bash
# Shared Maestro E2E runner. Called from each sample repo's .maestro/run.sh
# after it has cloned/updated this harness. Auto-detects platform (iOS
# simulator or Android emulator), orchestrates device capture, starts the
# sink, runs maestro, then renders tickmarks.html + annotated.mp4.
#
# Expected env (set by the caller):
#   APP_ID               Bundle id / package name to launch
#   PLATFORM             "iOS" or "Android" (the sample knows which it is —
#                        we don't detect from booted devices since both may
#                        be running at once)
#   HARNESS_DIR          Absolute path to this harness checkout
#   SAMPLE_MAESTRO_DIR   Absolute path to the sample's .maestro/ dir (holds .env)
#
# The caller should `cd` to the sample repo root so artifacts/ lands there.
#
# Positional args:
#   $1 — flow filename (default: campaign_141.yaml)

set -euo pipefail

FLOW="${1:-campaign_141.yaml}"
FLOW_NAME="$(basename "$FLOW" .yaml)"
OUT_DIR="${E2E_ARTIFACTS_DIR:-artifacts/$FLOW_NAME}"
DEBUG_DIR="$OUT_DIR/debug"
TEST_OUTPUT_DIR="$OUT_DIR/maestro-artifacts"
mkdir -p "$OUT_DIR" "$DEBUG_DIR"
find "$DEBUG_DIR" -mindepth 1 -delete
mkdir -p "$TEST_OUTPUT_DIR"
find "$TEST_OUTPUT_DIR" -mindepth 1 -delete
# Never leave a previous run's video looking like evidence for the current run
# when capture or annotated rendering fails partway through.
rm -f "$OUT_DIR/device.mp4" "$OUT_DIR/annotated.mp4"

# --- Env
# The top-level runner has already applied caller > shared file > sample file
# precedence. Direct low-level invocations still load the sample-local file.
CALLER_REMOTE_FLAG_SET="${MAESTRO_LIVE_ACTIVITY_REMOTE_ENABLED+x}"
CALLER_REMOTE_FLAG="${MAESTRO_LIVE_ACTIVITY_REMOTE_ENABLED:-}"
CALLER_NOTIFICATION_REMOTE_FLAG_SET="${MAESTRO_LIVE_NOTIFICATION_REMOTE_ENABLED+x}"
CALLER_NOTIFICATION_REMOTE_FLAG="${MAESTRO_LIVE_NOTIFICATION_REMOTE_ENABLED:-}"
CALLER_INBOX_MESSAGE_ID_SET="${INBOX_TRANSACTIONAL_MESSAGE_ID+x}"
CALLER_INBOX_MESSAGE_ID="${INBOX_TRANSACTIONAL_MESSAGE_ID:-}"
if [[ "${E2E_ENV_PRELOADED:-false}" != "true" && -f "$SAMPLE_MAESTRO_DIR/.env" ]]; then
  set -a; source "$SAMPLE_MAESTRO_DIR/.env"; set +a
fi
if [[ "$CALLER_REMOTE_FLAG_SET" == "x" ]]; then
  MAESTRO_LIVE_ACTIVITY_REMOTE_ENABLED="$CALLER_REMOTE_FLAG"
fi
if [[ "$CALLER_NOTIFICATION_REMOTE_FLAG_SET" == "x" ]]; then
  MAESTRO_LIVE_NOTIFICATION_REMOTE_ENABLED="$CALLER_NOTIFICATION_REMOTE_FLAG"
fi
if [[ "$CALLER_INBOX_MESSAGE_ID_SET" == "x" ]]; then
  INBOX_TRANSACTIONAL_MESSAGE_ID="$CALLER_INBOX_MESSAGE_ID"
fi
: "${MAESTRO_APP_API_KEY:=${MAESTRO_EXT_API_KEY:-}}"
: "${MAESTRO_EXT_API_BASE_URL:=https://api.customer.io/v1}"
if [[ -z "${MAESTRO_APP_API_KEY:-}" ]]; then
  echo "warn: MAESTRO_APP_API_KEY not set; backend assertions will fail auth" >&2
fi
: "${MAESTRO_LIVE_API_BASE_URL:=$MAESTRO_EXT_API_BASE_URL}"
: "${MAESTRO_LIVE_ACTIVITY_REMOTE_ENABLED:=false}"
: "${MAESTRO_LIVE_ACTIVITY_DEVICE_BACKEND_ENABLED:=false}"
: "${MAESTRO_LIVE_NOTIFICATION_REMOTE_ENABLED:=false}"
: "${MAESTRO_INBOX_API_BASE_URL:=https://consumer.inapp.customer.io}"
: "${MAESTRO_INBOX_DATACENTER:=US}"
: "${MAESTRO_INBOX_CLIENT_PLATFORM:=customerio-maestro}"
: "${MAESTRO_SITE_ID:=}"
: "${INBOX_TRANSACTIONAL_MESSAGE_ID:=}"
: "${LIVE_NOTIFICATION_PLATFORM:=ios}"
: "${LIVE_NOTIFICATION_APP_IDENTIFIER:=${LIVE_ACTIVITY_APP_IDENTIFIER:-}}"
if [[ "$LIVE_NOTIFICATION_PLATFORM" == "ios" ]]; then
  : "${LIVE_NOTIFICATION_DEEP_LINK:=apn-uikit://live-activities}"
else
  : "${LIVE_NOTIFICATION_DEEP_LINK:=}"
fi
: "${E2E_SINK_PORT:=0}"
: "${E2E_SINK_START_TIMEOUT_SECONDS:=20}"
export MAESTRO_EXT_API_BASE_URL MAESTRO_LIVE_API_BASE_URL MAESTRO_APP_API_KEY
: "${APP_ID:?APP_ID must be exported by the sample repo run.sh}"
: "${PLATFORM:?PLATFORM must be exported by the sample repo run.sh (iOS or Android)}"

if ! [[ "$E2E_SINK_START_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: E2E_SINK_START_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

BOOTED=""
ANDROID_DEVICE=""
if [[ "$PLATFORM" == iOS ]]; then
  BOOTED="${E2E_DEVICE_ID:-}"
  if [[ -z "$BOOTED" ]]; then
    BOOTED=$(xcrun simctl list devices booted 2>/dev/null \
      | grep -E 'iPhone.*\(Booted\)' \
      | grep -Eo '\(([0-9A-F-]{36})\)' \
      | head -1 \
      | tr -d '()' || true)
  fi
  if [[ -z "$BOOTED" ]]; then
    echo "error: no booted iPhone simulator" >&2; exit 2
  fi
  if ! xcrun simctl list devices booted | grep -Fq "$BOOTED"; then
    echo "error: selected iOS simulator $BOOTED is not booted" >&2; exit 2
  fi
elif [[ "$PLATFORM" == Android ]]; then
  ANDROID_DEVICE="${E2E_DEVICE_ID:-}"
  if [[ -z "$ANDROID_DEVICE" ]]; then
    ANDROID_DEVICE=$(adb devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')
  fi
  if [[ -z "$ANDROID_DEVICE" || "$(adb -s "$ANDROID_DEVICE" get-state 2>/dev/null || true)" != "device" ]]; then
    echo "error: selected Android emulator is not attached" >&2; exit 2
  fi
else
  echo "error: unknown PLATFORM '$PLATFORM' (expected iOS or Android)" >&2; exit 2
fi
echo ">> platform: $PLATFORM${BOOTED:+ (sim $BOOTED)}"

# --- Flow resolution: prefer a local override in .maestro/, fall back to harness.
resolve_flow() {
  local name="$1"
  if [[ -f ".maestro/$name" ]]; then echo ".maestro/$name"; return; fi
  if [[ -f "$HARNESS_DIR/flows/$name" ]]; then echo "$HARNESS_DIR/flows/$name"; return; fi
  echo ""
}
FLOW_PATH="$(resolve_flow "$FLOW")"
if [[ -z "$FLOW_PATH" ]]; then
  echo "error: flow '$FLOW' not found in .maestro/ or $HARNESS_DIR/flows/" >&2
  exit 2
fi

# --- Process cleanup. Install the trap before any background process starts so
# an early health-check failure does not leak the local result sink.
SINK_PID=""
REC_PID=""
DEVICE_LOG_PID=""
cleanup() {
  if [[ "$PLATFORM" == Android && -n "$ANDROID_DEVICE" ]]; then
    [[ -n "${ANDROID_RECORD_STOP:-}" ]] && : >"$ANDROID_RECORD_STOP"
    adb -s "$ANDROID_DEVICE" shell pkill -2 screenrecord >/dev/null 2>&1 || true
  fi
  if [[ -n "$REC_PID" ]]; then
    kill "$REC_PID" >/dev/null 2>&1 || true
    wait "$REC_PID" 2>/dev/null || true
  fi
  if [[ -n "$DEVICE_LOG_PID" ]]; then
    kill "$DEVICE_LOG_PID" >/dev/null 2>&1 || true
    wait "$DEVICE_LOG_PID" 2>/dev/null || true
  fi
  if [[ -n "$SINK_PID" ]]; then
    kill "$SINK_PID" >/dev/null 2>&1 || true
    wait "$SINK_PID" 2>/dev/null || true
  fi
  python3 "$HARNESS_DIR/scripts/redact_artifacts.py" "$OUT_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- Start local sink (backend-assertion JSON capture).
SINK_LOG="$OUT_DIR/sink.jsonl"
SINK_PORT_FILE="$OUT_DIR/sink.port"
rm -f "$SINK_PORT_FILE"
unset E2E_SINK_BASE_URL
python3 "$HARNESS_DIR/scripts/sink.py" "$SINK_LOG" \
  --port "$E2E_SINK_PORT" --port-file "$SINK_PORT_FILE" \
  >"$OUT_DIR/sink.stderr" 2>&1 &
SINK_PID=$!
SINK_START_DEADLINE=$((SECONDS + E2E_SINK_START_TIMEOUT_SECONDS))
while (( SECONDS < SINK_START_DEADLINE )); do
  kill -0 "$SINK_PID" >/dev/null 2>&1 || break
  if [[ -s "$SINK_PORT_FILE" ]]; then
    RESOLVED_SINK_PORT=$(<"$SINK_PORT_FILE")
    E2E_SINK_BASE_URL="http://127.0.0.1:$RESOLVED_SINK_PORT"
    if curl -fsS --connect-timeout 1 --max-time 2 -o /dev/null \
      "$E2E_SINK_BASE_URL/" 2>/dev/null; then break; fi
  fi
  sleep 0.2
done
if ! kill -0 "$SINK_PID" >/dev/null 2>&1 \
  || [[ -z "${E2E_SINK_BASE_URL:-}" ]] \
  || ! curl -fsS --connect-timeout 1 --max-time 2 -o /dev/null "$E2E_SINK_BASE_URL/"; then
  echo "error: local result sink failed to start within ${E2E_SINK_START_TIMEOUT_SECONDS}s" >&2
  if [[ -s "$OUT_DIR/sink.stderr" ]]; then
    echo "--- sink diagnostics ---" >&2
    sed -n '1,80p' "$OUT_DIR/sink.stderr" >&2
    echo "--- end sink diagnostics ---" >&2
  else
    echo "sink produced no diagnostics; process state: $(kill -0 "$SINK_PID" >/dev/null 2>&1 && echo running || echo exited)" >&2
  fi
  exit 2
fi
export E2E_SINK_BASE_URL

# --- Start device capture.
REC_STARTED_AT_MS=$(python3 -c "import time;print(int(time.time()*1000))")
if [[ "$PLATFORM" == Android ]]; then
  ANDROID_RECORD_DIR="$OUT_DIR/android-recording"
  ANDROID_RECORD_STOP="$OUT_DIR/.stop-android-recording"
  mkdir -p "$ANDROID_RECORD_DIR"
  find "$ANDROID_RECORD_DIR" -mindepth 1 -delete
  rm -f "$ANDROID_RECORD_STOP"
  record_android_segments() {
    local index=0 remote_file local_file
    while [[ ! -f "$ANDROID_RECORD_STOP" ]]; do
      remote_file="/sdcard/maestro-run-$index.mp4"
      local_file="$ANDROID_RECORD_DIR/segment-$(printf '%04d' "$index").mp4"
      adb -s "$ANDROID_DEVICE" shell rm -f "$remote_file" >/dev/null 2>&1 || true
      adb -s "$ANDROID_DEVICE" shell screenrecord \
        --size 720x1600 --bit-rate 4000000 --time-limit 170 "$remote_file" \
        >/dev/null 2>&1 || true
      adb -s "$ANDROID_DEVICE" pull "$remote_file" "$local_file" >/dev/null 2>&1 || true
      adb -s "$ANDROID_DEVICE" shell rm -f "$remote_file" >/dev/null 2>&1 || true
      index=$((index + 1))
    done
  }
  record_android_segments &
  REC_PID=$!
  adb -s "$ANDROID_DEVICE" logcat -v threadtime \
    'CustomerIO:V' 'AndroidRuntime:E' 'ActivityManager:W' '*:S' \
    >"$OUT_DIR/device-live.log" 2>&1 &
  DEVICE_LOG_PID=$!
else
  FRAMES_DIR="$OUT_DIR/frames"
  rm -rf "$FRAMES_DIR" && mkdir -p "$FRAMES_DIR"
  "$HARNESS_DIR/scripts/capture_frames.sh" "$BOOTED" "$FRAMES_DIR" >"$OUT_DIR/capture.log" 2>&1 &
  REC_PID=$!
fi

# --- Run maestro.
echo ">> running maestro: $FLOW_PATH"
MAESTRO_DEVICE_ARGS=()
if [[ "$PLATFORM" == iOS ]]; then
  MAESTRO_DEVICE_ARGS=(--device "$BOOTED")
else
  [[ -n "$ANDROID_DEVICE" ]] && MAESTRO_DEVICE_ARGS=(--device "$ANDROID_DEVICE")
fi
if [[ -n "${CI:-}" ]]; then
  REPORT_ARGS=(--format=JUNIT --output="$OUT_DIR/report.xml")
else
  REPORT_ARGS=(--format=HTML-DETAILED --output="$OUT_DIR/report.html")
fi
RESOLVED_GEOFENCE_ID="${GEOFENCE_ID:-}"
if [[ -z "$RESOLVED_GEOFENCE_ID" ]]; then
  if [[ "$PLATFORM" == Android ]]; then
    RESOLVED_GEOFENCE_ID="83"
  else
    RESOLVED_GEOFENCE_ID="3488"
  fi
fi
if [[ -n "$RESOLVED_GEOFENCE_ID" ]]; then
  GEOFENCE_EXPECTED_PROPERTY="geofence_id"
else
  GEOFENCE_EXPECTED_PROPERTY=""
fi
set +e
maestro "${MAESTRO_DEVICE_ARGS[@]}" test \
  "${REPORT_ARGS[@]}" \
  --debug-output="$DEBUG_DIR" --flatten-debug-output \
  --test-output-dir="$TEST_OUTPUT_DIR" \
  --test-suite-name="Customer.io SDK $PLATFORM $FLOW_NAME" \
  -e "APP_ID=$APP_ID" \
  -e "MAESTRO_EXT_API_BASE_URL=$MAESTRO_EXT_API_BASE_URL" \
  -e "MAESTRO_APP_API_KEY=${MAESTRO_APP_API_KEY:-}" \
  -e "MAESTRO_LIVE_API_BASE_URL=$MAESTRO_LIVE_API_BASE_URL" \
  -e "MAESTRO_LIVE_ACTIVITY_REMOTE_ENABLED=$MAESTRO_LIVE_ACTIVITY_REMOTE_ENABLED" \
  -e "MAESTRO_LIVE_ACTIVITY_DEVICE_BACKEND_ENABLED=$MAESTRO_LIVE_ACTIVITY_DEVICE_BACKEND_ENABLED" \
  -e "MAESTRO_LIVE_NOTIFICATION_REMOTE_ENABLED=$MAESTRO_LIVE_NOTIFICATION_REMOTE_ENABLED" \
  -e "LIVE_ACTIVITY_APP_IDENTIFIER=${LIVE_ACTIVITY_APP_IDENTIFIER:-}" \
  -e "LIVE_NOTIFICATION_PLATFORM=$LIVE_NOTIFICATION_PLATFORM" \
  -e "LIVE_NOTIFICATION_APP_IDENTIFIER=$LIVE_NOTIFICATION_APP_IDENTIFIER" \
  -e "LIVE_NOTIFICATION_DEEP_LINK=$LIVE_NOTIFICATION_DEEP_LINK" \
  -e "MAESTRO_INBOX_API_BASE_URL=$MAESTRO_INBOX_API_BASE_URL" \
  -e "MAESTRO_INBOX_DATACENTER=$MAESTRO_INBOX_DATACENTER" \
  -e "MAESTRO_INBOX_CLIENT_PLATFORM=$MAESTRO_INBOX_CLIENT_PLATFORM" \
  -e "MAESTRO_SITE_ID=$MAESTRO_SITE_ID" \
  -e "INBOX_TRANSACTIONAL_MESSAGE_ID=$INBOX_TRANSACTIONAL_MESSAGE_ID" \
  -e "E2E_SINK_BASE_URL=$E2E_SINK_BASE_URL" \
  -e "E2E_RUN_ID=${E2E_RUN_ID:-}" \
  -e "GEOFENCE_OUTSIDE_LATITUDE=${GEOFENCE_OUTSIDE_LATITUDE:-40.7000}" \
  -e "GEOFENCE_OUTSIDE_LONGITUDE=${GEOFENCE_OUTSIDE_LONGITUDE:--74.0200}" \
  -e "GEOFENCE_INSIDE_LATITUDE=${GEOFENCE_INSIDE_LATITUDE:-40.7128}" \
  -e "GEOFENCE_INSIDE_LONGITUDE=${GEOFENCE_INSIDE_LONGITUDE:--74.0060}" \
  -e "GEOFENCE_ID=$RESOLVED_GEOFENCE_ID" \
  -e "GEOFENCE_EXPECTED_PROPERTY=$GEOFENCE_EXPECTED_PROPERTY" \
  "$FLOW_PATH" | tee "$OUT_DIR/run.log"
EXIT=$?
set -e

# Maestro persists imported flow variables in commands-*.json. Scrub backend
# API keys before the report renderer reads that JSON or CI can upload it.
if ! python3 "$HARNESS_DIR/scripts/redact_artifacts.py" "$OUT_DIR"; then
  echo "error: failed to sanitize E2E artifacts" >&2
  EXIT=1
fi

# --- Stop capture, assemble device.mp4.
if [[ "$PLATFORM" == Android ]]; then
  : >"$ANDROID_RECORD_STOP"
  adb -s "$ANDROID_DEVICE" shell pkill -2 screenrecord >/dev/null 2>&1 || true
  wait "$REC_PID" 2>/dev/null || true
  REC_PID=""
  SEGMENT_LIST="$OUT_DIR/android-segments.txt"
  : >"$SEGMENT_LIST"
  SEGMENT_COUNT=0
  for segment in "$ANDROID_RECORD_DIR"/segment-*.mp4; do
    [[ -f "$segment" ]] || continue
    printf "file '%s'\n" "$segment" >>"$SEGMENT_LIST"
    SEGMENT_COUNT=$((SEGMENT_COUNT + 1))
  done
  if [[ "$SEGMENT_COUNT" -gt 0 ]]; then
    ffmpeg -y -f concat -safe 0 -i "$SEGMENT_LIST" -c copy "$OUT_DIR/device.mp4" \
      >/dev/null 2>&1 || echo "warn: Android recording assembly failed"
  else
    echo "warn: Android screen recording produced no segments"
  fi
  if [[ -f "$OUT_DIR/device.mp4" ]]; then
    find "$ANDROID_RECORD_DIR" -mindepth 1 -delete
    rmdir "$ANDROID_RECORD_DIR"
    rm -f "$SEGMENT_LIST" "$ANDROID_RECORD_STOP"
  fi
else
  kill "$REC_PID" >/dev/null 2>&1 || true
  wait "$REC_PID" 2>/dev/null || true
  REC_ENDED_AT_MS=$(python3 -c "import time;print(int(time.time()*1000))")
  FRAME_COUNT=$(ls "$FRAMES_DIR" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$FRAME_COUNT" -gt 0 ]]; then
    # simctl screenshot latency varies with host load; encoding at the target
    # loop rate compresses the recording and drifts from Maestro timestamps.
    # Use the observed average rate so the annotated step panel stays aligned.
    FRAME_RATE=$(python3 -c \
      'import sys; frames=int(sys.argv[1]); elapsed=max(0.001, (int(sys.argv[3])-int(sys.argv[2]))/1000); print(f"{frames/elapsed:.6f}")' \
      "$FRAME_COUNT" "$REC_STARTED_AT_MS" "$REC_ENDED_AT_MS")
    ffmpeg -y -framerate "$FRAME_RATE" -i "$FRAMES_DIR/f_%06d.png" \
      -vf "scale=-2:1280:flags=lanczos,format=yuv420p" \
      -c:v libx264 -preset veryfast -crf 22 "$OUT_DIR/device.mp4" \
      >/dev/null 2>&1 || echo "warn: frame assembly failed"
  fi
  if [[ -f "$OUT_DIR/device.mp4" ]]; then
    find "$FRAMES_DIR" -mindepth 1 -delete
    rmdir "$FRAMES_DIR"
  fi
fi

kill "$SINK_PID" >/dev/null 2>&1 || true
wait "$SINK_PID" 2>/dev/null || true
SINK_PID=""

# --- Render outputs.
python3 "$HARNESS_DIR/scripts/render_report.py" \
  "$DEBUG_DIR" "$OUT_DIR/tickmarks.html" \
  --screens-dir artifacts \
  --video "$OUT_DIR/device.mp4" \
  --sink "$SINK_LOG" \
  --title "$FLOW_NAME" \
  || echo "warn: HTML evidence render failed"

if [[ -f "$OUT_DIR/device.mp4" ]]; then
  COMMANDS_JSON=""
  if [[ -d "$DEBUG_DIR" ]]; then
    COMMANDS_JSON=$(find "$DEBUG_DIR" -maxdepth 1 -type f \
      -name 'commands-*.json' -print -quit 2>/dev/null || true)
    if [[ -z "$COMMANDS_JSON" ]]; then
      COMMANDS_JSON=$(find "$DEBUG_DIR" -type f \
        -name commands.json -print -quit 2>/dev/null || true)
    fi
  fi
  if [[ -n "$COMMANDS_JSON" ]]; then
    python3 "$HARNESS_DIR/scripts/render_video.py" \
      --commands "$COMMANDS_JSON" \
      --device "$OUT_DIR/device.mp4" \
      --rec-started-ms "$REC_STARTED_AT_MS" \
      --sink "$SINK_LOG" \
      --title "$FLOW_NAME" \
      --out "$OUT_DIR/annotated.mp4" \
      || echo "warn: annotated video render failed"
  else
    echo "warn: annotated video render skipped; no Maestro commands JSON found"
  fi
fi

python3 "$HARNESS_DIR/scripts/redact_artifacts.py" "$OUT_DIR"
if ! python3 "$HARNESS_DIR/scripts/redact_artifacts.py" --check "$OUT_DIR"; then
  EXIT=1
fi

echo ">> done: $OUT_DIR/tickmarks.html (exit=$EXIT)"
if [[ -z "${CI:-}" && -z "${E2E_NO_OPEN:-}" ]]; then
  open "$OUT_DIR/tickmarks.html" 2>/dev/null || true
  open "$OUT_DIR/annotated.mp4" 2>/dev/null || true
fi
exit "$EXIT"
