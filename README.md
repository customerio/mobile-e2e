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
flows/
  campaign_141.yaml            # Shared cross-platform Maestro flow for Campaign 141
                               # ("Maestro E2E"). Drives both iOS (APN-UIKit) and
                               # Android (kotlin_compose) unchanged — same selectors
                               # resolve on both platforms via unified accessibility
                               # IDs (iOS `accessibilityIdentifier`, Android
                               # `Modifier.testTag(...)` + `testTagsAsResourceId`).
scripts/
  setup_run.js                 # Generates a unique run_id + email and POSTs to the
                               # sink so the HTML report shows per-run identity.
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

## Selector contract (the thing that makes shared flows possible)

Sample apps must expose the same accessibility identifiers on every widget the
shared flows drive. Current identifier set:

| ID                     | iOS widget                        | Android widget (Compose) |
|------------------------|-----------------------------------|--------------------------|
| `Login Button`         | `accessibilityIdentifier`         | `testTag` |
| `First Name Input`     | `accessibilityIdentifier`         | `testTag` |
| `Email Input`          | `accessibilityIdentifier`         | `testTag` |
| `Custom Event Button`  | `accessibilityIdentifier`         | `testTag` |
| `Event Name Input`     | `accessibilityIdentifier`         | `testTag` |
| `Property Name Input`  | `accessibilityIdentifier`         | `testTag` |
| `Property Value Input` | `accessibilityIdentifier`         | `testTag` |
| `Send Event Button`    | `accessibilityIdentifier`         | `testTag` |

Android additionally requires `Modifier.semantics { testTagsAsResourceId = true }`
on the root nav graph so `testTag` values surface as `resource-id` to Maestro.
Without that, `{ id: "..." }` selectors silently miss.

## Consuming this harness from a sample repo

Each sample repo's `.maestro/run.sh` clones this repo into `.maestro/harness/`
(gitignored) on first run and `git pull`s it on subsequent runs. Then Maestro
is pointed at the shared flow:

```bash
maestro test .maestro/harness/flows/campaign_141.yaml
```

The flow's `runScript: file: ../scripts/...` references resolve to
`harness/scripts/` naturally.

## What stays in each sample repo

- `.maestro/run.sh` — the platform-specific capture + renderer orchestration
  (adb screenrecord for Android, simctl screenshot loop for iOS).
- `.maestro/.env` — per-dev `MAESTRO_EXT_API_KEY`.
- `.maestro/scripts/capture_frames.sh` — iOS-only; polls `simctl screenshot`
  at 5fps because `simctl recordVideo` collides with Maestro's active session.
- Any sample-app-specific screen navigation that hasn't been unified yet.

## Requirements

- Python 3 with Pillow (`pip3 install pillow`)
- `ffmpeg` on PATH (video assembly + annotated composite)
- `maestro` CLI
- Bearer token for Customer.io Ext API in `MAESTRO_EXT_API_KEY`
