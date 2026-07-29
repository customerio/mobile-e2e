# mobile-e2e

Shared E2E harness for Customer.io mobile SDK sample apps — Maestro flows,
backend-assertion sinks, and annotated video/report renderers for iOS and Android.

`mobile-e2e` is the shared test infrastructure used by the Customer.io mobile SDK
sample apps to validate the full SDK → backend → client loop. It provides a
one-command virtual-device runner, a Python HTTP sink that captures real
Customer.io Ext API responses during a Maestro run, a GraalJS helper for
asserting on message delivery state (`sent` / `delivered` / `opened`), and
renderers that produce a per-step tick-mark HTML report and a side-by-side
annotated MP4 showing the device screen alongside the live step list and live
backend responses. Each sample repo can consume this harness through a runtime
clone at `.maestro/harness/`; CI checks it out at `.e2e-harness`. Platform-
specific SDK builds and credentials stay in the sample repos themselves.

## One-command local runs

From this repository:

```bash
# Verify tools, sample configuration, and Ext API access without starting a device.
./e2e doctor --platform android
./e2e doctor --platform ios

# Create/boot an emulator or simulator, build and install the SDK sample,
# run Maestro, validate Customer.io backend state, and collect evidence.
./e2e run --platform android --suite smoke
./e2e run --platform ios --suite smoke
./e2e run --platform android --suite geofence
./e2e run --platform ios --suite geofence
```

The runner discovers the local SDK repos by default. Use `--sdk-repo PATH` in a
different checkout, `--skip-build` while iterating, `--keep-device` for visual
debugging, and `--headless` in automation. Every run provisions or boots a
compatible virtual device when none is available; no separately managed
simulator is required.

Credentials remain outside git. Configure each sample as usual and put an Ext
API bearer token in the sample's `.maestro/.env`:

```bash
MAESTRO_EXT_API_KEY=...
```

The token must be able to read customers, messages, and activities in the same
workspace used by that sample's CDP key. The flows rely on Maestro's documented
automatic import of `MAESTRO_`-prefixed shell variables, so the token is never
copied into a `runScript.env` block. Because Maestro still serializes imported
variables in its raw command JSON, the runner redacts the exact key before
rendering, and a separate always-run CI sanitizer gates artifact upload.

## Layout

```
flows/
  campaign_141.yaml            # Full E2E loop: SDK identify → backend → campaign
                               # 141 → in-app + inline + push, with visual proof
                               # of the push notification.
  smoke_login_event.yaml       # Smoke: identify → backend in_app sent → modal
                               # rendered + dismissed → exact custom event persisted.
  geofence_basic.yaml          # Always permission → outside location → registered
                               # fences → inside location → backend geofence activity.
  inline_messages.yaml         # Template for inline in-app validation (needs a
                               # seeded workspace campaign to fully assert).
scripts/
  setup_run.js                 # Generates a unique run_id + email and POSTs to the
                               # sink so the HTML report shows per-run identity.
  sink.py                      # Tiny HTTP server that appends JSON POSTs to a .jsonl
  redact_artifacts.py          # Removes the exact Ext API key from Maestro debug
                               # JSON and blocks CI upload if verification fails.
  assert_message_delivered.js  # Maestro runScript helper: polls Customer.io Ext API
                               # for a message of a given type/metric/campaign and
                               # POSTs the match (or miss) to the sink.
  assert_customer_activity.js  # Polls Ext API activities for an exact event/property
                               # or first-class geofence activity after a timestamp.
  mark_time.js                 # Marks the movement boundary so older activities do
                               # not create false positives.
  wait.js                      # Bounded wait for async SDK/backend transitions.
  render_report.py             # Reads Maestro debug-output + sink.jsonl → tickmarks.html
                               # (per-step pass/fail, inline screenshots, real Ext API
                               # responses surfaced per assertion).
  render_video.py              # Reads same inputs + device.mp4 → annotated.mp4:
                               # device screen on the left, live step panel on the
                               # right, backend-response card pops when assertions land.
  capture_frames.sh            # iOS-only fallback: `simctl recordVideo` collides with
                               # Maestro's active session, so run.sh on iOS polls
                               # `simctl io screenshot` at 5fps via this script and
                               # ffmpeg-assembles the frames into device.mp4.
VALIDATION_MATRIX.md           # Reference for what's validatable via Maestro today,
                               # how each check is implemented, and what workspace
                               # configuration each row depends on.
```

