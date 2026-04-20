#!/usr/bin/env bash
# Shared Maestro E2E runner. Called from each sample repo's .maestro/run.sh
# after it has cloned/updated this harness. Auto-detects platform (iOS
# simulator or Android emulator), orchestrates device capture, starts the
# sink, runs maestro, then renders tickmarks.html + annotated.mp4.
#
# Expected env (set by the caller):
#   APP_ID               Bundle id / package name to launch
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
OUT_DIR="artifacts/$FLOW_NAME"
DEBUG_DIR="$OUT_DIR/debug"
mkdir -p "$OUT_DIR" "$DEBUG_DIR"
rm -rf "$DEBUG_DIR"/*

# --- Env
if [[ -f "$SAMPLE_MAESTRO_DIR/.env" ]]; then
  set -a; source "$SAMPLE_MAESTRO_DIR/.env"; set +a
fi
if [[ -z "${MAESTRO_EXT_API_KEY:-}" ]]; then
  echo "warn: MAESTRO_EXT_API_KEY not set; backend assertions will fail auth" >&2
fi
: "${APP_ID:?APP_ID must be exported by the sample repo run.sh}"

# --- Platform detection: prefer a booted iOS sim, else a connected Android device.
PLATFORM=""; BOOTED=""
if command -v xcrun >/dev/null 2>&1; then
  BOOTED=$(xcrun simctl list devices booted 2>/dev/null | grep -Eo '\(([0-9A-F-]{36})\) \(Booted\)' | head -1 | grep -Eo '[0-9A-F-]{36}' || true)
  [[ -n "$BOOTED" ]] && PLATFORM=iOS
fi
if [[ -z "$PLATFORM" ]] && command -v adb >/dev/null 2>&1 && adb devices | grep -q "device$"; then
  PLATFORM=Android
fi
if [[ -z "$PLATFORM" ]]; then
  echo "error: no booted iOS simulator and no adb-attached Android device" >&2
  exit 2
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

# --- Start local sink (backend-assertion JSON capture).
SINK_LOG="$OUT_DIR/sink.jsonl"
python3 "$HARNESS_DIR/scripts/sink.py" "$SINK_LOG" --port 8899 >"$OUT_DIR/sink.stderr" 2>&1 &
SINK_PID=$!
for _ in 1 2 3 4 5; do
  if curl -s -o /dev/null http://127.0.0.1:8899/ ; then break; fi
  sleep 0.2
done

# --- Start device capture.
REC_STARTED_AT_MS=$(python3 -c "import time;print(int(time.time()*1000))")
if [[ "$PLATFORM" == Android ]]; then
  adb shell screenrecord --size 720x1600 --bit-rate 4000000 --time-limit 180 /sdcard/maestro-run.mp4 &
  REC_PID=$!
else
  FRAMES_DIR="$OUT_DIR/frames"
  rm -rf "$FRAMES_DIR" && mkdir -p "$FRAMES_DIR"
  "$HARNESS_DIR/scripts/capture_frames.sh" "$BOOTED" "$FRAMES_DIR" >"$OUT_DIR/capture.log" 2>&1 &
  REC_PID=$!
fi
cleanup() {
  [[ "$PLATFORM" == Android ]] && adb shell pkill -2 screenrecord >/dev/null 2>&1 || true
  kill "$REC_PID" >/dev/null 2>&1 || true
  wait "$REC_PID" 2>/dev/null || true
  kill "$SINK_PID" >/dev/null 2>&1 || true
  wait "$SINK_PID" 2>/dev/null || true
}
trap cleanup EXIT

# --- Run maestro.
echo ">> running maestro: $FLOW_PATH"
set +e
if [[ "$PLATFORM" == iOS ]]; then
  maestro --device "$BOOTED" test \
    --format=HTML --output="$OUT_DIR/report.html" \
    --debug-output="$DEBUG_DIR" --flatten-debug-output \
    -e "APP_ID=$APP_ID" \
    "$FLOW_PATH" | tee "$OUT_DIR/run.log"
else
  maestro test \
    --format=HTML --output="$OUT_DIR/report.html" \
    --debug-output="$DEBUG_DIR" --flatten-debug-output \
    -e "APP_ID=$APP_ID" \
    "$FLOW_PATH" | tee "$OUT_DIR/run.log"
fi
EXIT=$?
set -e

# --- Stop capture, assemble device.mp4.
if [[ "$PLATFORM" == Android ]]; then
  adb shell pkill -2 screenrecord >/dev/null 2>&1 || true
  sleep 2
  adb pull /sdcard/maestro-run.mp4 "$OUT_DIR/device.mp4" >/dev/null \
    || echo "warn: failed to pull recording"
else
  kill "$REC_PID" >/dev/null 2>&1 || true
  wait "$REC_PID" 2>/dev/null || true
  FRAME_COUNT=$(ls "$FRAMES_DIR" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$FRAME_COUNT" -gt 0 ]]; then
    ffmpeg -y -framerate 5 -i "$FRAMES_DIR/f_%06d.png" \
      -vf "scale=-2:1280:flags=lanczos,format=yuv420p" \
      -c:v libx264 -preset veryfast -crf 22 "$OUT_DIR/device.mp4" \
      >/dev/null 2>&1 || echo "warn: frame assembly failed"
  fi
  [[ -f "$OUT_DIR/device.mp4" ]] && rm -rf "$FRAMES_DIR"
fi

kill "$SINK_PID" >/dev/null 2>&1 || true
wait "$SINK_PID" 2>/dev/null || true

# --- Render outputs.
python3 "$HARNESS_DIR/scripts/render_report.py" \
  "$DEBUG_DIR" "$OUT_DIR/tickmarks.html" \
  --screens-dir artifacts \
  --video "$OUT_DIR/device.mp4" \
  --sink "$SINK_LOG" \
  --title "$FLOW_NAME"

if [[ -f "$OUT_DIR/device.mp4" ]]; then
  python3 "$HARNESS_DIR/scripts/render_video.py" \
    --commands "$DEBUG_DIR"/commands-*.json \
    --device "$OUT_DIR/device.mp4" \
    --rec-started-ms "$REC_STARTED_AT_MS" \
    --sink "$SINK_LOG" \
    --out "$OUT_DIR/annotated.mp4" \
    || echo "warn: annotated video render failed"
fi

echo ">> done: $OUT_DIR/tickmarks.html (exit=$EXIT)"
open "$OUT_DIR/tickmarks.html" 2>/dev/null || true
open "$OUT_DIR/annotated.mp4" 2>/dev/null || true
exit "$EXIT"
