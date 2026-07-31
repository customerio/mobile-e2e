# Validation matrix — what Maestro can verify for this SDK

A reference for what's validatable end-to-end, how to implement each check, and
what workspace configuration each check depends on. Mirror copy lives in the
iOS sample repo; both repos share identical patterns.

## Maestro primitives we rely on

| Primitive | What it gives us | Used for |
|---|---|---|
| `assertVisible: "<text>"` | regex match against the native accessibility tree | Native text/button presence |
| `assertVisible: { id: "<id>" }` | matches by accessibilityIdentifier / content-desc / resource-id | Stable targeting when the sample sets IDs |
| `assertNotVisible` | inverse | Dismissed modals, hidden inline slots |
| `extendedWaitUntil: visible:` | polls up to `timeout:` ms for a condition | Async UI renders (in-apps arriving from backend) |
| `takeScreenshot: <path>` | PNG dropped into the test run artifacts | Visual evidence a human can review |
| `runScript: scripts/x.js` with `env:` | Graal JS with `http.get/post` + `output.*` | Poll the Customer.io Ext API for backend state |
| `tapOn`, `inputText`, `swipe`, `back`, `hideKeyboard` | UI driving | Navigation + interaction |

**Not available (important to know):**
- No `setTimeout` / `Thread.sleep` / `await` in the script runtime. The harness
  uses a bounded `wait.js` busy wait between external transitions and polling
  loops with explicit maximum budgets for backend assertions.
- No way to speak MySQL or gRPC directly — only HTTP. We query the Customer.io Ext API (`https://api.customer.io/v1/...`).
- WebView-rendered content is sometimes invisible to the accessibility tree. In this sample, the in-app modal uses native text views, so it's fine. Rich HTML in-apps may not be.

## Regex gotcha (learned the hard way)

`assertVisible: "Some text"` is a regex against the full text node. It's **not**
a substring search. If the tree contains `"Thank you for choosing our product. Have a look around..."`
then `assertVisible: "Thank you for choosing"` **fails** — the regex has to
match the full text. Use `".*Thank you for choosing.*"` instead.

## The matrix

### ✅ Currently covered

| Case | How |
|---|---|
| SDK identify reached the server | the smoke flow resolves the exact run-correlated event by the fresh identified email; a welcome in-app is visual evidence only when that workspace is configured to send one |
| In-app modal rendered when this installation is eligible | conditional `assertVisible: ".*Thank you for choosing.*"` + `takeScreenshot`; dedicated campaign tests own campaign dispatch assertions |
| Modal dismissed correctly | conditional `tapOn: "Continue"` + `assertNotVisible` |
| Exact custom event persisted | send `maestro_test_event` with a unique `run_id`, then poll `/v1/customers/:cio_id/activities` for both exact values after the run start |
| SDK one-shot location reached backend | move the virtual device outside, tap `Request location once (SDK)`, then poll for `event=CIO Location Update` with both exact latitude and longitude |
| Android geofence transition reached backend | grant foreground/background permission, register fences, move inside City Hall Park, then assert `type=geofence` and `geofence_id=83` after movement |
| iOS geofence transition reached backend | grant Always permission, register monitored conditions, move the simulator, then assert a first-class `type=geofence` activity after movement; set `GEOFENCE_ID` for exact workspace seeding |
| Android geofence foreground recovery | background/foreground the sample after initial registration and validate the production foreground-retry path before movement |
| Inbox delivery reaches the SDK queue | Identify a fresh profile through the SDK, send a published transactional Inbox template through the App API, require the exact returned delivery ID in Ext API history with `type=inbox` and `metrics.sent`, then match that delivery in the Gist queue with `opened=false` |
| Inbox SDK list and opened metric | Fetch the exact delivery through the public SDK inbox API, assert its title/body in the native sample UI, mark it read, then require both Gist `opened=true` and the exact Ext API `opened` metric |
| Inbox read/unread state | Drive the public SDK read controls and poll the Gist queue after each mutation for `opened=true`, `opened=false`, then `opened=true` |
| Inbox click and delete | Call the public click API and require the Ext API `clicked` metric; delete through the SDK and require three consecutive Gist polls with the run marker absent plus the native empty state |
| Inbox visual rendering and CTA | Send a second isolated delivery, require a visual-compatible server payload, render it first in a dedicated full-screen SDK Inbox and then through the optional bell/sheet overlay, match the same queue title/body and published CTA in both Jist presentations, require the exact delivery's opened metric, tap its dismiss action, then require stable queue absence |
| iOS local Live Activity visual lifecycle | Drive the registered Segments, Delivery, and Countdown examples through start/update/end; require one stable ActivityKit and Customer.io instance per template; assert active/final Lock Screen content; tap the card and verify widget-URL re-entry to the Live Activities screen; save each state as evidence |