All flows are parameterized with `appId: ${APP_ID}` — each sample repo's
`run.sh` passes its own bundle id via `maestro test -e APP_ID=...`.

## Selector contract (the thing that makes shared flows possible)

Sample apps must expose the same accessibility identifiers on every widget the
shared flows drive. Current identifier set:

| ID | Purpose |
|---|---|
| `login_button`, `first_name_input`, `email_input` | Identify a fresh test customer |
| `custom_event_button`, `event_name_input`, `property_name_input`, `property_value_input`, `send_event_button` | Send a uniquely traceable event |
| `location_test_button`, `request_sdk_location_once` | Drive the SDK location/geofence path |

iOS exposes these through `accessibilityIdentifier`; the Android Java sample
exposes the same names as resource IDs/content descriptions.

## Consuming this harness from a sample repo

Each sample repo's `.maestro/run.sh` clones this repo into `.maestro/harness/`
(gitignored) on first run and `git pull`s it on subsequent runs. Then Maestro
is pointed at the shared flow:

```bash
maestro test .maestro/harness/flows/campaign_141.yaml
```

The flow's `runScript: file: ../scripts/...` references resolve to
`harness/scripts/` naturally.

For a full local run, prefer the top-level `./e2e` command because it also owns
device provisioning, SDK build/install, permissions, backend preflight, logs,
and artifact placement. The sample `.maestro/run.sh` remains useful when an app
is already installed on a booted device.

## What stays in each sample repo

- `.maestro/run.sh` — the platform-specific capture + renderer orchestration
  (adb screenrecord for Android, simctl screenshot loop for iOS).
- `.maestro/.env` — per-dev `MAESTRO_EXT_API_KEY`.
- `.maestro/scripts/capture_frames.sh` — iOS-only; polls `simctl screenshot`
  at 5fps because `simctl recordVideo` collides with Maestro's active session.
- Any sample-app-specific screen navigation that hasn't been unified yet.

## Requirements

- Android SDK/emulator for Android; full Xcode with an iOS runtime for iOS
- Java 17 and the SDK repo's normal build prerequisites
- Python 3; Pillow is optional but required for annotated MP4 rendering
- `ffmpeg` on PATH (video assembly + annotated composite)
- `maestro` CLI
- Bearer token for Customer.io Ext API in `MAESTRO_EXT_API_KEY`

`./e2e doctor --platform <platform>` reports missing prerequisites before any
build starts. A missing Pillow installation is a warning: Maestro, JUnit/HTML,
screenshots, raw video, device logs, and backend sink evidence still work.

## CI

Both native SDK repos now contain a `Maestro SDK E2E` workflow. It runs smoke
on weekdays and supports manual `smoke` and `geofence` dispatches. Each job
checks out this harness, provisions a virtual device,
builds the SDK sample from source, runs the same command used locally, and
uploads `artifacts/e2e/` even on failure.

The legacy `campaign` and `inline` suites remain available locally for
workspaces/devices that meet their prerequisites; they are not offered as CI
choices because the current virtual-device lane cannot prove real push delivery
and the inline campaign is not deterministically seeded yet.

Required repository secrets:

- Existing sample CDP/site secrets (`CUSTOMERIO_JAVA_WORKSPACE_*` on Android,
  `CUSTOMERIO_APN_WORKSPACE_*` on iOS).
- `MOBILE_E2E_EXT_API_KEY` for backend assertions.
- `MOBILE_E2E_REPO_TOKEN` only when the workflow's default token cannot read the
  shared `customerio/mobile-e2e` repository.

## Geofence workspace behavior

The Android test workspace is deterministically seeded with City Hall Park
fence `83`, so Android verifies the exact `geofence_id`. The iOS sample currently
uses a different workspace with overlapping fences, so its default contract is
“at least one first-class `geofence` activity after the simulated crossing.”
Set `GEOFENCE_ID=<id>` to make iOS enforce a specific seeded fence as well.

Live Notifications/Live Activities are intentionally not claimed as covered
yet: their SDK implementations still live on feature branches and the main
sample apps do not expose a stable start/update/end scenario. The harness is
ready to add that suite once those sample seams and a deterministic backend
trigger are merged; see `VALIDATION_MATRIX.md` for the proposed contract.
