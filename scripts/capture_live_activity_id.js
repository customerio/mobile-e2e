// Extracts the SDK-minted Live Activity correlation id from the app's
// ActivityKit status probe after Maestro's copyTextFrom command.
//
// Required env:
//   LIVE_ACTIVITY_KIND - segments | countdown | delivery
//
// Output:
//   output.capture_live_id_ok
//   output.live_instance_id
//   output.live_activitykit_id
//   output.live_activity_kind_count

(function () {
    var text = String(maestro.copiedText || "")
    var kind = String(LIVE_ACTIVITY_KIND || "")
    var escapedKind = kind.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    var linePattern = new RegExp(
        "(?:^|\\n)" + escapedKind +
        " state=[^\\n]* activityId=([^ \\n]+) id=([0-9A-HJKMNP-TV-Z]{26})(?=\\n|$)",
        "g")
    var matches = []
    var match
    while ((match = linePattern.exec(text)) !== null) {
        matches.push(match)
    }

    output.live_activity_kind_count = String(matches.length)
    output.capture_live_id_ok = matches.length === 1 ? "true" : "false"
    output.capture_live_id_reason = matches.length === 1
        ? "matched_one_activity"
        : (matches.length === 0 ? "activity_not_found" : "multiple_activities_found")
    output.live_activitykit_id = matches.length === 1 ? matches[0][1] : ""
    output.live_instance_id = matches.length === 1 ? matches[0][2] : ""
})()