### 🧪 Opt-in integration coverage

| Case | How | Prerequisites |
|---|---|---|
| iOS local Live Activity lifecycle reached backend | Copy the SDK-minted `cioInstanceId` from ActivityKit, poll `/v1/live_notifications/:id`, require device-sourced start/end on that same conversation, and hold the backend at its original start delivery for 8 seconds after a local-only update | A real Simulator APNs device token; enabled automatically by the `live-activities-remote` suite, or explicitly with `MAESTRO_LIVE_ACTIVITY_DEVICE_BACKEND_ENABLED=true` |
| iOS backend push-to-start | Call `/v1/live_notifications/start`, poll status to `sent`, then match the unique run id in ActivityKit; successful delivery proves the SDK's consumed push-to-start registration reached Customer.io | Live Notifications plan, App API key, configured APNs sandbox key, supported Simulator host, and the dedicated `Live Notification Token` CDP action |
| iOS backend update/end | Reuse the returned `instance_id`, call update/end, require each operation's status to become `sent`, then match updated/final content and state in ActivityKit | Same as above; services must put `input-push-token: 1` on the iOS start payload and the resulting SDK instance-token registration must complete |
| Remote Live Activity system surface | Background the app after remote updates and capture the Simulator system presentation | Dynamic Island-capable Simulator model |

### 🛠 Coverable with small additions (patterns exist, need either seeded campaigns or small sample-app work)

