#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/version.sh
# shellcheck disable=SC1091
source "$ROOT/scripts/version.sh"

[[ "$(extract_semantic_version '2.6.0')" == "2.6.0" ]]
[[ "$(extract_semantic_version 'Maestro CLI version 2.10.1 (stable)')" == "2.10.1" ]]

if extract_semantic_version "version unknown" >/dev/null; then
  echo "expected an unparseable version to fail" >&2
  exit 1
fi

semantic_version_at_least "2.6.0" "2.6.0"
semantic_version_at_least "2.10.0" "2.6.0"
semantic_version_at_least "3.0.0-beta.1" "2.6.0"

if semantic_version_at_least "2.5.9" "2.6.0"; then
  echo "expected an older patch version to fail" >&2
  exit 1
fi
if semantic_version_at_least "1.10.0" "2.6.0"; then
  echo "expected an older major version to fail" >&2
  exit 1
fi

echo "Semantic version checks passed"
