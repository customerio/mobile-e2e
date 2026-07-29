// Deterministic wait used only when the OS needs time to register geofences.
// Maestro's embedded GraalJS runtime does not expose a sleep primitive.
var waitMs = parseInt((typeof WAIT_MS === "string" && WAIT_MS) ? WAIT_MS : "1000", 10)
var waitUntil = Date.now() + waitMs
while (Date.now() < waitUntil) { /* spin */ }
output.waited_ms = String(waitMs)
