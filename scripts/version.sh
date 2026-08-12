#!/usr/bin/env bash

extract_semantic_version() {
  local version
  version=$(printf '%s\n' "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

semantic_version_at_least() {
  local actual minimum
  local actual_major actual_minor actual_patch
  local minimum_major minimum_minor minimum_patch

  actual=$(extract_semantic_version "$1") || return 2
  minimum=$(extract_semantic_version "$2") || return 2
  IFS=. read -r actual_major actual_minor actual_patch <<<"$actual"
  IFS=. read -r minimum_major minimum_minor minimum_patch <<<"$minimum"

  if ((10#$actual_major != 10#$minimum_major)); then
    ((10#$actual_major > 10#$minimum_major))
  elif ((10#$actual_minor != 10#$minimum_minor)); then
    ((10#$actual_minor > 10#$minimum_minor))
  else
    ((10#$actual_patch >= 10#$minimum_patch))
  fi
}
