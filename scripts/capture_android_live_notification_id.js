// Extracts the SDK-minted Android Live Notification ULID after Maestro copies
// the sample screen's status_text_view.

(function () {
    var text = String(maestro.copiedText || "")
    var match = text.match(/Status:\s*API:([0-9A-HJKMNP-TV-Z]{26})\s*\(Step\s+1\)/)

    output.capture_live_id_ok = match ? "true" : "false"
    output.capture_live_id_reason = match ? "matched_api_activity" : "activity_not_found"
    output.live_instance_id = match ? match[1] : ""
})()
