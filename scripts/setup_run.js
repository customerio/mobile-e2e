// Generate a unique run_id + email for this Maestro run.
// Shared across iOS and Android sample apps.
//
// Outputs:
//   output.run_id  - short random id unique to this run
//   output.email   - customer email derived from run_id
//
// Also publishes to the local sink (started by run.sh) so the renderer
// can pin the per-run identity into the HTML report's setup banner.

var rid = Math.random().toString(36).substring(2, 10) + "-" + Date.now()
output.run_id = rid
output.email = "maestro+e2e-" + rid + "@cio.test"

try {
    http.post("http://127.0.0.1:8899/setup", {
        body: JSON.stringify({ kind: "setup", run_id: rid, email: output.email }),
        headers: { "Content-Type": "application/json" }
    })
} catch (_) { /* sink optional; non-fatal if missing */ }
