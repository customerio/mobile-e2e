#!/usr/bin/env node

const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(
    path.join(__dirname, "..", "scripts", "assert_inbox_queue_state.js"),
    "utf8")

function runScenario(queuePost, maxWaitMs, expectedPresent = "true") {
    let clock = 0
    const sinkEvents = []
    const output = {}
    const context = {
        Date: { now: () => ++clock },
        E2E_SINK_BASE_URL: "http://127.0.0.1:9999",
        EXPECTED_DELIVERY_ID: "delivery-1",
        EXPECTED_MARKER: "",
        EXPECTED_OPENED: "false",
        EXPECT_PRESENT: expectedPresent,
        MAESTRO_INBOX_API_BASE_URL: "https://consumer.inapp.customer.io",
        MAESTRO_INBOX_CLIENT_PLATFORM: "customerio-maestro",
        MAESTRO_INBOX_DATACENTER: "US",
        MAESTRO_SITE_ID: "site-id",
        MAX_WAIT_MS: String(maxWaitMs),
        POLL_INTERVAL_MS: "1",
        REQUIRE_TITLE_BODY: "true",
        REQUIRE_VISUAL_RENDERABLE: "true",
        RUN_EMAIL: "maestro-test@cio.test",
        output,
        http: {
            post(url, request) {
                if (url.startsWith("http://127.0.0.1:9999/")) {
                    sinkEvents.push(JSON.parse(request.body))
                    return { status: 204, body: "" }
                }
                return queuePost(url, request, () => { clock = maxWaitMs + 10 })
            }
        }
    }
    vm.runInNewContext(source, context)
    return { output, sinkEvents }
}

let attempts = 0
const recovered = runScenario(() => {
    attempts++
    if (attempts === 1) throw new Error("Connection reset")
    return {
        status: 200,
        body: JSON.stringify({
            inboxMessages: [{
                queueId: "queue-1",
                deliveryId: "delivery-1",
                opened: false,
                properties: { title: "Hello", body: "Inbox body" },
                topics: ["cio_inbox_test"],
                type: "basic"
            }]
        })
    }
}, 100)
assert.strictEqual(attempts, 2)
assert.strictEqual(recovered.output.assert_ok, "true")
assert.strictEqual(recovered.output.assert_reason, "matched_after_2_attempts")
assert.ok(recovered.sinkEvents.some(event => event.result === "transport_error"))
assert.ok(recovered.sinkEvents.some(event => event.result === "match"))

const exhausted = runScenario((_url, _request, exhaustBudget) => {
    exhaustBudget()
    throw new Error("Connection reset")
}, 100)
assert.strictEqual(exhausted.output.assert_ok, "false")
assert.strictEqual(exhausted.output.assert_reason, "queue_transport_error")
assert.strictEqual(exhausted.output.attempts, "1")

let nonMatchAttempts = 0
const laterNonMatch = runScenario(() => {
    nonMatchAttempts++
    if (nonMatchAttempts === 1) throw new Error("Connection reset")
    return { status: 200, body: JSON.stringify({ inboxMessages: [] }) }
}, 20)
assert.strictEqual(laterNonMatch.output.assert_ok, "false")
assert.match(
    laterNonMatch.output.assert_reason,
    /^message_or_opened_state_not_matched_after_[2-9][0-9]*$/)

let absenceAttempts = 0
const stableAbsence = runScenario(() => {
    absenceAttempts++
    if (absenceAttempts === 2) throw new Error("Connection reset")
    return { status: 204, body: "" }
}, 100, "false")
assert.strictEqual(absenceAttempts, 5)
assert.strictEqual(stableAbsence.output.assert_ok, "true")
assert.strictEqual(stableAbsence.output.assert_reason, "absent_for_3_consecutive_polls")

console.log("Inbox queue transport retry tests passed")
