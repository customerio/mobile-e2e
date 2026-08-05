// Polls the production Gist queue for the exact inbox message created by this
// Maestro run. This independently verifies the state the SDK fetches and
// mutates, rather than treating the sample UI as the source of truth.
//
// Required env:
//   MAESTRO_SITE_ID
//   RUN_EMAIL
//   One of EXPECTED_MARKER or EXPECTED_DELIVERY_ID
//
// Optional env:
//   EXPECT_PRESENT              true (default) | false
//   EXPECTED_OPENED             true | false | empty (ignore)
//   EXPECTED_DELIVERY_ID        exact delivery id returned by App API send
//   REQUIRE_TITLE_BODY          true to require non-empty title and body
//   REQUIRE_VISUAL_RENDERABLE   true to additionally require a cio_inbox*
//                               topic and a basic/image/cta message type
//   MAESTRO_INBOX_API_BASE_URL  default https://consumer.inapp.customer.io
//   MAESTRO_INBOX_DATACENTER    default US
//   MAESTRO_INBOX_CLIENT_PLATFORM
//   MAX_WAIT_MS                 default 30000
//   POLL_INTERVAL_MS            default 750

// Always sets output.assert_ok and output.assert_reason. On a match it also
// exposes the queue/delivery ids for reports and follow-up assertions.

