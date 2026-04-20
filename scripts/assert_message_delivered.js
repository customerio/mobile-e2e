// Waits up to MAX_WAIT_MS for a message of EXPECTED_TYPE to appear for
// RUN_EMAIL with the MIN_METRIC populated. Polls Customer.io Ext API.
//
// Required env (passed via runScript.env):
//   MAESTRO_EXT_API_KEY  - Bearer token for api.customer.io
//   RUN_EMAIL            - Customer email (unique per test run)
//   EXPECTED_TYPE        - in_app | push | email | slack
//
// Optional env (with defaults):
//   MIN_METRIC           - "sent" (default) | "delivered" | "drafted" | "opened" | ...
//   MAX_WAIT_MS          - "20000" ms total budget
//   POLL_INTERVAL_MS     - "750" ms between attempts (busy-wait; no Thread.sleep available)
//
// Always sets:
//   output.assert_ok      - "true" | "false"
//   output.assert_reason  - last outcome string
//   output.attempts       - attempts made
//   output.elapsed_ms     - total elapsed
// On success additionally sets:
//   output.message_id
//   output.message_type
//   output.message_metrics  (JSON string)
//   output.message_campaign
//   output.message_template
// On miss also sets:
//   output.messages_seen  (JSON string; last observation)

(function () {
    var BASE = "https://api.customer.io/v1"
    var TYPE = EXPECTED_TYPE
    var MIN = (typeof MIN_METRIC === "string" && MIN_METRIC.length > 0) ? MIN_METRIC : "sent"
    var MAX = parseInt(
        (typeof MAX_WAIT_MS === "string" && MAX_WAIT_MS) ? MAX_WAIT_MS : "20000", 10)
    var INTERVAL = parseInt(
        (typeof POLL_INTERVAL_MS === "string" && POLL_INTERVAL_MS) ? POLL_INTERVAL_MS : "750", 10)
    var AUTH = { "Authorization": "Bearer " + MAESTRO_EXT_API_KEY }
    // Local sink for surfacing backend values in the rendered HTML report.
    var SINK = "http://127.0.0.1:8899/assert"
    var CAMP = (typeof CAMPAIGN_ID === "string") ? CAMPAIGN_ID : ""

    output.assert_ok = "false"
    output.assert_reason = ""

    function postSink(payload) {
        try {
            payload.kind = "assert_message"
            payload.expected_type = TYPE
            payload.min_metric = MIN
            payload.campaign_filter = CAMP
            payload.run_email = RUN_EMAIL
            http.post(SINK, { body: JSON.stringify(payload), headers: { "Content-Type": "application/json" } })
        } catch (_) { /* sink not running; non-fatal */ }
    }

    function parse(res) {
        try { return JSON.parse(res.body) } catch (_) { return {} }
    }

    // Busy-wait — Maestro's GraalJS runtime doesn't expose Thread.sleep.
    function busyWait(ms) {
        var end = Date.now() + ms
        while (Date.now() < end) { /* spin */ }
    }

    var startedAt = Date.now()
    var attempts = 0
    var cioId = null
    var lastSeen = null

    while (Date.now() - startedAt < MAX) {
        attempts++

        // Step 1: resolve cio_id (retry if 404 / empty results).
        if (!cioId) {
            var lookup = http.get(
                BASE + "/customers?email=" + encodeURIComponent(RUN_EMAIL),
                { headers: AUTH })
            if (lookup.status === 200) {
                var lookupBody = parse(lookup)
                var results = (lookupBody && lookupBody.results) || []
                if (results.length > 0 && results[0].cio_id) {
                    cioId = results[0].cio_id
                }
            } else if (lookup.status !== 404) {
                // 5xx / 401 / etc. — record and keep trying, might be transient.
                output.assert_reason = "customer_lookup_status_" + lookup.status
            }
        }

        // Step 2: if we have a cio_id, look for the message.
        if (cioId) {
            var res = http.get(
                BASE + "/customers/" + cioId + "/messages?limit=50",
                { headers: AUTH })
            if (res.status === 200) {
                var body = parse(res)
                var messages = (body && body.messages) || []
                var seen = []
                for (var i = 0; i < messages.length; i++) {
                    var m = messages[i]
                    var metrics = m.metrics || {}
                    if (i < 10) seen.push({ type: m.type, campaign_id: m.campaign_id, metrics: Object.keys(metrics) })
                    if (m.type === TYPE && metrics[MIN] && (!CAMP || String(m.campaign_id) === CAMP)) {
                        output.assert_ok = "true"
                        output.assert_reason = "matched_after_" + attempts + "_attempts"
                        output.message_id = m.id
                        output.message_type = m.type
                        output.message_metrics = JSON.stringify(metrics)
                        output.message_campaign = String(m.campaign_id)
                        output.message_template = String(m.msg_template_id)
                        output.attempts = String(attempts)
                        output.elapsed_ms = String(Date.now() - startedAt)
                        postSink({
                            result: "match",
                            message_id: m.id,
                            message_type: m.type,
                            campaign_id: m.campaign_id,
                            msg_template_id: m.msg_template_id,
                            metrics: metrics,
                            attempts: attempts,
                            elapsed_ms: Date.now() - startedAt
                        })
                        return
                    }
                }
                lastSeen = seen
            } else {
                output.assert_reason = "messages_status_" + res.status
            }
        }

        // Budget-aware sleep: don't overshoot MAX.
        var remaining = MAX - (Date.now() - startedAt)
        if (remaining <= 0) break
        busyWait(Math.min(INTERVAL, remaining))
    }

    // Timed out.
    output.assert_reason = cioId
        ? ("no_matching_" + TYPE + "_with_" + MIN + "_after_" + attempts)
        : ("customer_not_resolved_after_" + attempts)
    output.attempts = String(attempts)
    output.elapsed_ms = String(Date.now() - startedAt)
    if (lastSeen) output.messages_seen = JSON.stringify(lastSeen)
    postSink({
        result: "miss",
        reason: output.assert_reason,
        attempts: attempts,
        elapsed_ms: Date.now() - startedAt,
        messages_seen: lastSeen
    })
})()
