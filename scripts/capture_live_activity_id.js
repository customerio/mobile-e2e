// Extracts the SDK-minted Live Activity correlation id from the app's
// ActivityKit status probe after Maestro's copyTextFrom command.
//
// Required env:
//   LIVE_ACTIVITY_KIND - segments | countdown | delivery
//
// Output:
//   output.capture_live_id_ok
//   output.live_instance_id

(function () {
    var text = String(maestro.copiedText || "")
    var kind = String(LIVE_ACTIVITY_KIND || "")
    var escapedKind = kind.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    var pattern = new RegExp(
        "(?:^|\\n)" + escapedKind + " state=[^\\n]* id=([0-9A-HJKMNP-TV-Z]{26})(?:\\n|$)")
    var match = text.match(pattern)

    output.capture_live_id_ok = match ? "true" : "false"
    output.capture_live_id_reason = match ? "matched" : "instance_id_not_found"
    output.live_instance_id = match ? match[1] : ""
})()
