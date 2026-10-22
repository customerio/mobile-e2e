#!/usr/bin/env node

// Unit tests for scripts/assert_customer_activity.js, plus a replay of the
// geofence flow's inside-crossing steps (runScript / setLocation / assertTrue)
// against a fake backend, so the flow and the script are checked together.

const assert = require("assert")
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const ROOT = path.join(__dirname, "..")
const SCRIPT = path.join(ROOT, "scripts", "assert_customer_activity.js")
const source = fs.readFileSync(SCRIPT, "utf8")

const BASE = "https://api.example.test/v1"
const SINK = "http://127.0.0.1:9999"
const CIO_ID = "cio_fixture"

function geofence(id, fenceId, timestamp) {
    return {
        id,
        type: "geofence",
        timestamp,
        data: { geofence_id: fenceId, geoset_id: 5, transition_id: id.split(":")[0], attributes: {} }
    }
}

// The fences the SDK enters at the outside start point (synthesized ENTERs).
const OUTSIDE_ENTERS = [
    geofence("a2926000-0000-4000-8000-000000000001:5", 2926, 1791442650),
    geofence("a5714000-0000-4000-8000-000000000002:5", 5714, 1791442650),
    geofence("a0640000-0000-4000-8000-000000000003:5", 640, 1791442651)
]
// 2026-10-08 (run 37739722962): the backend stored fence 83's ENTER at
// 1791442727 while the runner's clock read 1791442729 at the crossing.
const FENCE_83_ENTER = geofence("d0083000-0000-4000-8000-000000000083:5", 83, 1791442727)
const RUNNER_MS_AT_CROSSING = 1791442729400

// backend(url) -> { status, body } for Ext API reads.
function fakeBackend(activitiesFor) {
    const calls = { lookups: 0, activities: 0 }
    function get(url) {
        if (url.startsWith(BASE + "/customers?email=")) {
            calls.lookups++
            return { status: 200, body: JSON.stringify({ results: [{ cio_id: CIO_ID }] }) }
        }
        if (url.startsWith(BASE + "/customers/" + CIO_ID + "/activities?")) {
            calls.activities++
            const response = activitiesFor(calls.activities, url)
            if (response.status) return response
            return { status: 200, body: JSON.stringify({ activities: response }) }
        }
        return { status: 404, body: "" }
    }
    return { get, calls }
}

function makeMaestro(backend, startMs) {
    let clock = startMs
    const sinkEvents = []
    return {
        output: { email: "maestro+e2e-fixture@cio.test" },
        sinkEvents,
        Date: { now: () => ++clock },
        http: {
            get: (url) => backend.get(url),
            post(url, request) {
                if (url.startsWith(SINK + "/")) {
                    sinkEvents.push(JSON.parse(request.body))
                    return { status: 200, body: "" }
                }
                throw new Error("unexpected POST " + url)
            }
        }
    }
}

const FLOW_ENV = {
    MAESTRO_APP_API_KEY: "test-key",
    MAESTRO_EXT_API_BASE_URL: BASE,
    E2E_SINK_BASE_URL: SINK,
    GEOFENCE_ID: "83",
    GEOFENCE_EXPECTED_PROPERTY: "geofence_id"
}

function runScriptFile(maestro, file, env) {
    const code = file === SCRIPT ? source : fs.readFileSync(file, "utf8")
    const context = Object.assign({}, FLOW_ENV, env, {
        output: maestro.output,
        http: maestro.http,
        Date: maestro.Date
    })
    vm.runInNewContext(code, context)
}

function geofenceAssertEnv(extra) {
    return Object.assign({
        RUN_EMAIL: "maestro+e2e-fixture@cio.test",
        EXPECTED_ACTIVITY_TYPE: "geofence",
        EXPECTED_ACTIVITY_NAME: "",
        EXPECTED_PROPERTY_NAME: "geofence_id",
        EXPECTED_PROPERTY_VALUE: "83",
        POLL_INTERVAL_MS: "750"
    }, extra)
}

