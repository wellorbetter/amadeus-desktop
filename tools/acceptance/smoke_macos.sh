#!/usr/bin/env bash
set -euo pipefail

app_bundle="${1:?usage: smoke_macos.sh APP_BUNDLE}"
executable="$app_bundle/Contents/MacOS/Amadeus"
smoke_home="$(mktemp -d)"

cleanup() {
  if [[ -n "${amadeus_app_pid:-}" ]]; then
    kill "$amadeus_app_pid" 2>/dev/null || true
  fi
  rm -rf -- "$smoke_home"
}
trap cleanup EXIT

HOME="$smoke_home" "$executable" &
amadeus_app_pid=$!
sleep 8
kill -0 "$amadeus_app_pid"
