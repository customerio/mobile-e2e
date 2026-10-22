// Polls the Customer.io Ext API until a specific customer activity appears.
// This proves that a UI action reached the backend, rather than only proving
// that the sample app accepted the tap.
//
// Required env:
//   MAESTRO_APP_API_KEY   - App API bearer token
//   RUN_EMAIL             - unique email created by setup_run.js
//   EXPECTED_ACTIVITY_TYPE
//   EXPECTED_ACTIVITY_NAME - optional for types such as `geofence` that do not
//                            expose a name in the Ext API activity model
//
// Optional env:
//   EXPECTED_PROPERTY_NAME / EXPECTED_PROPERTY_VALUE
//   EXPECTED_PROPERTY_NAME_2 / EXPECTED_PROPERTY_VALUE_2
//   MIN_TIMESTAMP_SECONDS - ignore activity older than this run
//   EXCLUDE_ACTIVITY_IDS  - JSON array of activity ids that existed before the
//                           action (from RECORD_BASELINE); only a new id matches
//   RECORD_BASELINE       - "true": take one snapshot of the matching activity
//                           ids instead of polling, as output.baseline_activity_ids
//   MAX_WAIT_MS            - default 30000
//   POLL_INTERVAL_MS       - default 750
//   MAESTRO_EXT_API_BASE_URL - default https://api.customer.io/v1
//
// Activity timestamps come from the device's clock, so comparing them with a
// mark taken on the runner's clock can reject a real transition. Use a
// baseline of ids from the backend itself to separate "before" from "after".

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
    var BASELINE_MODE = (typeof RECORD_BASELINE === "string") && RECORD_BASELINE === "true"
    var EXCLUDE_RAW = (typeof EXCLUDE_ACTIVITY_IDS === "string") ? EXCLUDE_ACTIVITY_IDS : ""
    var AUTH = { "Authorization": "Bearer " + MAESTRO_APP_API_KEY }
    var SINK_BASE = (typeof E2E_SINK_BASE_URL === "string" && E2E_SINK_BASE_URL.length > 0)
        ? E2E_SINK_BASE_URL.replace(/\/$/, "")
        : "http://127.0.0.1:8899"
    var SEEN_LIMIT = 10

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

    // Returns null for an absent list, or the array of ids; throws on bad input
    // so a broken hand-off between flow steps fails loudly instead of silently
    // dropping the "new activity" requirement.
    function parseExcludedIds(raw) {
        if (!raw) return null
        var parsed = JSON.parse(raw)
        if (!Array.isArray(parsed)) throw new Error("not an array")
        var ids = {}
        for (var i = 0; i < parsed.length; i++) {
            if (typeof parsed[i] !== "string" || parsed[i].length === 0) throw new Error("non-string id")
            ids[parsed[i]] = true
        }
        return { list: parsed, set: ids }
    }

    var excluded = null
    var excludedError = ""
    try {
        excluded = parseExcludedIds(EXCLUDE_RAW)
    } catch (e) {
        excludedError = "invalid_exclude_activity_ids"
    }

    function bounds() {
        if (BASELINE_MODE) return { mode: "baseline_snapshot" }
        var b = { max_wait_ms: MAX, poll_interval_ms: INTERVAL }
        if (MIN_TIMESTAMP) b.min_timestamp = MIN_TIMESTAMP
        if (excluded) b.exclude_activity_ids = excluded.list
        return b
    }

    function postSink(payload) {
        try {
            if (!payload.kind) payload.kind = "assert_activity"
            payload.expected_type = TYPE
            payload.expected_name = NAME
            payload.expected_property = PROPERTY
            payload.expected_property_value = PROPERTY_VALUE
            payload.expected_property_2 = PROPERTY_2
            payload.expected_property_value_2 = PROPERTY_VALUE_2
            payload.bounds = bounds()
            payload.run_email = RUN_EMAIL
            http.post(SINK_BASE + "/assert", {
                body: JSON.stringify(payload),
                headers: { "Content-Type": "application/json" }
            })
        } catch (_) { /* sink is diagnostic only */ }
    }

    // One customer lookup + one activities read. Returns
    // { cioId, activities } on success or { cioId, reason } on failure.
    var cioId = null
    function fetchActivities() {
        if (!cioId) {
            var lookup = http.get(
                BASE + "/customers?email=" + encodeURIComponent(RUN_EMAIL),
                { headers: AUTH })
            if (lookup.status === 200) {
                var customers = (parse(lookup).results || [])
                if (customers.length > 0 && customers[0].cio_id) cioId = customers[0].cio_id
            } else if (lookup.status !== 404) {
                return { reason: "customer_lookup_status_" + lookup.status }
            }
        }
        if (!cioId) return { reason: "customer_not_resolved" }
        var path = BASE + "/customers/" + encodeURIComponent(cioId) +
            "/activities?limit=100&type=" + encodeURIComponent(TYPE)
        if (NAME) path += "&name=" + encodeURIComponent(NAME)
        var res = http.get(path, { headers: AUTH })
        if (res.status !== 200) return { reason: "activities_status_" + res.status }
        return { activities: parse(res).activities || [] }
    }

    // Type, name and property filters. Timestamp and baseline are separate so
    // the baseline snapshot records every activity of the asserted kind.
    function matchesFilters(activity) {
        var propertyMatches = !PROPERTY ||
            valuesMatch(valueAtPath(activity.data || {}, PROPERTY), PROPERTY_VALUE)
        var property2Matches = !PROPERTY_2 ||
            valuesMatch(valueAtPath(activity.data || {}, PROPERTY_2), PROPERTY_VALUE_2)
        var nameMatches = !NAME || activity.name === NAME
        return activity.type === TYPE && nameMatches && propertyMatches && property2Matches
    }

    function isNew(activity) {
        if (!excluded) return true
        var id = (activity.id === undefined || activity.id === null) ? "" : String(activity.id)
        return id.length > 0 && !excluded.set[id]
    }

    function summarize(activities) {
        var seen = []
        for (var i = 0; i < activities.length && i < SEEN_LIMIT; i++) {
            var activity = activities[i]
            seen.push({
                id: activity.id,
                type: activity.type,
                name: activity.name,
                timestamp: activity.timestamp,
                property_value: PROPERTY ? valueAtPath(activity.data || {}, PROPERTY) : undefined,
                property_value_2: PROPERTY_2 ? valueAtPath(activity.data || {}, PROPERTY_2) : undefined
            })
        }
        return seen
    }

    var startedAt = Date.now()

    if (excludedError) {
        output.assert_reason = excludedError
        output.attempts = "0"
        output.elapsed_ms = "0"
        postSink({ result: "miss", reason: excludedError, attempts: 0, elapsed_ms: 0, activities_seen: null })
        return
    }

    if (BASELINE_MODE) {
        // A single snapshot; there is nothing to wait for. The flow asserts
        // baseline_ok so an unreadable baseline fails here, named, instead of
        // weakening the later assertion.
        output.baseline_ok = "false"
        output.baseline_activity_ids = ""
        var snapshot = fetchActivities()
        if (snapshot.reason) {
            output.assert_reason = "baseline_" + snapshot.reason
            postSink({
                kind: "activity_baseline",
                result: "failed",
                reason: output.assert_reason,
                attempts: 1,
                elapsed_ms: Date.now() - startedAt,
                activities_seen: null
            })
            return
        }
        var baselineIds = []
        for (var j = 0; j < snapshot.activities.length; j++) {
            var candidate = snapshot.activities[j]
            if (matchesFilters(candidate) && candidate.id !== undefined && candidate.id !== null) {
                baselineIds.push(String(candidate.id))
            }
        }
        output.baseline_ok = "true"
        output.baseline_activity_ids = JSON.stringify(baselineIds)
        output.assert_reason = "baseline_recorded_" + baselineIds.length
        postSink({
            kind: "activity_baseline",
            result: "recorded",
            reason: output.assert_reason,
            baseline_activity_ids: baselineIds,
            attempts: 1,
            elapsed_ms: Date.now() - startedAt,
            activities_seen: summarize(snapshot.activities)
        })
        return
    }

    var attempts = 0
    var lastSeen = null
    var lastReason = ""

    while (Date.now() - startedAt < MAX) {
        attempts++

        var fetched = fetchActivities()
        if (fetched.reason) {
            if (fetched.reason !== "customer_not_resolved") lastReason = fetched.reason
        } else {
            var activities = fetched.activities
            var seen = summarize(activities)
            for (var i = 0; i < activities.length; i++) {
                var activity = activities[i]
                var timestampMatches = !MIN_TIMESTAMP || Number(activity.timestamp) >= MIN_TIMESTAMP
                if (matchesFilters(activity) && timestampMatches && isNew(activity)) {
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
                        reason: output.assert_reason,
                        activity_id: activity.id,
                        activity_type: activity.type,
                        activity_name: activity.name,
                        activity_timestamp: activity.timestamp,
                        activity_data: activity.data || {},
                        attempts: attempts,
                        elapsed_ms: Date.now() - startedAt,
                        activities_seen: seen
                    })
                    return
                }
            }
            lastSeen = seen
        }

        var remaining = MAX - (Date.now() - startedAt)
        if (remaining <= 0) break
        busyWait(Math.min(INTERVAL, remaining))
    }

    output.assert_reason = cioId
        ? "no_matching_activity_after_" + attempts
        : "customer_not_resolved_after_" + attempts
    if (lastReason) output.last_error = lastReason
    output.attempts = String(attempts)
    output.elapsed_ms = String(Date.now() - startedAt)
    if (lastSeen) output.activities_seen = JSON.stringify(lastSeen)
    postSink({
        result: "miss",
        reason: output.assert_reason,
        last_error: lastReason || undefined,
        attempts: attempts,
        elapsed_ms: Date.now() - startedAt,
        activities_seen: lastSeen
    })
})()
