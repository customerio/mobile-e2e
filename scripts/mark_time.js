// Records a backend-compatible timestamp immediately before a simulated action.
// The activity poller uses this to ignore startup/registration activity from
// earlier in the same Maestro run.
output.action_started_at_seconds = String(Math.floor(Date.now() / 1000))
