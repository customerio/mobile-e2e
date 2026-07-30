// Sends a real transactional Inbox message to the fresh profile identified by
// this Maestro run. Retries briefly because SDK identify ingestion and the App
// API send can race in an end-to-end test.
//
// Required env:
//   MAESTRO_APP_API_KEY
//   INBOX_TRANSACTIONAL_MESSAGE_ID
//   RUN_EMAIL
//   RUN_ID
//
// Optional env:
//   MAESTRO_EXT_API_BASE_URL  default https://api.customer.io/v1
//   MAX_WAIT_MS               default 30000
//   POLL_INTERVAL_MS          default 750

(function () {
    var BASE = (typeof MAESTRO_EXT_API_BASE_URL === "string" && MAESTRO_EXT_API_BASE_URL.length > 0)
        ? MAESTRO_EXT_API_BASE_URL.replace(/\/$/, "")
        : "https://api.customer.io/v1"
    var MAX = parseInt(
        (typeof MAX_WAIT_MS === "string" && MAX_WAIT_MS) ? MAX_WAIT_MS : "30000", 10)
    var INTERVAL = parseInt(
        (typeof POLL_INTERVAL_MS === "string" && POLL_INTERVAL_MS) ? POLL_INTERVAL_MS : "750", 10)
    var SINK_BASE = (typeof E2E_SINK_BASE_URL === "string" && E2E_SINK_BASE_URL.length > 0)
        ? E2E_SINK_BASE_URL.replace(/\/$/, "")
        : "http://127.0.0.1:8899"

    output.inbox_send_ok = "false"
    output.inbox_send_reason = ""

    function parse(res) {
        try { return JSON.parse(res.body) } catch (_) { return {} }
    }

    function busyWait(ms) {
        var end = Date.now() + ms
        while (Date.now() < end) { /* Maestro's GraalJS runtime has no sleep primitive. */ }
    }

    function postSink(payload) {
        try {
            payload.kind = "send_inbox"
            payload.run_email = RUN_EMAIL
            payload.transactional_message_id = INBOX_TRANSACTIONAL_MESSAGE_ID
            http.post(SINK_BASE + "/assert", {
                body: JSON.stringify(payload),
                headers: { "Content-Type": "application/json" }
            })
        } catch (_) { /* sink is diagnostic only */ }
    }

    var numericId = parseInt(INBOX_TRANSACTIONAL_MESSAGE_ID, 10)
    var messageId = String(numericId) === INBOX_TRANSACTIONAL_MESSAGE_ID ? numericId : INBOX_TRANSACTIONAL_MESSAGE_ID
    var requestBody = {
        transactional_message_id: messageId,
        identifiers: { email: RUN_EMAIL },
        message_data: {
            run_id: RUN_ID,
            title: "MAESTRO_INBOX_OK " + RUN_ID,
            body: "MAESTRO_INBOX_BODY"
        }
    }
    var startedAt = Date.now()
    var attempts = 0
    var lastStatus = 0
    var lastBody = {}

    while (Date.now() - startedAt < MAX) {
        attempts++
        var response = http.post(BASE + "/send/inbox_message", {
            body: JSON.stringify(requestBody),
            headers: {
                "Authorization": "Bearer " + MAESTRO_APP_API_KEY,
                "Content-Type": "application/json"
            }
        })
        lastStatus = response.status
        lastBody = parse(response)
        if (response.status === 200 && lastBody.delivery_id) {
            output.inbox_send_ok = "true"
            output.inbox_send_reason = "sent_after_" + attempts + "_attempts"
            output.inbox_delivery_id = String(lastBody.delivery_id)
            output.inbox_queued_at = String(lastBody.queued_at || "")
            output.attempts = String(attempts)
            output.elapsed_ms = String(Date.now() - startedAt)
            postSink({
                result: "sent",
                delivery_id: lastBody.delivery_id,
                queued_at: lastBody.queued_at,
                attempts: attempts,
                elapsed_ms: Date.now() - startedAt
            })
            return
        }

        var errorText = JSON.stringify(lastBody).toLowerCase()
        var retryable = response.status === 404 ||
            (response.status === 400 &&
                (errorText.indexOf("customer") !== -1 ||
                 errorText.indexOf("person") !== -1 ||
                 errorText.indexOf("recipient") !== -1 ||
                 errorText.indexOf("identifier") !== -1))
        if (!retryable) break

        var remaining = MAX - (Date.now() - startedAt)
        if (remaining <= 0) break
        busyWait(Math.min(INTERVAL, remaining))
    }

    output.inbox_send_reason = "send_status_" + lastStatus + "_after_" + attempts
    output.inbox_send_response = JSON.stringify(lastBody)
    output.attempts = String(attempts)
    output.elapsed_ms = String(Date.now() - startedAt)
    postSink({
        result: "failed",
        reason: output.inbox_send_reason,
        response: lastBody,
        attempts: attempts,
        elapsed_ms: Date.now() - startedAt
    })
})()
