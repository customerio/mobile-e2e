#!/usr/bin/env bash

# Select the newest available runtime for the requested iPhone model. GitHub's
# macOS images contain the same model under several runtimes, and simctl's JSON
# order is oldest-first. Pairing Xcode 26.3 with the first iOS 26.0 simulator
# caused Maestro's XCUITest runner to die during launch; the newest runtime is
# the closest match for the active Xcode SDK.
select_ios_device() {
  local preferred_name="${1:-}"

  jq -r --arg preferred "$preferred_name" '
    [.devices | to_entries[] | .key as $runtime | .value[] |
      select(.isAvailable == true) |
      select((.name | startswith("iPhone")) or (.name | startswith("Maestro iPhone"))) |
      . + {runtime: $runtime}
    ] as $phones |
    def runtime_version:
      [.runtime | scan("[0-9]+") | tonumber];
    def newest:
      sort_by(runtime_version) | last;
    def on_newest_runtime:
      (map(. + {runtimeVersion: runtime_version})) as $versioned |
      ($versioned | map(.runtimeVersion) | max) as $latest |
      $versioned | map(select(.runtimeVersion == $latest));
    if $preferred != "" then
      (($phones | map(select(.name == $preferred)) | newest).udid // empty)
    else
      ($phones | on_newest_runtime) as $newest_phones |
      ((($newest_phones | map(select(.name == "Maestro iPhone 17 Pro")))[0] //
        ($newest_phones | map(select(.name == "iPhone 17 Pro")))[0] //
        $newest_phones[0]).udid // empty)
    end'
}
