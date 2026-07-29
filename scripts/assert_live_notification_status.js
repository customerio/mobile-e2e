// Polls the Customer.io Live Notifications status API for an exact
// conversation created by an SDK-reported local Live Activity operation.
//
// This is the correct backend assertion surface for `Live Notification Event`:
// the Customer.io CDP destination consumes that SDK event and maps it to a
// device-sourced live_notification operation rather than a generic activity.
//
// Required env:
//   LIVE_INSTANCE_ID
//   EXPECTED_STATE - active | ended | failed | expired
//   EXPECTED_OPERATION - start | update | end
//
// Optional env:
//   EXPECTED_NOTIFICATION_TYPE
//   EXPECTED_PLATFORM (default ios)
//   EXPECTED_DELIVERY_STATUS (default sent)
//   EXPECTED_SOURCE (default device)
//   EXPECTED_DELIVERY_ID
//   MIN_TIMESTAMP_SECONDS
//   MIN_STABLE_MS (continue polling a matching state for this duration)
//   MAX_WAIT_MS / POLL_INTERVAL_MS
//   MAESTRO_LIVE_API_BASE_URL / MAESTRO_EXT_API_BASE_URL
//   MAESTRO_APP_API_KEY (falls back to MAESTRO_EXT_API_KEY)
//   E2E_SINK_BASE_URL

