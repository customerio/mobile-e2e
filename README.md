# mobile-e2e

Shared E2E harness for Customer.io mobile SDK sample apps — Maestro flows,
backend-assertion sinks, and annotated video/report renderers for iOS and Android.

`mobile-e2e` is the shared test infrastructure used by the Customer.io mobile SDK
sample apps (Android, iOS, and eventually Flutter) to validate the full
SDK → backend → client loop. It provides a Python HTTP sink that captures real
Customer.io Ext API responses during a Maestro run, a GraalJS helper for
asserting on message delivery state (`sent` / `delivered` / `opened`), and
renderers that produce a per-step tick-mark HTML report and a side-by-side
annotated MP4 showing the device screen alongside the live step list and live
backend responses. Each sample repo consumes this harness as a git submodule at
`.maestro/harness/`; platform-specific flow YAMLs and device wiring stay in
the sample repos themselves.

## Layout

```
scripts/
  sink.py                      # Tiny HTTP server that appends JSON POSTs to a .jsonl
  assert_message_delivered.js  # Maestro runScript helper: polls Customer.io Ext API
                               # for a message of a given type/metric/campaign and
                               # POSTs the match (or miss) to the sink.
  render_report.py             # Reads Maestro debug-output + sink.jsonl → tickmarks.html
                               # (per-step pass/fail, inline screenshots, real Ext API
                               # responses surfaced per assertion).
  render_video.py              # Reads same inputs + device.mp4 → annotated.mp4:
                               # device screen on the left, live step panel on the
                               # right, backend-response card pops when assertions land.
```

## Consuming this harness from a sample repo

1. Add as a submodule:

   ```bash
   git submodule add git@github.com:customerio/mobile-e2e.git .maestro/harness
   ```

2. In flow YAMLs, reference the shared scripts via the submodule path:

   ```yaml
   - runScript:
       file: harness/scripts/assert_message_delivered.js
       env:
         MAESTRO_EXT_API_KEY: ${MAESTRO_EXT_API_KEY}
         RUN_EMAIL: ${output.email}
         EXPECTED_TYPE: "in_app"
         MIN_METRIC: "sent"
         CAMPAIGN_ID: "141"
         MAX_WAIT_MS: "45000"
   ```

3. Each sample repo provides its own `.maestro/run.sh` that wires up the
   platform-specific capture path (adb for Android, simctl for iOS) and
   invokes `harness/scripts/sink.py` + `render_report.py` + `render_video.py`.

## What's NOT shared (lives in the sample repos)

- The flow YAMLs themselves (selectors are platform-specific)
- `run.sh` (adb screenrecord vs. simctl screenshot loop)
- `setup_run.js` (unique-email prefix differs per platform)
- `.env` with `MAESTRO_EXT_API_KEY`
- `capture_frames.sh` (iOS-only; polls `simctl screenshot` since `recordVideo`
  conflicts with Maestro's active session)

## Requirements

- Python 3 with Pillow (`pip3 install pillow`)
- `ffmpeg` on PATH (video assembly + annotated composite)
- `maestro` CLI
- Bearer token for Customer.io Ext API in `MAESTRO_EXT_API_KEY`