(function () {
    var BASE = (typeof MAESTRO_INBOX_API_BASE_URL === "string" && MAESTRO_INBOX_API_BASE_URL.length > 0)
        ? MAESTRO_INBOX_API_BASE_URL.replace(/\/$/, "")
        : "https://consumer.inapp.customer.io"
    var DATACENTER = (typeof MAESTRO_INBOX_DATACENTER === "string" && MAESTRO_INBOX_DATACENTER.length > 0)
        ? MAESTRO_INBOX_DATACENTER
        : "US"
    var CLIENT_PLATFORM = (typeof MAESTRO_INBOX_CLIENT_PLATFORM === "string" && MAESTRO_INBOX_CLIENT_PLATFORM.length > 0)
        ? MAESTRO_INBOX_CLIENT_PLATFORM
        : "customerio-maestro"
    var SHOULD_EXIST = !(typeof EXPECT_PRESENT === "string" && EXPECT_PRESENT.toLowerCase() === "false")
    var OPENED = (typeof EXPECTED_OPENED === "string") ? EXPECTED_OPENED.toLowerCase() : ""
    var DELIVERY_ID = (typeof EXPECTED_DELIVERY_ID === "string") ? EXPECTED_DELIVERY_ID : ""
    var MARKER = (typeof EXPECTED_MARKER === "string") ? EXPECTED_MARKER : ""
    var REQUIRE_TITLE_BODY = typeof REQUIRE_TITLE_BODY === "string" &&
        REQUIRE_TITLE_BODY.toLowerCase() === "true"
    // Backward compatibility for callers using the original option name.
    if (!REQUIRE_TITLE_BODY && typeof REQUIRE_VISUAL_PROPERTIES === "string") {
        REQUIRE_TITLE_BODY = REQUIRE_VISUAL_PROPERTIES.toLowerCase() === "true"
    }
    var REQUIRE_VISUAL = typeof REQUIRE_VISUAL_RENDERABLE === "string" &&
        REQUIRE_VISUAL_RENDERABLE.toLowerCase() === "true"
    var MAX = parseInt(
        (typeof MAX_WAIT_MS === "string" && MAX_WAIT_MS) ? MAX_WAIT_MS : "30000", 10)
    var INTERVAL = parseInt(
        (typeof POLL_INTERVAL_MS === "string" && POLL_INTERVAL_MS) ? POLL_INTERVAL_MS : "750", 10)
    var SINK_BASE = (typeof E2E_SINK_BASE_URL === "string" && E2E_SINK_BASE_URL.length > 0)
        ? E2E_SINK_BASE_URL.replace(/\/$/, "")
        : "http://127.0.0.1:8899"

    output.assert_ok = "false"
    output.assert_reason = ""

    function asciiBase64(value) {
        var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        var result = ""
        for (var i = 0; i < value.length; i += 3) {
            var a = value.charCodeAt(i) & 255
            var hasB = i + 1 < value.length
            var hasC = i + 2 < value.length
            var b = hasB ? value.charCodeAt(i + 1) & 255 : 0
            var c = hasC ? value.charCodeAt(i + 2) & 255 : 0
            var bits = (a << 16) | (b << 8) | c
            result += alphabet.charAt((bits >> 18) & 63)
            result += alphabet.charAt((bits >> 12) & 63)
            result += hasB ? alphabet.charAt((bits >> 6) & 63) : "="
            result += hasC ? alphabet.charAt(bits & 63) : "="
        }
        return result
    }

    function parse(res) {
        try { return JSON.parse(res.body) } catch (_) { return {} }
    }

    function busyWait(ms) {
        var end = Date.now() + ms
        while (Date.now() < end) { /* Maestro's GraalJS runtime has no sleep primitive. */ }
    }

    function postSink(payload) {
        try {
            payload.kind = "assert_inbox_queue"
            payload.run_email = RUN_EMAIL
            payload.expected_marker = MARKER
            payload.expected_delivery_id = DELIVERY_ID
            payload.expected_present = SHOULD_EXIST
            payload.expected_opened = OPENED
            http.post(SINK_BASE + "/assert", {
                body: JSON.stringify(payload),
                headers: { "Content-Type": "application/json" }
            })
        } catch (_) { /* sink is diagnostic only */ }
    }

    if (!MARKER && !DELIVERY_ID) {
        output.assert_reason = "missing_expected_marker_or_delivery_id"
        postSink({ result: "invalid", reason: output.assert_reason })
        return
    }

    var headers = {
        "Content-Type": "application/json",
        "X-CIO-Site-Id": MAESTRO_SITE_ID,
        "X-CIO-Datacenter": DATACENTER,
        "X-CIO-Client-Platform": CLIENT_PLATFORM,
        "X-CIO-Client-Version": "1",
        "X-Gist-Encoded-User-Token": asciiBase64(RUN_EMAIL),
        "X-Gist-User-Anonymous": "false"
    }
    var startedAt = Date.now()
    var attempts = 0
    var stableAbsentAttempts = 0
    var lastSeen = []
    var lastAttemptWasTransportError = false

    while (Date.now() - startedAt < MAX) {
        attempts++
        lastAttemptWasTransportError = false
        var correlation = DELIVERY_ID || MARKER
        var sessionId = "maestro-inbox-" + encodeURIComponent(correlation) + "-" + attempts
        var res
        try {
            res = http.post(BASE + "/api/v4/users?sessionId=" + sessionId, {
                body: "{}",
                headers: headers
            })
        } catch (error) {
            lastAttemptWasTransportError = true
            stableAbsentAttempts = 0
            postSink({
                result: "transport_error",
                reason: "queue_transport_error",
                attempts: attempts,
                error: String(error)
            })
            var retryRemaining = MAX - (Date.now() - startedAt)
            if (retryRemaining <= 0) break
            busyWait(Math.min(INTERVAL, retryRemaining))
            continue
        }

        if (res.status === 200 || res.status === 204) {
            var messages = res.status === 200 ? (parse(res).inboxMessages || []) : []
            var match = null
            lastSeen = []
            for (var i = 0; i < messages.length; i++) {
                var message = messages[i]
                var propertiesText = JSON.stringify(message.properties || {})
                if (i < 10) {
                    lastSeen.push({
                        queue_id: message.queueId,
                        delivery_id: message.deliveryId,
                        opened: message.opened,
                        type: message.type,
                        topics: message.topics || []
                    })
                }
                var markerMatches = MARKER && propertiesText.indexOf(MARKER) !== -1
                var deliveryMatches = DELIVERY_ID && String(message.deliveryId || "") === DELIVERY_ID
                if (markerMatches || deliveryMatches) match = message
            }

            if (SHOULD_EXIST && match) {
                var openedMatches = OPENED === "" || String(Boolean(match.opened)) === OPENED
                var properties = match.properties || {}
                var title = typeof properties.title === "string" ? properties.title : ""
                var body = typeof properties.body === "string" ? properties.body : ""
                var topics = Array.isArray(match.topics) ? match.topics : []
                var type = typeof match.type === "string" ? match.type : ""
                var titleBodyMatches = !REQUIRE_TITLE_BODY || (title.length > 0 && body.length > 0)
                var hasVisualTopic = topics.some(function (topic) {
                    return typeof topic === "string" && topic.toLowerCase().indexOf("cio_inbox") === 0
                })
                var hasVisualType = type === "basic" || type === "image" || type === "cta"
                var visualMatches = !REQUIRE_VISUAL || (titleBodyMatches && hasVisualTopic && hasVisualType)
                if (openedMatches && titleBodyMatches && visualMatches) {
                    output.assert_ok = "true"
                    output.assert_reason = "matched_after_" + attempts + "_attempts"
                    output.inbox_queue_id = String(match.queueId || "")
                    output.inbox_delivery_id = String(match.deliveryId || "")
                    output.inbox_opened = String(Boolean(match.opened))
                    output.inbox_title = title
                    output.inbox_body = body
                    output.inbox_type = type
                    output.inbox_topics = JSON.stringify(topics)
                    output.inbox_visual_renderable = String(
                        title.length > 0 && body.length > 0 && hasVisualTopic && hasVisualType)
                    output.inbox_title_regex = title.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
                    output.inbox_body_regex = body.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
                    output.attempts = String(attempts)
                    output.elapsed_ms = String(Date.now() - startedAt)
                    postSink({
                        result: "match",
                        queue_id: match.queueId,
                        delivery_id: match.deliveryId,
                        opened: Boolean(match.opened),
                        message_type: type,
                        topics: topics,
                        visual_renderable: title.length > 0 && body.length > 0 &&
                            hasVisualTopic && hasVisualType,
                        title: title,
                        body: body,
                        attempts: attempts,
                        elapsed_ms: Date.now() - startedAt
                    })
                    return
                }
            } else if (!SHOULD_EXIST && !match) {
                stableAbsentAttempts++
                if (stableAbsentAttempts >= 3) {
                    output.assert_ok = "true"
                    output.assert_reason = "absent_for_3_consecutive_polls"
                    output.attempts = String(attempts)
                    output.elapsed_ms = String(Date.now() - startedAt)
                    postSink({
                        result: "absent",
                        attempts: attempts,
                        elapsed_ms: Date.now() - startedAt
                    })
                    return
                }
            } else {
                stableAbsentAttempts = 0
            }
        } else {
            output.assert_reason = "queue_status_" + res.status
            stableAbsentAttempts = 0
        }

        var remaining = MAX - (Date.now() - startedAt)
        if (remaining <= 0) break
        busyWait(Math.min(INTERVAL, remaining))
    }

    if (lastAttemptWasTransportError) {
        output.assert_reason = "queue_transport_error"
    } else {
        output.assert_reason = SHOULD_EXIST
            ? "message_or_opened_state_not_matched_after_" + attempts
            : "message_still_present_after_" + attempts
    }
    output.attempts = String(attempts)
    output.elapsed_ms = String(Date.now() - startedAt)
    output.messages_seen = JSON.stringify(lastSeen)
    postSink({
        result: "miss",
        reason: output.assert_reason,
        attempts: attempts,
        elapsed_ms: Date.now() - startedAt,
        messages_seen: lastSeen
    })
})()