| Case | How (pattern) | What's needed |
|---|---|---|
| **Inline in-app renders in the correct slot** | Fire a trigger event for a campaign configured to show inline on elementId `X` → navigate to Inline Examples screen → `assertVisible` on the inline body text within the slot | A seeded event-triggered campaign in the workspace whose in-app targets an elementId the sample has (`sticky-header`, `inline`, `below-fold`, or the Compose/Tabs variants) |
| **Page rule: in-app shows only on screen Y** | Navigate to screen Y → `assertVisible` on in-app body. Navigate to screen Z → `assertNotVisible`. | A campaign with a page-rule filter keyed to a screen name the sample actually emits via `CustomerIO.screen("Y")` |
| **Frequency capping: same in-app doesn't show twice** | Trigger once, dismiss, assert visible. Trigger again, `extendedWaitUntil timeout` short, `assertNotVisible`. | A campaign with frequency cap configured |
| **Action button on in-app fires tracking event + deep-link** | `tapOn` the action button inside the rendered in-app → `assertVisible` destination screen → `runScript` poll `/v1/messages/:id` for `metrics.clicked` or `metrics.action_taken` | Known campaign with a known action button label |
| **Push received tracked** | After campaign fires, `openNotifications` on Android or assert the iOS system surface, then poll for `metrics.delivered` | Real device, Android emulator with Google Play Services, or a supported iOS Simulator with valid APNs sandbox configuration |
| **Push tap → deep link** | After `openNotifications` + `tapOn`, assert the expected in-app screen is shown | Real device + a campaign with a push containing a deep link |
| **Profile attribute update visible on server** | tap `Set Profile Attribute` → fill name/value → `runScript` poll `/v1/customers/:cio_id/attributes` | Nothing extra — sample and Ext API both support this today |
| **Device token registered for customer** | after login, `runScript` on `/v1/customers/:cio_id` looking for `devices[]` entry | Real device OR an emulator with Google Play Services + FCM |
| **Logout clears identity** | `tapOn: "Logout"` → `assertVisible: "Login"` → `runScript` confirm no new events for the cio_id | Sample must render the Logout button (Android does; iOS's current dashboard hides it) |
| **Re-identify same email stitches history** | Log in with pre-existing email → `runScript` assert same cio_id returned from lookup → no duplicate customer | Nothing extra |

### ⚠️ Needs investment (real-device bench or sample-app work)

| Case | What's needed |
|---|---|
| Android Live Notification start/update/end | Merge/adapt the Android feature, expose stable callback/render selectors, and test its FCM-specific payload contract independently |
| Live Notification background/cold-start recovery | Add explicit process termination/relaunch scenarios and assert token-registration races, callback payload preservation, tap intent/deep link, and restart recovery |
| Flutter full flow | Add `Semantics(identifier: ...)` wrappers to ~15 widgets in the Flutter sample |
| WebView-based in-app content assertion | Maestro can read WebView text on Android if JS-accessible. On iOS, usually not. Fall back to screenshots. |
| Rich push payloads (images, action buttons) on iOS | Real device + `xcrun simctl push` with rich JSON |

## How to add a new visual in-app assertion

Template:

```yaml
# 1) Put the user in a known identified state
- runScript: { file: scripts/setup_run.js }
- launchApp: { clearState: true }
- tapOn: { id: "Email Input" }
- inputText: ${output.email}
- tapOn: "Login"

# 2) Wait for backend to dispatch + SDK to render the in-app you care about
- extendedWaitUntil:
    visible: "<unique body copy from the campaign's in-app>"
    timeout: 25000

# 3) Visual evidence + richer asserts
- takeScreenshot: artifacts/<scenario-name>
- assertVisible: ".*<other body substring>.*"
- assertVisible: "<cta button text>"

# 4) Optionally also assert server-side state
- runScript:
    file: scripts/assert_message_delivered.js
    env:
      RUN_EMAIL: ${output.email}
      EXPECTED_TYPE: "in_app"
      MIN_METRIC: "human_opened"  # proves the render happened, not just dispatch
      MAX_WAIT_MS: "15000"
- assertTrue: ${output.assert_ok === "true"}

# 5) Interact with the in-app (dismiss or action)
- tapOn: "<cta or dismiss>"
- assertNotVisible: "<body copy>"
```

## How to add a page-rule test

```yaml
# Fire the trigger
- tapOn: "Send Custom Event"
- tapOn: { id: "Event Name Input" }
- inputText: "<campaign_trigger_event>"
- tapOn: "Send Event"

# Navigate to screen A — in-app SHOULD render here
- back                             # back to dashboard
- tapOn: "<screen A entry point>"
- extendedWaitUntil:
    visible: "<in-app body>"
    timeout: 15000
- takeScreenshot: artifacts/pagerule_screenA_shows

# Navigate to screen B — same in-app should NOT render
- back
- tapOn: "<screen B entry point>"
- waitForAnimationToEnd: { timeout: 3000 }
- assertNotVisible: "<in-app body>"
- takeScreenshot: artifacts/pagerule_screenB_hidden
```

## Workspace prerequisites (what to seed for best coverage)

If we later land dedicated test campaigns in the test-prod workspace:

- `maestro_modal_triggered` — event-triggered by event `maestro_modal` → shows a modal in-app with body `"MAESTRO MODAL OK"` (or any deterministic string).
- `maestro_inline_dashboard` — event-triggered by `maestro_inline`, page rule: only Dashboard screen, inline targeting `elementId = "inline"`, body `"MAESTRO INLINE DASHBOARD"`.
- `maestro_inline_inbox_only` — same but page rule = Inbox screen, body `"MAESTRO INLINE INBOX"`.
- `maestro_push_generic` — event-triggered by `maestro_push`, push with title+body that includes `{{event.properties.run_id}}` so each test run has a uniquely traceable push.
- `maestro_visual_inbox_e2e` — active transactional Inbox template with a
  `cio_inbox*` topic, `cta` type, title `MAESTRO VISUAL INBOX`, body
  `Rendered by Customer.io for Maestro E2E.`, and dismiss CTA `Verify E2E`.
  Set message ID `21` through `INBOX_TRANSACTIONAL_MESSAGE_ID`. The harness
  sends only to the fresh synthetic profile identified by that run.

With these seeded, every row in the "Coverable with small additions" section above becomes a working flow.

## One-command execution and artifacts

```bash
# Full deterministic local profile. Provisions devices and builds each platform once.
./e2e test

# Fast/focused profiles.
./e2e test --profile quick
./e2e test --platform android
./e2e test --platform ios --suite message-inbox
./e2e test --profile remote --platform ios

# Single-flow debugging remains available.
./e2e run --platform android --suite smoke
./e2e run --platform ios --suite smoke
./e2e run --platform android --suite geofence
./e2e run --platform ios --suite geofence
INBOX_TRANSACTIONAL_MESSAGE_ID=<id> ./e2e run --platform android --suite message-inbox
INBOX_TRANSACTIONAL_MESSAGE_ID=<id> ./e2e run --platform ios --suite message-inbox
./e2e run --platform ios --suite live-activities
./e2e run --platform ios --suite live-activities-remote
```

The command provisions the emulator/simulator, builds and installs the sample,
prepares location permission where needed, runs Maestro, polls the backend, and
collects evidence under the selected SDK repo:

`artifacts/e2e/<platform>/<flow>/`

That directory contains the Maestro report/debug bundle, `sink.jsonl`, device
logs, screenshots, raw video, the self-contained `tickmarks.html`, and JUnit XML
in CI. The sink distinguishes UI success from backend success and includes the
matched message/activity IDs and payload fields.

## Raw Maestro artifacts

Every `maestro test` run drops in `~/.maestro/tests/<timestamp>/`:
- `commands-*.json` — full command-by-command status
- `maestro.log` — engine log
- `screenshot-❌-*.png` — on failure, the screen at the moment of fail
- `artifacts/<name>.png` — anything we explicitly capture via `takeScreenshot`

The harness copies the relevant evidence into its per-run artifact directory.
Running in CI selects JUnit output automatically; local runs use the detailed
HTML format.