// --- Minimal reader for the flow's top-level command list ---------------
// Handles the shapes used after the inside crossing: `- runScript:` with
// file/env, `- setLocation:` with coordinates, `- assertTrue: <expr>`, and
// single-line commands. Anything else is kept as an opaque command.
function readFlowCommands(flowPath, fromMarker) {
    const text = fs.readFileSync(flowPath, "utf8")
    const start = text.indexOf(fromMarker)
    assert.ok(start >= 0, "flow marker not found: " + fromMarker)
    const lines = text.slice(start).split("\n")
    const commands = []
    let current = null
    let section = null
    function unquote(value) {
        const trimmed = value.trim()
        const quoted = trimmed.match(/^"(.*)"$/)
        return quoted ? quoted[1] : trimmed
    }
    for (const line of lines) {
        if (/^\s*(#.*)?$/.test(line)) continue
        const top = line.match(/^- (\w+):\s*(.*)$/)
        if (top) {
            current = { name: top[1], value: unquote(top[2]), fields: {}, env: {} }
            section = null
            commands.push(current)
            continue
        }
        if (!current) continue
        const field = line.match(/^ {4}(\w+):\s*(.*)$/)
        if (field) {
            section = field[1] === "env" ? "env" : null
            if (field[1] !== "env") current.fields[field[1]] = unquote(field[2])
            continue
        }
        const envLine = line.match(/^ {6}(\w+):\s*(.*)$/)
        if (envLine && section === "env") current.env[envLine[1]] = unquote(envLine[2])
    }
    return commands
}

function interpolate(value, maestro) {
    return value.replace(/\$\{([^}]+)\}/g, (_, expression) =>
        String(vm.runInNewContext(expression, Object.assign({}, FLOW_ENV, { output: maestro.output }))))
}

// Runs the flow from the inside-crossing marker to the end. Returns the first
// failed assertTrue (or null) and the backend calls made.
function replayInsideCrossing(enterVisibleAfterPolls) {
    const flowPath = path.join(ROOT, "flows", "geofence_basic.yaml")
    const commands = readFlowCommands(flowPath, "# --- Cross into the seeded fence ---")
    let inside = false
    let insidePolls = 0
    const backend = fakeBackend(() => {
        if (!inside) return OUTSIDE_ENTERS
        insidePolls++
        return insidePolls >= enterVisibleAfterPolls ? OUTSIDE_ENTERS.concat([FENCE_83_ENTER]) : OUTSIDE_ENTERS
    })
    const maestro = makeMaestro(backend, RUNNER_MS_AT_CROSSING)
    for (const command of commands) {
        if (command.name === "runScript") {
            const env = {}
            for (const key of Object.keys(command.env)) env[key] = interpolate(command.env[key], maestro)
            runScriptFile(maestro, path.join(path.dirname(flowPath), command.fields.file), env)
        } else if (command.name === "setLocation") {
            if ((command.fields.latitude || "").includes("GEOFENCE_INSIDE_LATITUDE")) inside = true
        } else if (command.name === "assertTrue") {
            if (interpolate(command.value, maestro) !== "true") {
                return { failed: command.value, maestro, backend }
            }
        }
    }
    assert.ok(inside, "the replayed segment never moved inside the fence")
    return { failed: null, maestro, backend }
}

// --- Cases -----------------------------------------------------------------
const cases = []
function test(name, fn) { cases.push({ name, fn }) }

test("baseline empty + new fence-83 enter -> pass", () => {
    let polls = 0
    const backend = fakeBackend(() => (++polls >= 3 ? OUTSIDE_ENTERS.concat([FENCE_83_ENTER]) : OUTSIDE_ENTERS))
    const maestro = makeMaestro(backend, RUNNER_MS_AT_CROSSING)
    runScriptFile(maestro, SCRIPT, geofenceAssertEnv({ EXCLUDE_ACTIVITY_IDS: "[]", MAX_WAIT_MS: "90000" }))
    assert.strictEqual(maestro.output.assert_ok, "true")
    assert.strictEqual(maestro.output.activity_id, FENCE_83_ENTER.id)
    assert.strictEqual(maestro.output.assert_reason, "matched_after_3_attempts")
    const record = maestro.sinkEvents[maestro.sinkEvents.length - 1]
    assert.strictEqual(record.result, "match")
    assert.deepStrictEqual(record.bounds.exclude_activity_ids, [])
    assert.ok(record.activities_seen.some(seen => seen.id === FENCE_83_ENTER.id))
})

test("fence-83 enter only in the baseline -> keeps polling, then fails", () => {
    const backend = fakeBackend(() => OUTSIDE_ENTERS.concat([FENCE_83_ENTER]))
    const maestro = makeMaestro(backend, RUNNER_MS_AT_CROSSING)
    runScriptFile(maestro, SCRIPT, geofenceAssertEnv({
        EXCLUDE_ACTIVITY_IDS: JSON.stringify([FENCE_83_ENTER.id]),
        MAX_WAIT_MS: "5000"
    }))
    assert.strictEqual(maestro.output.assert_ok, "false")
    assert.ok(Number(maestro.output.attempts) > 1, "expected repeated polls, got " + maestro.output.attempts)
    assert.match(maestro.output.assert_reason, /^no_matching_activity_after_\d+$/)
    const record = maestro.sinkEvents[maestro.sinkEvents.length - 1]
    assert.strictEqual(record.result, "miss")
    assert.ok(record.activities_seen.some(seen => seen.id === FENCE_83_ENTER.id))
})

test("enter stamped before the runner's clock but new by id -> pass (2026-10-08)", () => {
    const backend = fakeBackend(() => OUTSIDE_ENTERS.concat([FENCE_83_ENTER]))
    const maestro = makeMaestro(backend, RUNNER_MS_AT_CROSSING)
    runScriptFile(maestro, SCRIPT, geofenceAssertEnv({ EXCLUDE_ACTIVITY_IDS: "[]", MAX_WAIT_MS: "90000" }))
    assert.ok(FENCE_83_ENTER.timestamp < Math.floor(RUNNER_MS_AT_CROSSING / 1000))
    assert.strictEqual(maestro.output.assert_ok, "true")
    assert.strictEqual(maestro.output.activity_timestamp, String(FENCE_83_ENTER.timestamp))
})

test("flow replay: 2026-10-08 inside crossing with a device clock 2 s behind passes", () => {
    const replay = replayInsideCrossing(3)
    assert.strictEqual(replay.failed, null, "flow assertion failed: " + replay.failed +
        " (reason " + replay.maestro.output.assert_reason + ")")
    assert.strictEqual(replay.maestro.output.activity_id, FENCE_83_ENTER.id)
})

test("baseline snapshot records only matching ids, in one read", () => {
    const earlier83 = geofence("e0083000-0000-4000-8000-0000000000e0:5", 83, 1791442600)
    const backend = fakeBackend(() => OUTSIDE_ENTERS.concat([earlier83]))
    const maestro = makeMaestro(backend, RUNNER_MS_AT_CROSSING)
    runScriptFile(maestro, SCRIPT, geofenceAssertEnv({ RECORD_BASELINE: "true" }))
    assert.strictEqual(maestro.output.baseline_ok, "true")
    assert.deepStrictEqual(JSON.parse(maestro.output.baseline_activity_ids), [earlier83.id])
    assert.strictEqual(backend.calls.activities, 1)
    const record = maestro.sinkEvents[maestro.sinkEvents.length - 1]
    assert.strictEqual(record.kind, "activity_baseline")
    assert.strictEqual(record.result, "recorded")
    assert.strictEqual(record.activities_seen.length, OUTSIDE_ENTERS.length + 1)
})

test("baseline snapshot fails closed on a backend error", () => {
    const backend = fakeBackend(() => ({ status: 503, body: "" }))
    const maestro = makeMaestro(backend, RUNNER_MS_AT_CROSSING)
    runScriptFile(maestro, SCRIPT, geofenceAssertEnv({ RECORD_BASELINE: "true" }))
    assert.strictEqual(maestro.output.baseline_ok, "false")
    assert.strictEqual(maestro.output.baseline_activity_ids, "")
    assert.strictEqual(maestro.output.assert_reason, "baseline_activities_status_503")
    assert.strictEqual(backend.calls.activities, 1)
})

test("unreadable exclusion list fails without polling", () => {
    const backend = fakeBackend(() => OUTSIDE_ENTERS.concat([FENCE_83_ENTER]))
    const maestro = makeMaestro(backend, RUNNER_MS_AT_CROSSING)
    runScriptFile(maestro, SCRIPT, geofenceAssertEnv({ EXCLUDE_ACTIVITY_IDS: "undefined", MAX_WAIT_MS: "90000" }))
    assert.strictEqual(maestro.output.assert_ok, "false")
    assert.strictEqual(maestro.output.assert_reason, "invalid_exclude_activity_ids")
    assert.strictEqual(backend.calls.activities, 0)
})

test("MIN_TIMESTAMP_SECONDS still filters older activity for other flows", () => {
    const old = { id: "evt-old", type: "event", name: "CIO Location Update", timestamp: 1000, data: { latitude: 40.7 } }
    const fresh = { id: "evt-new", type: "event", name: "CIO Location Update", timestamp: 2000, data: { latitude: 40.7 } }
    const backend = fakeBackend(() => [old, fresh])
    const maestro = makeMaestro(backend, RUNNER_MS_AT_CROSSING)
    runScriptFile(maestro, SCRIPT, {
        RUN_EMAIL: "maestro+e2e-fixture@cio.test",
        EXPECTED_ACTIVITY_TYPE: "event",
        EXPECTED_ACTIVITY_NAME: "CIO Location Update",
        EXPECTED_PROPERTY_NAME: "latitude",
        EXPECTED_PROPERTY_VALUE: "40.7000",
        MIN_TIMESTAMP_SECONDS: "1500",
        MAX_WAIT_MS: "60000"
    })
    assert.strictEqual(maestro.output.assert_ok, "true")
    assert.strictEqual(maestro.output.activity_id, "evt-new")
    const record = maestro.sinkEvents[maestro.sinkEvents.length - 1]
    assert.strictEqual(record.bounds.min_timestamp, 1500)
    assert.strictEqual(record.bounds.exclude_activity_ids, undefined)
})

let failures = 0
for (const { name, fn } of cases) {
    try {
        fn()
        console.log("PASS " + name)
    } catch (error) {
        failures++
        console.log("FAIL " + name + "\n     " + String(error.message).split("\n")[0])
    }
}
if (failures > 0) {
    console.error(failures + " customer activity assertion test(s) failed")
    process.exit(1)
}
console.log("Customer activity assertion tests passed")
