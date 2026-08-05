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

## Team quick start

From this repository:

```bash
# One-time local validation.
cp .env.e2e.example .env.e2e.local
# Fill the test-workspace values, then:
./e2e setup

# The default: every deterministic suite on Android and iOS.
./e2e test
```

Nothing else needs to be running. The profile runner validates the environment,
boots/reuses virtual devices, builds each SDK sample once, reinstalls it with
fresh storage for each suite, runs every flow sequentially, and writes a combined
summary without hiding later results when an earlier suite fails.

| Profile | Android | iOS | Use |
|---|---|---|---|
| `quick` | smoke | smoke | Fast local/PR confidence |
| `standard` (default; `all` alias) | smoke, geofence, message Inbox | smoke, geofence, message Inbox, local Live Activities | Local full run and weekday CI |
| `remote` | none until Android remote delivery is deterministic | backend/APNs Live Activities | Explicit manual integration lane |

Useful focused commands:

```bash
./e2e test --profile quick
./e2e test --platform android
./e2e test --platform ios
./e2e test --platform ios --suite message-inbox
./e2e test --profile remote --platform ios
```

From a native SDK checkout, the equivalent shortcuts are:

```bash
make e2e          # standard profile for this SDK
make e2e-setup    # one-time preflight
make e2e-quick
make e2e-inbox
```

The original single-flow interface remains the debugging escape hatch:

```bash
./e2e run --platform android --suite geofence
./e2e run --platform ios --suite live-activities --keep-device
```

Cross-platform harness runs read `ANDROID_SDK_REPO` and `IOS_SDK_REPO` from the
shared configuration. The native-repo shortcuts supply their own checkout
automatically. You can also use profile-level `--android-sdk-repo` /
`--ios-sdk-repo` flags, or single-flow `--sdk-repo`. Every run provisions or
boots a compatible virtual device when none is available; no separately managed
simulator is required.

Credentials remain outside git. The preferred cross-platform configuration is
the harness's gitignored `.env.e2e.local`:

```bash
MAESTRO_APP_API_KEY=...
INBOX_TRANSACTIONAL_MESSAGE_ID=21
ANDROID_CDP_API_KEY=...
ANDROID_SITE_ID=...
IOS_CDP_API_KEY=...
IOS_SITE_ID=...
E2E_WORKSPACE_NAME=Mobile E2E
ANDROID_SDK_REPO=/absolute/path/to/customerio-android
IOS_SDK_REPO=/absolute/path/to/customerio-ios
```

When the platform CDP/site pair is provided, the runner writes the SDK sample's
gitignored configuration before preflight/build. Existing per-sample
`.maestro/.env` files remain supported for native-repo-only usage:

```bash
MAESTRO_APP_API_KEY=...
INBOX_TRANSACTIONAL_MESSAGE_ID=21
```

The App API key must be able to read customers, messages, and activities in the same
workspace used by that sample's CDP key. The flows rely on Maestro's documented
automatic import of `MAESTRO_`-prefixed shell variables, so the token is never
copied into a `runScript.env` block. Because Maestro still serializes imported
variables in its raw command JSON, the runner redacts the exact key before
rendering, and a separate always-run CI sanitizer gates artifact upload.

The iOS Live Activities suite has two lanes:

```bash
# Deterministic Segments, Delivery, and Countdown ActivityKit lifecycles with
# Lock Screen/deep-link evidence. No Apple device token is required.
./e2e run --platform ios --suite live-activities

# The same checks plus device-sourced backend lifecycle records and App API →
# services → APNs sandbox → Simulator push-to-start, update, and end.
./e2e run --platform ios --suite live-activities-remote
```

The remote lane additionally requires Live Notifications on the workspace, a
real Simulator APNs device token, valid APNs sandbox credentials for the
APN-UIKit bundle, and a Mac with Apple silicon or a T2 chip running macOS 13 or
later. Set
`LIVE_ACTIVITY_APP_IDENTIFIER` only when that exact identifier is configured
as an app in the workspace; an installed bundle identifier alone is not
enough, and an invalid value is rejected before delivery. The Customer.io CDP
destination must have both dedicated `Live Notification Event` and
`Live Notification Token` actions enabled. For iOS 18+, the services start
payload must also carry `input-push-token: 1` so ActivityKit issues the
per-instance token used by update and end.
`MAESTRO_APP_API_KEY` authenticates both the customer/message/activity Ext API
and Live Notifications operations. Existing gitignored local `.env` files that
still use `MAESTRO_EXT_API_KEY` remain compatible, but new configuration and CI
use the canonical App API key name. API keys, workspace site IDs, and the optional app
identifier are redacted from generated artifacts before reports or CI uploads
whenever they are supplied as protected values.

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
  smoke_login_event.yaml       # Smoke: identify → optional welcome modal →
                               # exact run-correlated custom event persisted.
  geofence_basic.yaml          # Always permission → outside location → registered
                               # fences → inside location → backend geofence activity.
  inline_messages.yaml         # Template for inline in-app validation (needs a
                               # seeded workspace campaign to fully assert).
  message_inbox.yaml           # App API → Gist queue → native SDK data API and
                               # full-screen/overlay visual Inbox → backend state.
  live_activities.yaml         # iOS local ActivityKit lifecycle plus optional
                               # real backend/APNs start, update, and end.
