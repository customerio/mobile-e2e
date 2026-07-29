// Generate a unique run_id + email for this Maestro run.
// Shared across iOS and Android sample apps.
//
// Outputs:
//   output.run_id  - short random id unique to this run
//   output.email   - customer email derived from run_id
//
// Also publishes to the local sink (started by run.sh) so the renderer
// can pin the per-run identity into the HTML report's setup banner.

var rid = (typeof E2E_RUN_ID === "string" && E2E_RUN_ID.length > 0)
    ? E2E_RUN_ID
    : Math.random().toString(36).substring(2, 10) + "-" + Date.now()
var emailSafeRid = rid.replace(/[^a-zA-Z0-9._-]/g, "-")
var customerNonce = Math.random().toString(36).substring(2, 8) + "-" + Date.now()
output.run_id = rid
output.run_id_regex = rid.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
// A caller may reuse E2E_RUN_ID for correlation. Keep that exact event value,
// but always identify a fresh customer so an older campaign message can never
// satisfy this run's backend assertion.
output.email = "maestro+e2e-" + emailSafeRid + "-" + customerNonce + "@cio.test"
output.started_at_seconds = String(Math.floor(Date.now() / 1000))

try {
    var sink = (typeof E2E_SINK_BASE_URL === "string" && E2E_SINK_BASE_URL.length > 0)
        ? E2E_SINK_BASE_URL
        : "http://127.0.0.1:8899"
    http.post(sink + "/setup", {
        body: JSON.stringify({
            kind: "setup",
            run_id: rid,
            email: output.email,
            started_at_seconds: output.started_at_seconds
        }),
        headers: { "Content-Type": "application/json" }
    })
} catch (_) { /* sink optional; non-fatal if missing */ }
