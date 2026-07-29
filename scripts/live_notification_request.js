// Drives the Customer.io Live Notifications App API and polls the public
// status endpoint until the requested start/update/end delivery is sent.
//
// Required env:
//   MAESTRO_APP_API_KEY
//   LIVE_NOTIFICATION_ACTION - start | update | end
//   RUN_EMAIL
//   RUN_ID
//
// Optional env:
//   MAESTRO_LIVE_API_BASE_URL (defaults to MAESTRO_EXT_API_BASE_URL)
//   LIVE_NOTIFICATION_TYPE
//   LIVE_ACTIVITY_APP_IDENTIFIER
//   MAX_WAIT_MS / POLL_INTERVAL_MS
//   E2E_SINK_BASE_URL
//
// `start` stores output.remote_live_instance_id. Later invocations reuse it.

(function () {
    var ACTION = LIVE_NOTIFICATION_ACTION
    var TYPE = (typeof LIVE_NOTIFICATION_TYPE === "string" && LIVE_NOTIFICATION_TYPE.length > 0)
        ? LIVE_NOTIFICATION_TYPE
        : "io.customer.livenotifications.segments"
    var rawBase = (typeof MAESTRO_LIVE_API_BASE_URL === "string" && MAESTRO_LIVE_API_BASE_URL.length > 0)
        ? MAESTRO_LIVE_API_BASE_URL
        : ((typeof MAESTRO_EXT_API_BASE_URL === "string" && MAESTRO_EXT_API_BASE_URL.length > 0)
            ? MAESTRO_EXT_API_BASE_URL
            : "https://api.customer.io/v1")
    var BASE = rawBase.replace(/\/$/, "")
    var MAX = parseInt(
        (typeof MAX_WAIT_MS === "string" && MAX_WAIT_MS) ? MAX_WAIT_MS : "90000", 10)
    var INTERVAL = parseInt(
        (typeof POLL_INTERVAL_MS === "string" && POLL_INTERVAL_MS) ? POLL_INTERVAL_MS : "1000", 10)
    var TOKEN = (typeof MAESTRO_APP_API_KEY === "string" &&
        MAESTRO_APP_API_KEY.length > 0)
        ? MAESTRO_APP_API_KEY
        : MAESTRO_EXT_API_KEY
    var AUTH = {
        "Authorization": "Bearer " + TOKEN,
        "Content-Type": "application/json"
    }
    var SINK_BASE = (typeof E2E_SINK_BASE_URL === "string" && E2E_SINK_BASE_URL.length > 0)
        ? E2E_SINK_BASE_URL.replace(/\/$/, "")
        : "http://127.0.0.1:8899"

    output.live_request_ok = "false"
    output.live_request_reason = ""

    function parse(res) {
        try { return JSON.parse(res.body) } catch (_) { return {} }
    }

    function busyWait(ms) {
        var end = Date.now() + ms
        while (Date.now() < end) { /* Maestro GraalJS has no sleep primitive. */ }
    }

    function terminalReason(status, delivery) {
        var detail = String(
            status.failure_reason ||
            delivery.failure_reason ||
            delivery.reason ||
            "")
        if (ACTION === "start" && /no eligible device/i.test(detail)) {
            return "push_to_start_registration_missing_or_ineligible"
        }
        if ((ACTION === "update" || ACTION === "end") &&
            String(delivery.status || "") === "undeliverable") {
            return "instance_token_missing_or_delivery_undeliverable"
        }
        return "terminal_" +
            String(status.state || delivery.status || "failure")
    }

    function postSink(payload) {
        try {
            payload.kind = "live_notification_request"
            payload.action = ACTION
            payload.run_email = RUN_EMAIL
            payload.run_id = RUN_ID
            http.post(SINK_BASE + "/assert", {
                body: JSON.stringify(payload),
                headers: { "Content-Type": "application/json" }
            })
        } catch (_) { /* diagnostic sink only */ }
    }

    function stateFor(action) {
        var labels = {
            start: "Maestro remote start " + RUN_ID,
            update: "Maestro remote update " + RUN_ID,
            end: "Maestro remote end " + RUN_ID
        }
        var complete = action === "start" ? 1 : (action === "update" ? 2 : 3)
        return {
            status: labels[action],
            substatus: "Customer.io backend to APNs sandbox",
            segmentsTotal: 3,
            segmentsComplete: complete,
            trailingText: complete + "/3"
        }
    }

    if (ACTION !== "start" && ACTION !== "update" && ACTION !== "end") {
        output.live_request_reason = "unsupported_action_" + ACTION
        return
    }

    var instanceId = String(output.remote_live_instance_id || "")
    var payload
    if (ACTION === "start") {
        payload = {
            identifiers: { email: RUN_EMAIL },
            notification_type: TYPE,
            platform: "ios",
            attributes: { header: "Maestro " + RUN_ID },
            content_state: stateFor("start"),
            push_payload: {
                alert: {
                    title: "Maestro Live Activity",
                    body: "Remote start " + RUN_ID,
                    sound: "default"
                }
            },
            deep_link: "apn-uikit://live-activities",
            expiration: Math.floor(Date.now() / 1000) + 3600
        }
        if (typeof LIVE_ACTIVITY_APP_IDENTIFIER === "string" && LIVE_ACTIVITY_APP_IDENTIFIER.length > 0) {
            payload.app_identifier = LIVE_ACTIVITY_APP_IDENTIFIER
        }
    } else {
        if (!instanceId) {
            output.live_request_reason = "remote_live_instance_id_missing"
            return
        }
        payload = {
            instance_id: instanceId,
            content_state: stateFor(ACTION),
            deep_link: "apn-uikit://live-activities"
        }
    }

    var request = http.post(BASE + "/live_notifications/" + ACTION, {
        body: JSON.stringify(payload),
        headers: AUTH
    })
    var requestBody = parse(request)
    if (request.status < 200 || request.status >= 300) {
        output.live_request_reason = "request_status_" + request.status
        output.live_request_response = JSON.stringify(requestBody)
        postSink({
            result: "request_failed",
            http_status: request.status,
            response: requestBody
        })
        return
    }

    if (ACTION === "start") {
        instanceId = String(requestBody.instance_id || "")
        if (!instanceId) {
            output.live_request_reason = "start_response_missing_instance_id"
            postSink({ result: "request_failed", response: requestBody })
            return
        }
        output.remote_live_instance_id = instanceId
    }

    var expectedState = ACTION === "end" ? "ended" : "active"
    var startedAt = Date.now()
    var attempts = 0
    var lastStatus = {}
    var lastPollReason = ""

    while (Date.now() - startedAt < MAX) {
        attempts++
        var statusResponse = http.get(
            BASE + "/live_notifications/" + encodeURIComponent(instanceId),
            { headers: { "Authorization": "Bearer " + TOKEN } })
        if (statusResponse.status === 200) {
            lastPollReason = ""
            lastStatus = parse(statusResponse)
            var delivery = lastStatus.last_delivery || {}
            if (lastStatus.state === expectedState &&
                delivery.operation === ACTION &&
                delivery.status === "sent") {
                output.live_request_ok = "true"
                output.live_request_reason = "sent_after_" + attempts + "_attempts"
                output.live_request_status = JSON.stringify(lastStatus)
                output.live_delivery_id = String(delivery.id || "")
                output.attempts = String(attempts)
                output.elapsed_ms = String(Date.now() - startedAt)
                postSink({
                    result: "sent",
                    instance_id: instanceId,
                    status: lastStatus,
                    attempts: attempts,
                    elapsed_ms: Date.now() - startedAt
                })
                return
            }
            if (lastStatus.state === "failed" ||
                delivery.status === "failed" ||
                delivery.status === "undeliverable") {
                output.live_request_reason = terminalReason(lastStatus, delivery)
                break
            }
        } else if (statusResponse.status === 404) {
            lastPollReason = "status_not_found"
        } else {
            lastPollReason = "status_http_" + statusResponse.status
            if (statusResponse.status === 401 || statusResponse.status === 403) {
                output.live_request_reason = lastPollReason
                break
            }
        }

        var remaining = MAX - (Date.now() - startedAt)
        if (remaining <= 0) break
        busyWait(Math.min(INTERVAL, remaining))
    }

    if (!output.live_request_reason) {
        output.live_request_reason = "status_not_sent_before_timeout" +
            (lastPollReason ? "_last_" + lastPollReason : "")
    }
    output.live_request_status = JSON.stringify(lastStatus)
    output.attempts = String(attempts)
    output.elapsed_ms = String(Date.now() - startedAt)
    postSink({
        result: "not_sent",
        reason: output.live_request_reason,
        instance_id: instanceId,
        status: lastStatus,
        attempts: attempts,
        elapsed_ms: Date.now() - startedAt
    })
})()
