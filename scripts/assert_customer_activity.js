// Polls the Customer.io Ext API until a specific customer activity appears.
// This proves that a UI action reached the backend, rather than only proving
// that the sample app accepted the tap.
//
// Required env:
//   MAESTRO_EXT_API_KEY   - Ext API bearer token
//   RUN_EMAIL             - unique email created by setup_run.js
//   EXPECTED_ACTIVITY_TYPE
//   EXPECTED_ACTIVITY_NAME - optional for types such as `geofence` that do not
//                            expose a name in the Ext API activity model
//
// Optional env:
//   EXPECTED_PROPERTY_NAME / EXPECTED_PROPERTY_VALUE
//   EXPECTED_PROPERTY_NAME_2 / EXPECTED_PROPERTY_VALUE_2
//   MIN_TIMESTAMP_SECONDS - ignore activity older than this run
//   MAX_WAIT_MS            - default 30000
//   POLL_INTERVAL_MS       - default 750
//   MAESTRO_EXT_API_BASE_URL - default https://api.customer.io/v1

(function () {
    var BASE = (typeof MAESTRO_EXT_API_BASE_URL === "string" && MAESTRO_EXT_API_BASE_URL.length > 0)
        ? MAESTRO_EXT_API_BASE_URL.replace(/\/$/, "")
        : "https://api.customer.io/v1"
    var TYPE = EXPECTED_ACTIVITY_TYPE
    var NAME = (typeof EXPECTED_ACTIVITY_NAME === "string") ? EXPECTED_ACTIVITY_NAME : ""
    var PROPERTY = (typeof EXPECTED_PROPERTY_NAME === "string") ? EXPECTED_PROPERTY_NAME : ""
    var PROPERTY_VALUE = (typeof EXPECTED_PROPERTY_VALUE === "string") ? EXPECTED_PROPERTY_VALUE : ""
    var PROPERTY_2 = (typeof EXPECTED_PROPERTY_NAME_2 === "string") ? EXPECTED_PROPERTY_NAME_2 : ""
    var PROPERTY_VALUE_2 = (typeof EXPECTED_PROPERTY_VALUE_2 === "string") ? EXPECTED_PROPERTY_VALUE_2 : ""
    var MIN_TIMESTAMP = parseInt(
        (typeof MIN_TIMESTAMP_SECONDS === "string" && MIN_TIMESTAMP_SECONDS) ? MIN_TIMESTAMP_SECONDS : "0", 10)
    var MAX = parseInt(
        (typeof MAX_WAIT_MS === "string" && MAX_WAIT_MS) ? MAX_WAIT_MS : "30000", 10)
    var INTERVAL = parseInt(
        (typeof POLL_INTERVAL_MS === "string" && POLL_INTERVAL_MS) ? POLL_INTERVAL_MS : "750", 10)
    var AUTH = { "Authorization": "Bearer " + MAESTRO_EXT_API_KEY }
    var SINK_BASE = (typeof E2E_SINK_BASE_URL === "string" && E2E_SINK_BASE_URL.length > 0)
        ? E2E_SINK_BASE_URL.replace(/\/$/, "")
        : "http://127.0.0.1:8899"

    output.assert_ok = "false"
    output.assert_reason = ""

    function parse(res) {
        try { return JSON.parse(res.body) } catch (_) { return {} }
    }

    function busyWait(ms) {
        var end = Date.now() + ms
        while (Date.now() < end) { /* Maestro GraalJS has no sleep primitive. */ }
    }

    function valueAtPath(value, path) {
        var parts = path.split(".")
        var current = value
        for (var i = 0; i < parts.length; i++) {
            if (current === null || typeof current !== "object" || !(parts[i] in current)) return undefined
            current = current[parts[i]]
        }
        return current
    }

    function valuesMatch(actual, expected) {
        if (String(actual) === expected) return true
        var actualNumber = Number(actual)
        var expectedNumber = Number(expected)
        return !isNaN(actualNumber) && !isNaN(expectedNumber) &&
            Math.abs(actualNumber - expectedNumber) < 0.0000001
    }

    function postSink(payload) {
        try {
            payload.kind = "assert_activity"
            payload.expected_type = TYPE
            payload.expected_name = NAME
            payload.expected_property = PROPERTY
            payload.expected_property_value = PROPERTY_VALUE
            payload.expected_property_2 = PROPERTY_2
            payload.expected_property_value_2 = PROPERTY_VALUE_2
            payload.run_email = RUN_EMAIL
            http.post(SINK_BASE + "/assert", {
                body: JSON.stringify(payload),
                headers: { "Content-Type": "application/json" }
            })
        } catch (_) { /* sink is diagnostic only */ }
    }

    var startedAt = Date.now()
    var attempts = 0
    var cioId = null
    var lastSeen = null

    while (Date.now() - startedAt < MAX) {
        attempts++

        if (!cioId) {
            var lookup = http.get(
                BASE + "/customers?email=" + encodeURIComponent(RUN_EMAIL),
                { headers: AUTH })
            if (lookup.status === 200) {
                var customers = (parse(lookup).results || [])
                if (customers.length > 0 && customers[0].cio_id) cioId = customers[0].cio_id
            } else if (lookup.status !== 404) {
                output.assert_reason = "customer_lookup_status_" + lookup.status
            }
        }

        if (cioId) {
            var path = BASE + "/customers/" + encodeURIComponent(cioId) +
                "/activities?limit=100&type=" + encodeURIComponent(TYPE)
            if (NAME) path += "&name=" + encodeURIComponent(NAME)
            var res = http.get(path, { headers: AUTH })
            if (res.status === 200) {
                var activities = parse(res).activities || []
                var seen = []
                for (var i = 0; i < activities.length; i++) {
                    var activity = activities[i]
                    var actualProperty = PROPERTY ? valueAtPath(activity.data || {}, PROPERTY) : undefined
                    var actualProperty2 = PROPERTY_2 ? valueAtPath(activity.data || {}, PROPERTY_2) : undefined
                    if (i < 10) {
                        seen.push({
                            id: activity.id,
                            type: activity.type,
                            name: activity.name,
                            timestamp: activity.timestamp,
                            property_value: actualProperty,
                            property_value_2: actualProperty2
                        })
                    }
                    var propertyMatches = !PROPERTY || valuesMatch(actualProperty, PROPERTY_VALUE)
                    var property2Matches = !PROPERTY_2 || valuesMatch(actualProperty2, PROPERTY_VALUE_2)
                    var timestampMatches = !MIN_TIMESTAMP || Number(activity.timestamp) >= MIN_TIMESTAMP
                    var nameMatches = !NAME || activity.name === NAME
                    if (activity.type === TYPE && nameMatches && propertyMatches && property2Matches && timestampMatches) {
                        output.assert_ok = "true"
                        output.assert_reason = "matched_after_" + attempts + "_attempts"
                        output.activity_id = String(activity.id || "")
                        output.activity_type = String(activity.type || "")
                        output.activity_name = String(activity.name || "")
                        output.activity_timestamp = String(activity.timestamp || "")
                        output.activity_data = JSON.stringify(activity.data || {})
                        output.attempts = String(attempts)
                        output.elapsed_ms = String(Date.now() - startedAt)
                        postSink({
                            result: "match",
                            activity_id: activity.id,
                            activity_type: activity.type,
                            activity_name: activity.name,
                            activity_timestamp: activity.timestamp,
                            activity_data: activity.data || {},
                            attempts: attempts,
                            elapsed_ms: Date.now() - startedAt
                        })
                        return
                    }
                }
                lastSeen = seen
            } else {
                output.assert_reason = "activities_status_" + res.status
            }
        }

        var remaining = MAX - (Date.now() - startedAt)
        if (remaining <= 0) break
        busyWait(Math.min(INTERVAL, remaining))
    }

    output.assert_reason = cioId
        ? "no_matching_activity_after_" + attempts
        : "customer_not_resolved_after_" + attempts
    output.attempts = String(attempts)
    output.elapsed_ms = String(Date.now() - startedAt)
    if (lastSeen) output.activities_seen = JSON.stringify(lastSeen)
    postSink({
        result: "miss",
        reason: output.assert_reason,
        attempts: attempts,
        elapsed_ms: Date.now() - startedAt,
        activities_seen: lastSeen
    })
})()