(function () {
    var rawBase = (typeof MAESTRO_LIVE_API_BASE_URL === "string" &&
        MAESTRO_LIVE_API_BASE_URL.length > 0)
        ? MAESTRO_LIVE_API_BASE_URL
        : ((typeof MAESTRO_EXT_API_BASE_URL === "string" &&
            MAESTRO_EXT_API_BASE_URL.length > 0)
            ? MAESTRO_EXT_API_BASE_URL
            : "https://api.customer.io/v1")
    var BASE = rawBase.replace(/\/$/, "")
    var TOKEN = (typeof MAESTRO_APP_API_KEY === "string" &&
        MAESTRO_APP_API_KEY.length > 0)
        ? MAESTRO_APP_API_KEY
        : MAESTRO_EXT_API_KEY
    var EXPECTED_PLATFORM_VALUE =
        (typeof EXPECTED_PLATFORM === "string" && EXPECTED_PLATFORM.length > 0)
            ? EXPECTED_PLATFORM
            : "ios"
    var EXPECTED_STATUS_VALUE =
        (typeof EXPECTED_DELIVERY_STATUS === "string" &&
            EXPECTED_DELIVERY_STATUS.length > 0)
            ? EXPECTED_DELIVERY_STATUS
            : "sent"
    var EXPECTED_SOURCE_VALUE =
        (typeof EXPECTED_SOURCE === "string" && EXPECTED_SOURCE.length > 0)
            ? EXPECTED_SOURCE
            : "device"
    var EXPECTED_TYPE_VALUE =
        (typeof EXPECTED_NOTIFICATION_TYPE === "string")
            ? EXPECTED_NOTIFICATION_TYPE
            : ""
    var EXPECTED_DELIVERY_ID_VALUE =
        (typeof EXPECTED_DELIVERY_ID === "string")
            ? EXPECTED_DELIVERY_ID
            : ""
    var MIN_TIMESTAMP = parseInt(
        (typeof MIN_TIMESTAMP_SECONDS === "string" && MIN_TIMESTAMP_SECONDS)
            ? MIN_TIMESTAMP_SECONDS
            : "0", 10)
    var MIN_STABLE = parseInt(
        (typeof MIN_STABLE_MS === "string" && MIN_STABLE_MS)
            ? MIN_STABLE_MS
            : "0", 10)
    var MAX = parseInt(
        (typeof MAX_WAIT_MS === "string" && MAX_WAIT_MS) ? MAX_WAIT_MS : "90000", 10)
    var INTERVAL = parseInt(
        (typeof POLL_INTERVAL_MS === "string" && POLL_INTERVAL_MS)
            ? POLL_INTERVAL_MS
            : "750", 10)
    var AUTH = { "Authorization": "Bearer " + TOKEN }
    var SINK_BASE = (typeof E2E_SINK_BASE_URL === "string" &&
        E2E_SINK_BASE_URL.length > 0)
        ? E2E_SINK_BASE_URL.replace(/\/$/, "")
        : "http://127.0.0.1:8899"

    output.live_status_ok = "false"
    output.live_status_reason = ""

    function parse(res) {
        try { return JSON.parse(res.body) } catch (_) { return {} }
    }

    function busyWait(ms) {
        var end = Date.now() + ms
        while (Date.now() < end) { /* Maestro GraalJS has no sleep primitive. */ }
    }

    function postSink(payload) {
        try {
            payload.kind = "assert_live_notification_status"
            payload.instance_id = LIVE_INSTANCE_ID
            payload.expected_state = EXPECTED_STATE
            payload.expected_operation = EXPECTED_OPERATION
            http.post(SINK_BASE + "/assert", {
                body: JSON.stringify(payload),
                headers: { "Content-Type": "application/json" }
            })
        } catch (_) { /* diagnostic sink only */ }
    }

    function timestampSeconds(value) {
        if (typeof value === "number" || (typeof value === "string" && value.length > 0)) {
            var numeric = Number(value)
            if (isFinite(numeric)) {
                return numeric > 1000000000000 ? Math.floor(numeric / 1000) : numeric
            }
        }
        if (typeof value === "string") {
            var parsed = Date.parse(value)
            if (!isNaN(parsed)) return Math.floor(parsed / 1000)
        }
        return NaN
    }

    function mismatch(status) {
        var delivery = status.last_delivery || {}
        if (String(status.instance_id || "") !== String(LIVE_INSTANCE_ID)) {
            return "instance_id_mismatch"
        }
        if (String(status.state || "") !== String(EXPECTED_STATE)) {
            return "state_" + String(status.state || "missing")
        }
        if (String(status.platform || "") !== EXPECTED_PLATFORM_VALUE) {
            return "platform_" + String(status.platform || "missing")
        }
        if (EXPECTED_TYPE_VALUE &&
            String(status.notification_type || "") !== EXPECTED_TYPE_VALUE) {
            return "notification_type_mismatch"
        }
        if (String(delivery.operation || "") !== String(EXPECTED_OPERATION)) {
            return "operation_" + String(delivery.operation || "missing")
        }
        if (String(delivery.status || "") !== EXPECTED_STATUS_VALUE) {
            return "delivery_status_" + String(delivery.status || "missing")
        }
        if (String(delivery.source || "") !== EXPECTED_SOURCE_VALUE) {
            return "source_" + String(delivery.source || "missing")
        }
        if (EXPECTED_DELIVERY_ID_VALUE &&
            String(delivery.id || "") !== EXPECTED_DELIVERY_ID_VALUE) {
            return "delivery_id_changed"
        }
        if (MIN_TIMESTAMP > 0) {
            var createdAt = timestampSeconds(delivery.created_at)
            if (isNaN(createdAt)) return "delivery_timestamp_missing_or_invalid"
            if (createdAt < MIN_TIMESTAMP) return "delivery_predates_run"
        }
        return ""
    }

    var startedAt = Date.now()
    var stableSince = 0
    var attempts = 0
    var lastStatus = {}
    var lastReason = "status_not_observed"

    while (Date.now() - startedAt < MAX) {
        attempts++
        var response = http.get(
            BASE + "/live_notifications/" + encodeURIComponent(LIVE_INSTANCE_ID),
            { headers: AUTH })
        if (response.status === 200) {
            lastStatus = parse(response)
            lastReason = mismatch(lastStatus)
            if (!lastReason) {
                if (!stableSince) stableSince = Date.now()
                if (Date.now() - stableSince >= MIN_STABLE) {
                    var delivery = lastStatus.last_delivery || {}
                    output.live_status_ok = "true"
                    output.live_status_reason = "matched_after_" + attempts + "_attempts"
                    output.live_status_delivery_id = String(delivery.id || "")
                    output.live_status_response = JSON.stringify(lastStatus)
                    output.attempts = String(attempts)
                    output.elapsed_ms = String(Date.now() - startedAt)
                    postSink({
                        result: "match",
                        status: lastStatus,
                        attempts: attempts,
                        elapsed_ms: Date.now() - startedAt,
                        stable_ms: Date.now() - stableSince
                    })
                    return
                }
            } else {
                stableSince = 0
                if (lastReason === "delivery_id_changed") break
            }
        } else if (response.status === 404) {
            lastReason = "status_not_found"
            stableSince = 0
        } else {
            lastReason = "status_http_" + response.status
            stableSince = 0
            if (response.status === 401 || response.status === 403) break
        }

        var remaining = MAX - (Date.now() - startedAt)
        if (remaining <= 0) break
        busyWait(Math.min(INTERVAL, remaining))
    }

    output.live_status_reason = lastReason
    output.live_status_response = JSON.stringify(lastStatus)
    output.attempts = String(attempts)
    output.elapsed_ms = String(Date.now() - startedAt)
    postSink({
        result: "miss",
        reason: lastReason,
        status: lastStatus,
        attempts: attempts,
        elapsed_ms: Date.now() - startedAt
    })
})()