scripts/
  setup_run.js                 # Generates a unique run_id + email and POSTs to the
                               # sink so the HTML report shows per-run identity.
  sink.py                      # Tiny HTTP server that appends JSON POSTs to a .jsonl
  redact_artifacts.py          # Removes exact protected keys and identifiers from
                               # Maestro debug JSON and blocks CI upload if verification fails.
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

Run the harness regression checks without a simulator or emulator:

```bash
bash tests/run.sh
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
- `.maestro/.env` — per-dev `MAESTRO_APP_API_KEY` (gitignored).
- `.maestro/scripts/capture_frames.sh` — iOS-only; polls `simctl screenshot`
  at 5fps because `simctl recordVideo` collides with Maestro's active session.
- Any sample-app-specific screen navigation that hasn't been unified yet.

## Requirements

- Android SDK/emulator for Android; full Xcode with an iOS runtime for iOS
- Java 17 and the SDK repo's normal build prerequisites
- Python 3; Pillow is optional but required for annotated MP4 rendering
- `ffmpeg` on PATH (video assembly + annotated composite)
- `maestro` CLI
- Customer.io App API key in `MAESTRO_APP_API_KEY`; the same credential is used
  for Ext API assertions, Inbox sends, and remote Live Notifications operations
- Published transactional Inbox template with non-empty `properties.title` and
  `properties.body`; the shared fixture currently uses
  `INBOX_TRANSACTIONAL_MESSAGE_ID=21`
- Live Notifications entitlement and APNs sandbox setup for the remote lane

`./e2e doctor --platform <platform>` reports missing prerequisites before any
build starts. A missing Pillow installation is a warning: Maestro, JUnit/HTML,
screenshots, raw video, device logs, and backend sink evidence still work.

The Message Inbox suite covers both surfaces. Its first delivery exercises the
SDK's build-your-own/data API (render, read, unread, click, and delete). After
that delivery is deleted, a second delivery first renders in a dedicated
full-screen `NotificationInboxView` and then renders again through the optional
bell/bottom-sheet overlay. Both presentations assert the same server-provided
title/body and fixture CTA. The flow also proves the opened metric, taps the real
Jist dismiss action, and proves queue removal. The template must contain a
`cio_inbox*` topic and `type` equal to `basic`, `image`, or `cta`; the pre-render
queue assertion fails explicitly when the fixture is incompatible.

## CI

Both native SDK repos contain a `Maestro SDK E2E` workflow using the same
single-flow runner as local profiles:

- Same-repository pull requests run the `quick` profile.
- Weekday schedules run the `standard` profile as a parallel suite matrix.
- Manual dispatch supports `quick`, `standard`, or one focused suite.
- iOS additionally exposes the explicit `remote` APNs profile.

PR and scheduled jobs remain disabled until the repository variable
`MOBILE_E2E_ENABLED=true` is set after the harness is published and the required
credentials have been provisioned. Manual dispatch remains available for the
initial CI proving runs.

Fork and Dependabot PRs do not receive workspace secrets and therefore do not
run the backend job. Each matrix job provisions its own virtual device, builds
the SDK sample from source, and uploads `artifacts/e2e/` even on failure. The
workflow result is the aggregate gate; individual jobs retain isolated evidence.

The legacy `campaign` and `inline` suites remain available locally for
workspaces/devices that meet their prerequisites; they are not offered as CI
choices because the current virtual-device lane cannot prove real push delivery
and the inline campaign is not deterministically seeded yet.

Required repository secrets:

- Existing sample CDP/site secrets (`CUSTOMERIO_JAVA_WORKSPACE_*` on Android,
  `CUSTOMERIO_APN_WORKSPACE_*` on iOS).
- `MOBILE_E2E_APP_API_KEY` for Ext API assertions, transactional Inbox sends,
  and remote Live Notifications operations.
- `MOBILE_E2E_INBOX_TRANSACTIONAL_MESSAGE_ID` repository variable containing a
  published Inbox template ID for the standard and focused Inbox suites.

Publish and merge `customerio/mobile-e2e` before enabling either native
workflow. After that initial rollout, pin native workflow checkouts to a reviewed
harness tag or commit when reproducibility is more important than immediately
consuming harness fixes.

Profile runs archive immutable evidence beneath
`mobile-e2e/artifacts/e2e/profile-<timestamp>/<platform>/<flow>/`; the summary
links to those snapshots. Focused low-level runs continue to use the selected SDK
repo's replaceable `artifacts/e2e/<platform>/<flow>/` debugging path.

## Geofence workspace behavior

The Android test workspace is deterministically seeded with City Hall Park
fence `83`. The iOS workspace is seeded with fence `3488`, which is fetched after
the simulated move to the inside coordinate. Both defaults verify the exact
`geofence_id`; set `GEOFENCE_ID=<id>` to target a different workspace fixture.

The local Live Activities lane drives the registered Segments, Delivery, and
Countdown examples through start, in-place update, Lock Screen rendering,
widget-URL re-entry, and final system state without depending on Apple issuing a
device token to a clean CI Simulator. The opt-in remote lane requires that token,
correlates the SDK-minted instance with device-sourced Customer.io start/end
deliveries, and proves real APNs sandbox delivery by matching a unique run id in
ActivityKit after each App API operation; a backend `sent` status alone is not
treated as device receipt.
