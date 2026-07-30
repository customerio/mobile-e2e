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
INBOX_TRANSACTIONAL_MESSAGE_ID=<id> ./e2e run --platform android --suite message-inbox
INBOX_TRANSACTIONAL_MESSAGE_ID=<id> ./e2e run --platform ios --suite message-inbox
./e2e run --platform ios --suite live-activities
```

The runner discovers the local SDK repos by default. Use `--sdk-repo PATH` for a
different checkout and `--skip-build` while iterating. Normal iOS runs restart a
reused Simulator to keep XCUITest input deterministic; `--keep-device` preserves
the current visual state for faster debugging. Use `--headless` in automation.
Every run provisions or boots a compatible virtual device when none is
available; no separately managed simulator is required.

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

The iOS Live Activities suite has two lanes:

```bash
# Local Segments, Delivery, and Countdown ActivityKit lifecycles with Lock
# Screen/deep-link evidence plus the correlated Segments backend conversation.
./e2e run --platform ios --suite live-activities

# The same checks plus App API → services → APNs sandbox → Simulator
# push-to-start, update, and end.
./e2e run --platform ios --suite live-activities-remote
```

The remote lane additionally requires Live Notifications on the workspace,
valid APNs sandbox credentials for the APN-UIKit bundle, and a Mac with Apple
silicon or a T2 chip running macOS 13 or later. Set
`LIVE_ACTIVITY_APP_IDENTIFIER` only when that exact identifier is configured
as an app in the workspace; an installed bundle identifier alone is not
enough, and an invalid value is rejected before delivery. The Customer.io CDP
destination must have both dedicated `Live Notification Event` and
`Live Notification Token` actions enabled. For iOS 18+, the services start
payload must also carry `input-push-token: 1` so ActivityKit issues the
per-instance token used by update and end.
`MAESTRO_EXT_API_KEY` is an App API bearer token and is used for both customer
and Live Notifications endpoints; `MAESTRO_APP_API_KEY` remains available as
an optional override. Both variables are redacted from generated artifacts
before reports or CI uploads. The optional app identifier is redacted too when
it is supplied as a protected CI value.

Remote-lane failures are deliberately diagnostic:

- `push_to_start_registration_missing_or_ineligible` means the backend could
  not select a device for the SDK-reported notification type. Check the
  dedicated token action, the identified device, and app scoping.
- `instance_token_missing_or_delivery_undeliverable` after a rendered start
  means update/end could not target the activity. Check `input-push-token` on
  the start payload and the SDK's instance-token registration action.
- `app_identifier does not match any app` means the optional identifier is not
  registered in that workspace; omit it or use the workspace's configured app.

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
  message_inbox.yaml           # App API → Gist queue → native SDK data API and
                               # Customer.io visual overlay → backend state.
  live_activities.yaml         # iOS local ActivityKit lifecycle plus optional
                               # real backend/APNs start, update, and end.
scripts/
  setup_run.js                 # Generates a unique run_id + email and POSTs to the
                               # sink so the HTML report shows per-run identity.
  sink.py                      # Tiny HTTP server that appends JSON POSTs to a .jsonl
  redact_artifacts.py          # Removes exact Ext/App API keys from Maestro debug
                               # JSON and blocks CI upload if verification fails.
  assert_message_delivered.js  # Maestro runScript helper: polls Customer.io Ext API
                               # for a message of a given type/metric/campaign and
                               # POSTs the match (or miss) to the sink.
  assert_inbox_queue_state.js  # Polls the Gist queue for this run's exact inbox
                               # message, verifies read/unread/deleted state, and
                               # reports whether it is eligible for the visual overlay.
  send_inbox_message.js        # Sends a transactional Inbox template to the
                               # SDK-identified synthetic profile.
  assert_customer_activity.js  # Polls Ext API activities for an exact event/property
                               # or first-class geofence activity after a timestamp.
  capture_live_activity_id.js  # Extracts the SDK-minted id from the app's
                               # ActivityKit probe using Maestro copied text.
  assert_live_notification_status.js
                               # Polls the correlated Live Notifications status
                               # and checks state, operation, source, and delivery.
  live_notification_request.js # Calls start/update/end and polls delivery status.
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
| `inbox_messages_button`, `mark_read_button`, `mark_unread_button`, `track_click_button`, `delete_button` | Open the raw inbox and drive message state/actions |
| `live_activities_button`, `live_activity_segments_toggle`, `live_activity_segments_update`, `live_activity_system_status`, `live_activity_end_all` | Drive, observe, and reset ActivityKit state |

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
- `.maestro/.env` — per-dev `MAESTRO_EXT_API_KEY`; optionally set
  `MAESTRO_APP_API_KEY` when Live Notifications uses a different credential.
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
- Published transactional Inbox template with non-empty `properties.title` and
  `properties.body`; pass its ID as `INBOX_TRANSACTIONAL_MESSAGE_ID`
- Live Notifications entitlement and APNs sandbox setup for the remote lane

`./e2e doctor --platform <platform>` reports missing prerequisites before any
build starts. A missing Pillow installation is a warning: Maestro, JUnit/HTML,
screenshots, raw video, device logs, and backend sink evidence still work.

The Message Inbox suite covers both surfaces. Its first delivery exercises the
SDK's build-your-own/data API (render, read, unread, click, and delete). After
that delivery is deleted, a second delivery opens the drop-in visual overlay,
asserts the server-provided title/body and the fixture CTA, proves the opened
metric, taps the real Jist dismiss action, and proves queue removal. The template
must contain a `cio_inbox*` topic and `type` equal to `basic`, `image`, or `cta`;
the pre-render queue assertion fails explicitly when the fixture is incompatible.

## CI

Both native SDK repos contain a `Maestro SDK E2E` workflow. It runs smoke
on weekdays and offers `message-inbox` as a manual dispatch. iOS additionally
offers manual `live-activities` and `live-activities-remote` dispatches. Each job
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
- `MOBILE_E2E_INBOX_TRANSACTIONAL_MESSAGE_ID` repository variable containing a
  published Inbox template ID for the manual `message-inbox` suite.
- `MOBILE_E2E_REPO_TOKEN` only when the workflow's default token cannot read the
  shared `customerio/mobile-e2e` repository.

`MOBILE_E2E_APP_API_KEY` is an optional override for the remote lane; otherwise
the workflow reuses `MOBILE_E2E_EXT_API_KEY`.

## Geofence workspace behavior

The Android test workspace is deterministically seeded with City Hall Park
fence `83`, so Android verifies the exact `geofence_id`. The iOS sample currently
uses a different workspace with overlapping fences, so its default contract is
“at least one first-class `geofence` activity after the simulated crossing.”
Set `GEOFENCE_ID=<id>` to make iOS enforce a specific seeded fence as well.

The local Live Activities lane drives the registered Segments, Delivery, and
Countdown examples through start, in-place update, Lock Screen rendering,
widget-URL re-entry, and final system state. It also correlates the Segments
SDK-minted instance with device-sourced Customer.io start/end deliveries. The
opt-in remote lane additionally proves real APNs sandbox delivery by matching a
unique run id in ActivityKit after each App API operation; a backend `sent`
status alone is not treated as device receipt.
